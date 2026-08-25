#!/usr/bin/env bash
#
# stream-scripts/final.sh — the restore-VM pipeline, end to end
#
# For every server in a JSON list, on this one host, in order:
#   restore_vm.sh   erase the datadir and rebuild it from that server's archive
#   logical.sh      dump the rebuilt instance, per database, to the share
# then once, for the whole run:
#   backup_sync.sh  copy the newest dumps to the second share
#   db_cleanup.sh   apply retention to the dumps on the first share
# and finally shut the VM down.
#
# ERASES MYSQL_DATADIR once per server. This belongs on a dedicated restore VM
# and nowhere else — see the CONFIRM_RESTORE_VM check in PART 8.
# Docs: stream-scripts/README-dr.md
#
#   PART 1   configuration
#   PART 2   log engine
#   PART 3   failure handling
#   PART 4   probes
#   PART 5   usage and arguments
#   PART 6   single-instance lock
#   PART 7   identity and paths
#   PART 8   pre-flight            12 checks
#   PART 9   servers               step 1/3
#   PART 10  sync                  step 2/3
#   PART 11  cleanup               step 3/3
#   PART 12  summary
#   PART 13  shutdown
#
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# PART 1  CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

# This script wipes the datadir once per configured server. The switch is here
# so that copying the deployment onto a production host does not turn it into a
# machine that erases itself nightly. 0 = refuse to run.
CONFIRM_RESTORE_VM=1

# Child scripts. Deployed side by side by default; each is overridable so a
# host can pin a known-good copy.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RESTORE_SCRIPT="${SCRIPT_DIR}/restore_vm.sh"
LOGICAL_SCRIPT="${SCRIPT_DIR}/logical.sh"
SYNC_SCRIPT="${SCRIPT_DIR}/backup_sync.sh"
CLEANUP_SCRIPT="${SCRIPT_DIR}/db_cleanup.sh"

SMB_MOUNT_POINT="/livestorage"                       # MUST match the children
LOCAL_STAGE="/Data/dbvault-stage"                    # logs, during the run
KEEP_LOCAL_DAYS=14                                   # prune logs stranded here

MYSQL_SERVICE="mysql"

# Where the run log is published. One directory per pipeline run, beside the
# dumps rather than inside any one server's tree.
PIPELINE_LOG_BASE="/livestorage/final/_pipeline_logs"

LOCK_DIR="/var/lock/dbvault"

SHUTDOWN_DELAY_MIN=10
# Shut down even when something failed. Every log is published to the share
# before this point, so there is nothing on the VM left to read.
SHUTDOWN_ON_FAILURE=1

CONFIG_FILE=""
BACKUP_DATE=""
SKIP_BINLOG=0
SKIP_SYNC=0
SKIP_CLEANUP=0
NO_SHUTDOWN=0
DRY_RUN=0

# ═══════════════════════════════════════════════════════════════════════════
# PART 2  LOG ENGINE
#
#   HH:MM:SS LEVEL [phase     nn/nn] message
#
# Child scripts use the same engine, so their output drops into this log
# already formatted; only the phase tag differs.
# ═══════════════════════════════════════════════════════════════════════════

RUN_LOG=""
ERROR_LOG=""
PHASE="init"
STEP="-"
WARN_COUNT=0

LOG_RULE='=============================================================='
LOG_SUB='--------------------------------------------------------------'
LOG_DOTS='..............................................................'

emit() {
  printf '%s\n' "$1"
  [[ -n "$RUN_LOG" && -d "${RUN_LOG%/*}" ]] && printf '%s\n' "$1" >> "$RUN_LOG"
  return 0
}

emit_err() {
  printf '%s\n' "$1" >&2
  [[ -n "$RUN_LOG"   && -d "${RUN_LOG%/*}" ]] && printf '%s\n' "$1" >> "$RUN_LOG"
  [[ -n "$ERROR_LOG" && -f "$ERROR_LOG"    ]] && printf '%s\n' "$1" >> "$ERROR_LOG"
  return 0
}

banner() { emit "$LOG_RULE"; emit "$1"; emit "$LOG_RULE"; }
sub()    { emit "$LOG_SUB"; }
kv()     { emit "$(printf ' %-16s: %s' "$1" "$2")"; }

tag()  { printf '[%s %s]' "$PHASE" "$STEP"; }
info() { emit     "$(printf '%s %-5s %-17s %s' "$(date +%T)" 'INFO'  "$(tag)" "$1")"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1))
         emit     "$(printf '%s %-5s %-17s %s' "$(date +%T)" 'WARN'  "$(tag)" "$1")"; }
erro() { emit_err "$(printf '%s %-5s %-17s %s' "$(date +%T)" 'ERROR' "$(tag)" "$1")"; }
cont() { emit     "$(printf '%-32s %s' '' "$1")"; }
cerr() { emit_err "$(printf '%-32s %s' '' "$1")"; }

leader() {
  local pad=$(( 40 - ${#1} - ${#2} ))
  (( pad < 3 )) && pad=3
  printf '%s %s %s' "$1" "${LOG_DOTS:0:$pad}" "$2"
}
ok()  { info "$(leader "$1" 'OK')"; }
val() { info "$(leader "$1" "$2")"; }
nok() { warn "$(leader "$1" "$2")"; }
skp() { info "$(leader "$1" "$2")"; }

CHECK_N=0
CHECK_TOTAL=12
PHASE_EPOCH=0

phase() { PHASE="$1"; STEP="${2:--}"; PHASE_EPOCH="$(date +%s)"; }
check() { PHASE="preflight"; CHECK_N=$((CHECK_N + 1))
          STEP="$(printf '%02d/%02d' "$CHECK_N" "$CHECK_TOTAL")"; }

elapsed() {
  local d=$(( $(date +%s) - $1 ))
  if (( d < 60 )); then printf '%ds' "$d"; else printf '%dm%02ds' $((d / 60)) $((d % 60)); fi
}

# ═══════════════════════════════════════════════════════════════════════════
# PART 3  FAILURE HANDLING
#
# A pipeline failure and a step failure are different things. One server
# failing is DATA, recorded and carried to the summary — the loop goes on to
# the next server, because the other sixteen dumps are still worth having.
# fail_run is for the pipeline itself: bad configuration, a missing child
# script, an unreachable share.
# ═══════════════════════════════════════════════════════════════════════════

START_EPOCH="$(date +%s)"
SERVER_COUNT=0
DONE_COUNT=0
OK_SERVERS=()
FAILED_SERVERS=()
SYNC_TARGETS=0
RET_TARGETS=0
PHYS_RET_TARGETS=0
SYNC_STATE="not run"
CLEANUP_STATE="not run"
CURRENT=""
PUBLISHED_LOGS=0
WORK_DIR=""

publish_logs() {
  [[ "$PUBLISHED_LOGS" == "1" ]] && return 0
  PUBLISHED_LOGS=1
  [[ -n "${PIPELINE_LOG_DIR:-}" ]] || return 0

  if ! mountpoint -q "$SMB_MOUNT_POINT" 2>/dev/null; then
    printf '%s\n' " [WARN] share not mounted — logs kept in $LOCAL_STAGE:" >&2
    printf '%s\n' "        $RUN_LOG" >&2
    return 0
  fi

  mkdir -p "$PIPELINE_LOG_DIR" 2>/dev/null || {
    printf '%s\n' " [WARN] cannot create $PIPELINE_LOG_DIR — logs kept in $LOCAL_STAGE" >&2
    return 0
  }

  local pair src dst kept=0
  for pair in "${RUN_LOG}:pipeline.log" \
              "${ERROR_LOG}:errors.log"; do
    src="${pair%:*}"; dst="${pair##*:}"
    [[ -n "$src" && -f "$src" ]] || continue
    if cp "$src" "${PIPELINE_LOG_DIR}/${dst}" 2>/dev/null \
       && [[ -s "${PIPELINE_LOG_DIR}/${dst}" ]]; then
      rm -f "$src" 2>/dev/null || true
    else
      kept=$((kept + 1))
    fi
  done

  if [[ $kept -gt 0 ]]; then
    printf '%s\n' " [WARN] $kept log(s) could not be published — kept in $LOCAL_STAGE" >&2
  fi
  printf '%s\n' " logs published to $PIPELINE_LOG_DIR"
}

# Safety net only. A successful run leaves nothing in LOCAL_STAGE: the log is
# published to the share and the local copy dropped. This clears only what an
# earlier run kept BECAUSE the share was unreachable.
# Never touches this run's files: -mtime is in whole days.
prune_local() {
  local f n=0
  while IFS= read -r f; do
    rm -f "$f" 2>/dev/null && n=$((n + 1))
  done < <(find "$LOCAL_STAGE" -maxdepth 1 -type f -name 'pipeline_*.log' \
             -mtime "+${KEEP_LOCAL_DAYS}" 2>/dev/null || true)
  [[ $n -gt 0 ]] && info "pruned $n stranded log file(s) older than ${KEEP_LOCAL_DAYS} days"
  return 0
}

# What actually broke. A die() names its own cause; an uncaught non-zero does
# not, and used to produce a failure banner with no reason in it at all. These
# carry what bash knows about that case: the command, its line, its exit code.
DIED=0
INTERRUPTED=0
FAILED_CMD=""
FAILED_LINE=""
FAILED_RC=""

fail_run() {
  trap - ERR INT TERM
  local at="$PHASE $STEP"

  emit ""
  banner " PIPELINE FAILED"
  kv "failed in" "$at"
  if [[ ${INTERRUPTED:-0} -eq 1 ]]; then
    kv "cause" "interrupted — Ctrl-C or kill"
  elif [[ ${DIED:-0} -eq 0 && -n "${FAILED_CMD:-}" ]]; then
    kv "cause"          "uncaught failure — no check reported this"
    kv "failed command" "$FAILED_CMD"
    kv "at line"        "${FAILED_LINE:-?}  (exit ${FAILED_RC:-?})"
  fi
  kv "duration"  "$(elapsed "$START_EPOCH")"
  [[ -n "$CURRENT" ]] && kv "working on" "$CURRENT"
  sub

  if [[ ${#OK_SERVERS[@]} -gt 0 ]]; then
    warn "${#OK_SERVERS[@]} server(s) completed before this failure"
    cont "${OK_SERVERS[*]}"
    cont "their dumps are published and verified"
  fi
  if [[ $DONE_COUNT -lt $SERVER_COUNT ]]; then
    erro "$(( SERVER_COUNT - DONE_COUNT )) server(s) were never attempted"
    cerr "this datadir now holds whichever server was restored last, if any"
  fi

  [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR" 2>/dev/null

  sub
  kv "error log" "${ERROR_LOG:-(none)}"
  banner " RESULT failed phase=${at% *} step=${at#* } servers=${SERVER_COUNT} ok=${#OK_SERVERS[@]} failed=${#FAILED_SERVERS[@]} dur_s=$(( $(date +%s) - START_EPOCH )) warn=${WARN_COUNT}"

  publish_logs

  # No shutdown here. A pipeline that fell over in pre-flight has done no work
  # and the operator is usually watching; the VM staying up costs one hour.
  exit 1
}

die() {
  DIED=1
  erro "$1"; shift
  local l; for l in "$@"; do cerr "$l"; done
  fail_run
}

# Captured inside the trap, not in fail_run: fail_run's own commands overwrite
# BASH_COMMAND, so by the time it runs the failing command is already gone.
on_err() {
  FAILED_RC=$?
  FAILED_CMD="$BASH_COMMAND"
  FAILED_LINE="${BASH_LINENO[0]}"
  fail_run
}

trap on_err ERR
trap 'INTERRUPTED=1; fail_run' INT TERM

# ═══════════════════════════════════════════════════════════════════════════
# PART 4  PROBES
# ═══════════════════════════════════════════════════════════════════════════

writable() {
  local probe="$1/.probe_$$"
  touch "$probe" 2>/dev/null || return 1
  rm -f "$probe"
  return 0
}

jqv() { jq -r "$1" "$CONFIG_FILE" 2>/dev/null || true; }

# Runs a child script: output to the terminal AND into this run's log AND into
# a per-step file the RESULT line is read back from. PIPESTATUS[0] is the
# child's own status — tee's would always be 0.
CHILD_RESULT=""
run_child() {
  local out="${WORK_DIR}/step_$$.out"
  local st=0
  : > "$out"

  set +e
  "$@" 2>&1 | tee -a "$RUN_LOG" "$out" >/dev/null
  st=${PIPESTATUS[0]}
  set -e

  # The child's own one-line verdict, quoted verbatim into the summary.
  CHILD_RESULT="$(grep -a ' RESULT ' "$out" 2>/dev/null | tail -1 || true)"
  CHILD_RESULT="${CHILD_RESULT# }"
  rm -f "$out" 2>/dev/null || true
  return "$st"
}

# ═══════════════════════════════════════════════════════════════════════════
# PART 5  USAGE AND ARGUMENTS
# ═══════════════════════════════════════════════════════════════════════════

usage() {
  cat <<EOF
Usage: $0 --config=PATH [--backup_date=YYYYMMDD] [--skip-binlog]
          [--skip-sync] [--skip-cleanup] [--no-shutdown] [--dry-run]

  Step 1  servers  per server: restore_vm.sh, then logical.sh
  Step 2  sync     backup_sync.sh, once
  Step 3  cleanup  db_cleanup.sh, once
  then     shutdown -h +${SHUTDOWN_DELAY_MIN}

  --config=PATH           JSON list of servers to process, in order
  --backup_date=YYYYMMDD  restore each server's LATEST archive from this date
                          (default: today) — passed straight to restore_vm.sh
  --skip-binlog           restore to the backup point only, for every server
  --skip-sync             do not run backup_sync.sh
  --skip-cleanup          do not run db_cleanup.sh
  --no-shutdown           leave the VM running at the end
  --dry-run               verify each archive (restore_vm.sh --dry-run), skip
                          the dumps, and run sync and cleanup in their own
                          dry-run modes. Nothing is erased, written or deleted.

Config file — an array of objects:

  [
    {
      "server_name": "Cloud-Live-DB-Default",
      "backup_base": "/livestorage/Backup/Cloud-Live-DB-Default",
      "base_dir":    "/livestorage/Logical/Cloud-Live-DB-Default"
    }
  ]

  server_name   required  identity, and the name of the dump tree
  backup_base   required  where that server's backup.sh publishes its .xbstream
  base_dir      required  where this run's logical dumps are published
  backup_id     optional  exact archive id, instead of the date's latest
  skip_binlog   optional  true = restore that one server to the backup point
  mysql_host    optional  override the dump connection for that server
  mode          optional  ALL (default) or SELECTED
  db_list_dir   optional  required by mode SELECTED
  sync_dest     optional  backup_sync.sh: destination on the second share
  retention     optional  db_cleanup.sh: "smart" or "days:N"

The same file drives all four steps: this script reads the first eight fields,
backup_sync.sh reads base_dir and sync_dest, db_cleanup.sh reads base_dir and
retention. There is no second server list anywhere.

Both closing steps are OPT-IN, per entry:

  no sync_dest on an entry   that server's dumps are not copied anywhere
  no sync_dest on any entry  step 2 does not run at all
  no retention on an entry   that server's dumps are never expired
  no retention on any entry  step 3 does not run at all

With neither field anywhere, the pipeline restores and dumps, the dumps stay on
the primary share, and nothing is copied or deleted.

Every server is restored onto THIS host's datadir, one after another, so only
the last one survives as a running database. The dumps are the product.
EOF
  trap - ERR INT TERM
  exit 1
}

argfail() { echo "[ERROR] $1" >&2; trap - ERR INT TERM; exit 1; }

[[ $# -ge 1 ]] || usage

for arg in "$@"; do
  case "$arg" in
    --config=*)       CONFIG_FILE="${arg#*=}" ;;
    --backup_date=*)  BACKUP_DATE="${arg#*=}" ;;
    --skip-binlog)    SKIP_BINLOG=1 ;;
    --skip-sync)      SKIP_SYNC=1 ;;
    --skip-cleanup)   SKIP_CLEANUP=1 ;;
    --no-shutdown)    NO_SHUTDOWN=1 ;;
    --dry-run)        DRY_RUN=1 ;;
    -h|--help)        usage ;;
    *) echo "[ERROR] Unknown argument: $arg" >&2; usage ;;
  esac
done

[[ -n "$CONFIG_FILE" ]] || argfail "--config is required"
[[ -f "$CONFIG_FILE" ]] || argfail "Config file not found: $CONFIG_FILE"
if [[ -n "$BACKUP_DATE" ]] && ! [[ "$BACKUP_DATE" =~ ^[0-9]{8}$ ]]; then
  argfail "Invalid --backup_date: $BACKUP_DATE (expected YYYYMMDD)"
fi

# A dry run never erases a datadir, so it never needs the VM to stop either.
[[ $DRY_RUN -eq 1 ]] && NO_SHUTDOWN=1

RUN_MODE="full pipeline"
[[ $SKIP_BINLOG -eq 1 ]] && RUN_MODE="$RUN_MODE, backup point only"
[[ $DRY_RUN     -eq 1 ]] && RUN_MODE="DRY RUN — verify only, nothing modified"

# ═══════════════════════════════════════════════════════════════════════════
# PART 6  SINGLE-INSTANCE LOCK
#
# Held for the whole pipeline. The children take their own locks; this one stops
# a second pipeline from interleaving restores into the same datadir.
# ═══════════════════════════════════════════════════════════════════════════

mkdir -p "$LOCK_DIR" "$LOCAL_STAGE" 2>/dev/null || true
exec 200>"${LOCK_DIR}/pipeline.lock"
if ! flock -n 200; then
  echo "[ERROR] Another pipeline run is already in progress." >&2
  trap - ERR INT TERM
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 7  IDENTITY AND PATHS
# ═══════════════════════════════════════════════════════════════════════════

RUN_STAMP="$(date +%Y%m%d_%H%M%S)"
RUN_LOG="${LOCAL_STAGE}/pipeline_${RUN_STAMP}.log"
ERROR_LOG="${LOCAL_STAGE}/pipeline_${RUN_STAMP}_errors.log"
PIPELINE_LOG_DIR="${PIPELINE_LOG_BASE}/${RUN_STAMP}"
WORK_DIR="${LOCAL_STAGE}/.pipeline_${RUN_STAMP}"

mkdir -p "$LOCAL_STAGE" "$WORK_DIR" 2>/dev/null || {
  echo "[ERROR] Failed to create $WORK_DIR" >&2
  trap - ERR INT TERM; exit 1; }

printf 'errors for pipeline run %s\n\n' "$RUN_STAMP" > "$ERROR_LOG"

banner " PIPELINE RUN  $RUN_STAMP"
kv "started"     "$(date '+%F %T %Z')"
kv "host"        "$(hostname -s 2>/dev/null || echo unknown)"
kv "mode"        "$RUN_MODE"
kv "config"      "$CONFIG_FILE"
kv "backup date" "${BACKUP_DATE:-today ($(date +%Y%m%d))}"
kv "restore"     "$RESTORE_SCRIPT"
kv "logical"     "$LOGICAL_SCRIPT"
kv "sync"        "$([[ $SKIP_SYNC -eq 1 ]] && echo 'SKIPPED (--skip-sync)' || echo "$SYNC_SCRIPT")"
kv "cleanup"     "$([[ $SKIP_CLEANUP -eq 1 ]] && echo 'SKIPPED (--skip-cleanup)' || echo "$CLEANUP_SCRIPT")"
kv "shutdown"    "$([[ $NO_SHUTDOWN -eq 1 ]] && echo 'no' || echo "yes, +${SHUTDOWN_DELAY_MIN} min at the end")"
kv "logs"        "$LOCAL_STAGE during the run, published at the end"
sub
prune_local

# ═══════════════════════════════════════════════════════════════════════════
# PART 8  PRE-FLIGHT
#
# The whole configuration is validated here, before the first datadir is
# erased. Discovering a typo in entry four after entries one to three have been
# restored and dumped costs hours and leaves a half-finished night.
# ═══════════════════════════════════════════════════════════════════════════

phase preflight
PREFLIGHT_EPOCH="$PHASE_EPOCH"

check
[[ $EUID -eq 0 ]] || die "$(leader 'user privileges' 'NOT ROOT')" \
                         "the restore step stops MySQL and rewrites the datadir"
ok "user privileges"

# Deliberately early, and before anything is read or erased.
check
if [[ $DRY_RUN -eq 1 ]]; then
  skp "restore VM switch" "n/a (dry run)"
elif [[ "${CONFIRM_RESTORE_VM:-0}" != "1" ]]; then
  die "$(leader 'restore VM switch' 'DISABLED')" \
      "CONFIRM_RESTORE_VM=0 — this host is not marked as a restore VM" \
      "" \
      "this pipeline erases the datadir once per configured server. On a" \
      "production host that is a self-inflicted outage, repeated for every" \
      "entry in the config file." \
      "" \
      "if this really is the restore VM, set CONFIRM_RESTORE_VM=1 in this script."
else
  ok "restore VM switch"
fi

check
for cmd in jq flock find sort awk tee mountpoint systemctl hostname; do
  command -v "$cmd" >/dev/null 2>&1 \
    || die "$(leader 'required binaries' 'MISSING')" "not found in PATH: $cmd"
done
ok "required binaries"

check
[[ -x "$RESTORE_SCRIPT" ]] \
  || die "$(leader 'child scripts' 'MISSING')" "not executable: $RESTORE_SCRIPT"
if [[ $DRY_RUN -eq 0 ]]; then
  [[ -x "$LOGICAL_SCRIPT" ]] \
    || die "$(leader 'child scripts' 'MISSING')" "not executable: $LOGICAL_SCRIPT"
fi
# The two closing steps are only required if the config asks for them, and that
# is not known until the config is read (the next checks). So they are recorded
# here and judged in their own phases: a host that never syncs need not deploy
# backup_sync.sh at all.
SYNC_SCRIPT_OK=0;    [[ -x "$SYNC_SCRIPT" ]]    && SYNC_SCRIPT_OK=1
CLEANUP_SCRIPT_OK=0; [[ -x "$CLEANUP_SCRIPT" ]] && CLEANUP_SCRIPT_OK=1
ok "child scripts"
[[ $SYNC_SCRIPT_OK    -eq 1 ]] || cont "backup_sync.sh not deployed here"
[[ $CLEANUP_SCRIPT_OK -eq 1 ]] || cont "db_cleanup.sh not deployed here"

check
jq empty "$CONFIG_FILE" >/dev/null 2>&1 \
  || die "$(leader 'config parses' 'INVALID JSON')" "$CONFIG_FILE"
[[ "$(jqv 'type')" == "array" ]] \
  || die "$(leader 'config parses' 'NOT AN ARRAY')" \
         "the config must be a JSON array of server objects — see --help"
SERVER_COUNT="$(jqv 'length')"
[[ "$SERVER_COUNT" =~ ^[0-9]+$ && "$SERVER_COUNT" -gt 0 ]] \
  || die "$(leader 'config parses' 'EMPTY')" "no entries in $CONFIG_FILE"
val "config parses" "$SERVER_COUNT server(s)"

# Read once into arrays: the loop in PART 9 never touches the file again, so a
# config edited mid-run cannot change what this run does.
check
SERVER_NAMES=();  BASES=(); DUMPS=(); IDS=(); SKIPS=(); HOSTS=(); MODES=(); LISTS=()
PROBLEMS=0
for i in $(seq 0 $((SERVER_COUNT - 1))); do
  n="$(jqv ".[$i].server_name // empty")"
  b="$(jqv ".[$i].backup_base // empty")"
  d="$(jqv ".[$i].base_dir // empty")"
  SERVER_NAMES+=("$n"); BASES+=("$b"); DUMPS+=("$d")
  IDS+=("$(jqv ".[$i].backup_id // empty")")
  SKIPS+=("$(jqv ".[$i].skip_binlog // empty")")
  HOSTS+=("$(jqv ".[$i].mysql_host // empty")")
  MODES+=("$(jqv ".[$i].mode // empty")")
  LISTS+=("$(jqv ".[$i].db_list_dir // empty")")

  label="entry $((i + 1))/$SERVER_COUNT"
  if [[ -z "$n" || -z "$b" || -z "$d" ]]; then
    erro "$(leader "$label" 'INCOMPLETE')"
    cerr "server_name='$n' backup_base='$b' base_dir='$d' — all three are required"
    PROBLEMS=$((PROBLEMS + 1))
    continue
  fi
  if ! [[ "$n" =~ ^[A-Za-z0-9._-]+$ ]]; then
    erro "$(leader "$label" 'BAD SERVER NAME')"
    cerr "'$n' — expected [A-Za-z0-9._-]+, it becomes part of file names"
    PROBLEMS=$((PROBLEMS + 1))
  fi
  for p in "$b" "$d"; do
    [[ "$p" == "$SMB_MOUNT_POINT"/* ]] && continue
    erro "$(leader "$label" 'PATH OFF THE SHARE')"
    cerr "'$p' is not under $SMB_MOUNT_POINT"
    PROBLEMS=$((PROBLEMS + 1))
  done
  if [[ -n "${MODES[$i]}" && "${MODES[$i]}" != "ALL" && "${MODES[$i]}" != "SELECTED" ]]; then
    erro "$(leader "$label" 'BAD MODE')"
    cerr "'${MODES[$i]}' — expected ALL or SELECTED"
    PROBLEMS=$((PROBLEMS + 1))
  fi
  if [[ "${MODES[$i]}" == "SELECTED" && -z "${LISTS[$i]}" ]]; then
    erro "$(leader "$label" 'MODE NEEDS A LIST')"
    cerr "mode SELECTED requires db_list_dir"
    PROBLEMS=$((PROBLEMS + 1))
  fi

  # Fields this script only passes through: backup_sync.sh reads sync_dest, and
  # db_cleanup.sh reads retention and physical_retention, from this same file.
  # All three are OPTIONAL and opt-in — an entry without the key is not synced,
  # or not expired. They are validated here anyway, so a typo surfaces in
  # pre-flight rather than three hours later, in the step that consumes it.
  dst="$(jqv ".[$i].sync_dest // empty")"
  if [[ -n "$dst" ]]; then
    SYNC_TARGETS=$((SYNC_TARGETS + 1))
    if [[ "$dst" != /* ]]; then
      erro "$(leader "$label" 'BAD SYNC DEST')"
      cerr "'$dst' — must be an absolute path on the second share"
      PROBLEMS=$((PROBLEMS + 1))
    fi
  fi
  ret="$(jqv ".[$i].retention // empty")"
  if [[ -n "$ret" ]]; then
    RET_TARGETS=$((RET_TARGETS + 1))
    case "$ret" in
      smart) ;;
      days:*) [[ "${ret#days:}" =~ ^[1-9][0-9]*$ ]] || {
                erro "$(leader "$label" 'BAD RETENTION')"
                cerr "'$ret' — days:N needs N as a positive integer"
                PROBLEMS=$((PROBLEMS + 1)); } ;;
      *) erro "$(leader "$label" 'BAD RETENTION')"
         cerr "'$ret' — expected 'smart' or 'days:N'"
         PROBLEMS=$((PROBLEMS + 1)) ;;
    esac
  fi
  # Same patterns, but over backup_base: this expires the .xbstream sets, and a
  # set is seven files and directories that only mean anything together.
  pret="$(jqv ".[$i].physical_retention // empty")"
  if [[ -n "$pret" ]]; then
    PHYS_RET_TARGETS=$((PHYS_RET_TARGETS + 1))
    case "$pret" in
      smart) ;;
      days:*) [[ "${pret#days:}" =~ ^[1-9][0-9]*$ ]] || {
                erro "$(leader "$label" 'BAD PHYSICAL RETENTION')"
                cerr "'$pret' — days:N needs N as a positive integer"
                PROBLEMS=$((PROBLEMS + 1)); } ;;
      *) erro "$(leader "$label" 'BAD PHYSICAL RETENTION')"
         cerr "'$pret' — expected 'smart' or 'days:N'"
         PROBLEMS=$((PROBLEMS + 1)) ;;
    esac
  fi
done

# One name restored twice in a night would leave the second run's dumps under
# the same tree with no way to tell which restore produced which archive.
DUPLICATE_NAMES="$(printf '%s\n' "${SERVER_NAMES[@]}" | sort | uniq -d || true)"
if [[ -n "$DUPLICATE_NAMES" ]]; then
  erro "$(leader 'config entries' 'DUPLICATE SERVER NAME')"
  while IFS= read -r d; do cerr "  $d"; done <<< "$DUPLICATE_NAMES"
  PROBLEMS=$((PROBLEMS + 1))
fi

[[ $PROBLEMS -eq 0 ]] \
  || die "$(leader 'config entries' "$PROBLEMS PROBLEM(S)")" \
         "listed above; nothing has been touched" \
         "the whole config is validated before the first datadir is erased"
ok "config entries"

# Both closing steps are opt-in, per entry. With no sync_dest anywhere there is
# nowhere to copy to, and with no retention anywhere there is no policy to
# apply — running either would be a no-op walk over the share, so neither runs.
# The dumps simply stay on the primary share.
if [[ $SYNC_TARGETS -eq 0 ]]; then
  val "sync targets" "none — no sync_dest in any entry, sync will be SKIPPED"
else
  val "sync targets" "$SYNC_TARGETS/$SERVER_COUNT entries have sync_dest"
fi
if [[ $RET_TARGETS -eq 0 ]]; then
  val "retention rules" "none — no retention in any entry, cleanup will be SKIPPED"
else
  val "retention rules" "$RET_TARGETS/$SERVER_COUNT entries have retention"
fi
if [[ $PHYS_RET_TARGETS -eq 0 ]]; then
  cont "no entry has physical_retention — no .xbstream set is ever expired"
else
  val "physical rules" "$PHYS_RET_TARGETS/$SERVER_COUNT entries have physical_retention"
fi

check
mountpoint -q "$SMB_MOUNT_POINT" \
  || die "$(leader 'smb share' 'NOT MOUNTED')" \
         "expected a mount at $SMB_MOUNT_POINT" \
         "unmounted, every backup_base reads as an empty directory and every" \
         "server would look as though it had never been backed up"
ok "smb share"

check
MISSING_BASES=0
for i in $(seq 0 $((SERVER_COUNT - 1))); do
  if [[ ! -d "${BASES[$i]}" ]]; then
    nok "${SERVER_NAMES[$i]}" "NO BACKUP DIRECTORY"
    cont "expected ${BASES[$i]}"
    MISSING_BASES=$((MISSING_BASES + 1))
  fi
done
[[ $MISSING_BASES -lt $SERVER_COUNT ]] \
  || die "$(leader 'backup directories' 'NONE PRESENT')" \
         "not one configured backup_base exists under $SMB_MOUNT_POINT" \
         "the share may be mounted from the wrong account"
val "backup directories" "$(( SERVER_COUNT - MISSING_BASES ))/$SERVER_COUNT present"

check
if [[ $DRY_RUN -eq 1 ]]; then
  skp "dump directories" "n/a (dry run)"
else
  for i in $(seq 0 $((SERVER_COUNT - 1))); do
    mkdir -p "${DUMPS[$i]}" 2>/dev/null \
      || die "$(leader 'dump directories' 'MKDIR FAILED')" "${DUMPS[$i]}"
    writable "${DUMPS[$i]}" \
      || die "$(leader 'dump directories' 'NOT WRITABLE')" "${DUMPS[$i]}"
  done
  ok "dump directories"
fi

check
writable "$LOCAL_STAGE" \
  || die "$(leader 'local stage writable' 'NO')" "not writable: $LOCAL_STAGE"
ok "local stage writable"

check
if systemctl cat "$MYSQL_SERVICE" >/dev/null 2>&1 \
   || systemctl cat mysqld >/dev/null 2>&1; then
  ok "mysql service"
else
  nok "mysql service" "UNIT NOT FOUND"
  cont "neither $MYSQL_SERVICE nor mysqld is a known unit on this host"
  cont "the restore step stops and starts it — it will fail if this is wrong"
fi

check
if [[ $NO_SHUTDOWN -eq 1 ]]; then
  skp "shutdown command" "n/a (--no-shutdown)"
elif command -v shutdown >/dev/null 2>&1; then
  ok "shutdown command"
else
  nok "shutdown command" "MISSING"
  cont "the run will finish normally but the VM will stay up"
fi

STEP="-"
info "$CHECK_N checks passed, ${WARN_COUNT} warning(s)   ($(elapsed "$PREFLIGHT_EPOCH"))"
sub

# ═══════════════════════════════════════════════════════════════════════════
# PART 9  SERVERS  1/3
#
# One server at a time: restore, then dump. A server that fails its restore is
# NOT dumped — the datadir then holds either nothing or the previous server's
# data, and logical.sh would happily publish it under the wrong name (its own
# source check refuses, which is the second line of defence).
# ═══════════════════════════════════════════════════════════════════════════

phase servers 1/3
SERVERS_EPOCH="$PHASE_EPOCH"

for i in $(seq 0 $((SERVER_COUNT - 1))); do
  name="${SERVER_NAMES[$i]}"
  CURRENT="$name ($((i + 1))/$SERVER_COUNT)"

  sub
  info "[$((i + 1))/$SERVER_COUNT] $name"
  cont "archive from ${BASES[$i]}"
  cont "dumps to     ${DUMPS[$i]}"

  # --- restore ---------------------------------------------------------
  R_ARGS=("$RESTORE_SCRIPT" "--server_name=$name" "--backup_base=${BASES[$i]}")
  if [[ -n "${IDS[$i]}" ]]; then
    R_ARGS+=("--backup_id=${IDS[$i]}")
  elif [[ -n "$BACKUP_DATE" ]]; then
    R_ARGS+=("--backup_date=$BACKUP_DATE")
  fi
  [[ $SKIP_BINLOG -eq 1 || "${SKIPS[$i]}" == "true" ]] && R_ARGS+=("--skip-binlog")
  [[ $DRY_RUN -eq 1 ]] && R_ARGS+=("--dry-run")

  if ! run_child "${R_ARGS[@]}"; then
    erro "$(leader "$name" 'RESTORE FAILED')"
    [[ -n "$CHILD_RESULT" ]] && cerr "$CHILD_RESULT"
    cerr "not dumping this server: the datadir does not hold its data"
    FAILED_SERVERS+=("${name}(restore)")
    DONE_COUNT=$((DONE_COUNT + 1))
    continue
  fi
  ok "$name restore"
  [[ -n "$CHILD_RESULT" ]] && cont "$CHILD_RESULT"

  # --- dump ------------------------------------------------------------
  if [[ $DRY_RUN -eq 1 ]]; then
    skp "$name dump" "skipped (dry run)"
    OK_SERVERS+=("$name")
    DONE_COUNT=$((DONE_COUNT + 1))
    continue
  fi

  L_ARGS=("$LOGICAL_SCRIPT" "--server_name=$name" "--base_dir=${DUMPS[$i]}")
  [[ -n "${HOSTS[$i]}" ]] && L_ARGS+=("--mysql_host=${HOSTS[$i]}")
  [[ -n "${MODES[$i]}" ]] && L_ARGS+=("--mode=${MODES[$i]}")
  [[ -n "${LISTS[$i]}" ]] && L_ARGS+=("--db_list_dir=${LISTS[$i]}")

  if ! run_child "${L_ARGS[@]}"; then
    erro "$(leader "$name" 'DUMP FAILED')"
    [[ -n "$CHILD_RESULT" ]] && cerr "$CHILD_RESULT"
    cerr "the restore succeeded, so this is a dump-side failure: see the"
    cerr "logical backup log under ${DUMPS[$i]}/logs/"
    FAILED_SERVERS+=("${name}(dump)")
    DONE_COUNT=$((DONE_COUNT + 1))
    continue
  fi
  ok "$name dump"
  [[ -n "$CHILD_RESULT" ]] && cont "$CHILD_RESULT"

  OK_SERVERS+=("$name")
  DONE_COUNT=$((DONE_COUNT + 1))
done
CURRENT=""

sub
if [[ ${#FAILED_SERVERS[@]} -gt 0 ]]; then
  nok "servers" "${#OK_SERVERS[@]}/$SERVER_COUNT  (${#FAILED_SERVERS[@]} failed)"
  cont "failed: ${FAILED_SERVERS[*]}"
else
  val "servers" "${#OK_SERVERS[@]}/$SERVER_COUNT  ($(elapsed "$SERVERS_EPOCH"))"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 10  SYNC  2/3
#
# Runs even when some servers failed: it copies whatever the newest dump of
# each database is, and a server that failed tonight still has yesterday's.
# ═══════════════════════════════════════════════════════════════════════════

phase sync 2/3

if [[ $SKIP_SYNC -eq 1 ]]; then
  SYNC_STATE="skipped (--skip-sync)"
  skp "sync" "$SYNC_STATE"
elif [[ $SYNC_TARGETS -eq 0 ]]; then
  SYNC_STATE="not configured"
  skp "sync" "$SYNC_STATE"
  cont "no entry in $CONFIG_FILE has sync_dest — nothing to copy anywhere"
  cont "the dumps stay on the primary share only; add sync_dest to opt an"
  cont "entry in"
elif [[ $SYNC_SCRIPT_OK -eq 0 ]]; then
  SYNC_STATE="FAILED (script missing)"
  erro "$(leader 'sync' 'SCRIPT MISSING')"
  cerr "$SYNC_TARGETS entry/ies ask for a sync, but $SYNC_SCRIPT is not"
  cerr "executable — the second copy is NOT current"
else
  S_ARGS=("$SYNC_SCRIPT" "--config=$CONFIG_FILE")
  [[ $DRY_RUN -eq 1 ]] && S_ARGS+=("--dry-run")

  if run_child "${S_ARGS[@]}"; then
    SYNC_STATE="ok"
    ok "sync"
    [[ -n "$CHILD_RESULT" ]] && cont "$CHILD_RESULT"
  else
    SYNC_STATE="FAILED"
    erro "$(leader 'sync' 'FAILED')"
    [[ -n "$CHILD_RESULT" ]] && cerr "$CHILD_RESULT"
    cerr "the dumps on the primary share are unaffected; the second copy is not"
    cerr "current. Cleanup still runs — it only ever touches the primary share."
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 11  CLEANUP  3/3
#
# Last, and deliberately after the sync: retention deletes from the primary
# share, and an archive that has not been copied yet should not be a candidate
# for deletion in the same run.
# ═══════════════════════════════════════════════════════════════════════════

phase cleanup 3/3

if [[ $SKIP_CLEANUP -eq 1 ]]; then
  CLEANUP_STATE="skipped (--skip-cleanup)"
  skp "cleanup" "$CLEANUP_STATE"
elif [[ $RET_TARGETS -eq 0 ]]; then
  CLEANUP_STATE="not configured"
  skp "cleanup" "$CLEANUP_STATE"
  cont "no entry in $CONFIG_FILE has retention — nothing is expired"
  cont "every dump is kept, so watch the share: add retention to an entry"
  cont "when you want it pruned"
elif [[ $CLEANUP_SCRIPT_OK -eq 0 ]]; then
  CLEANUP_STATE="FAILED (script missing)"
  erro "$(leader 'cleanup' 'SCRIPT MISSING')"
  cerr "$RET_TARGETS entry/ies ask for retention, but $CLEANUP_SCRIPT is not"
  cerr "executable — nothing is being expired"
else
  C_ARGS=("$CLEANUP_SCRIPT" "--config=$CONFIG_FILE")
  [[ $DRY_RUN -eq 1 ]] && C_ARGS+=("--dry-run")

  if run_child "${C_ARGS[@]}"; then
    CLEANUP_STATE="ok"
    ok "cleanup"
    [[ -n "$CHILD_RESULT" ]] && cont "$CHILD_RESULT"
  else
    CLEANUP_STATE="FAILED"
    erro "$(leader 'cleanup' 'FAILED')"
    [[ -n "$CHILD_RESULT" ]] && cerr "$CHILD_RESULT"
    cerr "retention did not complete: the share will keep filling until it does"
  fi
fi

rm -rf "$WORK_DIR" 2>/dev/null || true
WORK_DIR=""

# ═══════════════════════════════════════════════════════════════════════════
# PART 12  SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

PHASE="done"; STEP="-"

PIPELINE_OK=1
[[ ${#FAILED_SERVERS[@]} -gt 0 ]] && PIPELINE_OK=0
# Glob, not equality: a state may carry a reason, e.g. "FAILED (script missing)".
# "not configured" and "skipped" are deliberate outcomes and do NOT fail the run.
[[ "$SYNC_STATE" == FAILED* || "$CLEANUP_STATE" == FAILED* ]] && PIPELINE_OK=0

emit ""
if [[ $PIPELINE_OK -eq 1 ]]; then
  banner " PIPELINE OK  $RUN_STAMP"
else
  banner " PIPELINE INCOMPLETE  $RUN_STAMP"
fi
kv "duration"  "$(elapsed "$START_EPOCH")"
kv "mode"      "$RUN_MODE"
kv "servers"   "$SERVER_COUNT configured, ${#OK_SERVERS[@]} succeeded, ${#FAILED_SERVERS[@]} failed"
kv "succeeded" "${OK_SERVERS[*]:-none}"
kv "failed"    "${FAILED_SERVERS[*]:-none}"
kv "sync"      "$SYNC_STATE"
kv "cleanup"   "$CLEANUP_STATE"
kv "warnings"  "$WARN_COUNT"
if [[ ${#FAILED_SERVERS[@]} -gt 0 ]]; then
  sub
  emit " a failed server has no dump for tonight. Its previous dumps are"
  emit " untouched, and db_cleanup.sh never deletes the newest archive of a"
  emit " database, so the last good copy survives the gap."
  emit " each server's own logs are on the share:"
  emit "   <backup_base>/logs/<backup id>/restore_*/   restore"
  emit "   <base_dir>/logs/<run id>/                   dump"
fi
sub
kv "logs" "$PIPELINE_LOG_DIR/"

if [[ $PIPELINE_OK -eq 1 ]]; then
  banner " RESULT ok run=${RUN_STAMP} servers=${SERVER_COUNT} ok=${#OK_SERVERS[@]} failed=0 sync=${SYNC_STATE} cleanup=${CLEANUP_STATE} dur_s=$(( $(date +%s) - START_EPOCH )) warn=${WARN_COUNT}"
else
  banner " RESULT failed run=${RUN_STAMP} servers=${SERVER_COUNT} ok=${#OK_SERVERS[@]} failed=${#FAILED_SERVERS[@]} sync=${SYNC_STATE} cleanup=${CLEANUP_STATE} dur_s=$(( $(date +%s) - START_EPOCH )) warn=${WARN_COUNT}"
fi

publish_logs

# ═══════════════════════════════════════════════════════════════════════════
# PART 13  SHUTDOWN
#
# After publish_logs, always: a VM that powers off with its only log on local
# disk has thrown the run away.
# ═══════════════════════════════════════════════════════════════════════════

trap - ERR INT TERM

if [[ $NO_SHUTDOWN -eq 1 ]]; then
  echo " shutdown skipped (--no-shutdown)"
elif [[ $PIPELINE_OK -eq 0 && "${SHUTDOWN_ON_FAILURE:-1}" != "1" ]]; then
  echo " shutdown skipped: the run was incomplete and SHUTDOWN_ON_FAILURE=0"
elif command -v shutdown >/dev/null 2>&1; then
  echo " shutting down in ${SHUTDOWN_DELAY_MIN} minutes — cancel with: shutdown -c"
  shutdown -h "+${SHUTDOWN_DELAY_MIN}" "pipeline run $RUN_STAMP complete" || \
    echo " [WARN] shutdown could not be scheduled"
else
  echo " [WARN] no shutdown command — the VM stays up"
fi

[[ $PIPELINE_OK -eq 1 ]] || exit 1
exit 0
