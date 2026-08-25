#!/usr/bin/env bash
#
# stream-scripts/backup_sync.sh — copy the latest logical dumps to the second share
#
# One archive per database — the newest — copied from each server's dump tree to
# its destination on the second share, verified against its checksum, then
# retention applied to the DESTINATION only. Nothing on the source is ever
# deleted by this script.
#
# Servers, sources and destinations all come from the same JSON file final.sh
# uses: base_dir is the source, sync_dest is the destination.
# Docs: stream-scripts/README-dr.md
#
#   PART 1   configuration
#   PART 2   log engine
#   PART 3   failure handling
#   PART 4   probes
#   PART 5   usage and arguments
#   PART 6   single-instance lock
#   PART 7   identity and paths
#   PART 8   pre-flight            9 checks
#   PART 9   discover              step 1/4
#   PART 10  copy                  step 2/4
#   PART 11  retention             step 3/4
#   PART 12  prune logs            step 4/4
#   PART 13  summary
#
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# PART 1  CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

# The server list. Per entry this script reads:
#   base_dir    the source: where logical.sh published that server's dumps
#   sync_dest   the destination on the second share
#
# sync_dest is OPT-IN: an entry without it is not copied anywhere, and a config
# where no entry has it means there is nothing for this script to do. There is
# deliberately no default destination — inventing one would start copying data
# somewhere nobody asked for.
CONFIG_FILE="/Data/script/servers.json"

SOURCE_MOUNT_POINT="/livestorage"                    # where base_dir lives
DEST_MOUNT_POINT="/southstorage"                     # where sync_dest lives

# This script's own logs, published here as one directory per run.
SYNC_LOG_BASE="/southstorage/backup_latest/_sync_logs"
DEST_LOG_DAYS=30

ARCHIVE_GLOB="*.tar.gz"

# Destination retention, in whole days. 0 would delete a copy the moment it was
# made, so the pre-flight refuses it.
DEST_RETENTION_DAYS=3

LOCAL_STAGE="/Data/dbvault-stage"                    # logs only, during the run
KEEP_LOCAL_DAYS=14                                   # prune logs stranded here

# Directories inside a server's dump tree that are not databases.
NON_DB_DIRS="logs manifests _cleanup_logs"

LOCK_DIR="/var/lock/dbvault"

DRY_RUN=0

# ═══════════════════════════════════════════════════════════════════════════
# PART 2  LOG ENGINE
#
#   HH:MM:SS LEVEL [phase     nn/nn] message
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
CHECK_TOTAL=9
PHASE_EPOCH=0

phase() { PHASE="$1"; STEP="${2:--}"; PHASE_EPOCH="$(date +%s)"; }
check() { PHASE="preflight"; CHECK_N=$((CHECK_N + 1))
          STEP="$(printf '%02d/%02d' "$CHECK_N" "$CHECK_TOTAL")"; }

elapsed() {
  local d=$(( $(date +%s) - $1 ))
  if (( d < 60 )); then printf '%ds' "$d"; else printf '%dm%02ds' $((d / 60)) $((d % 60)); fi
}

hsize() {
  numfmt --to=iec-i --suffix=B "$1" 2>/dev/null \
    || awk -v b="$1" 'BEGIN { printf "%.1fGiB", b/1073741824 }'
}

# ═══════════════════════════════════════════════════════════════════════════
# PART 3  FAILURE HANDLING
# ═══════════════════════════════════════════════════════════════════════════

START_EPOCH="$(date +%s)"
SERVER_COUNT=0
SYNC_COUNT=0
NOT_CONFIGURED=""
COPIED=0
SKIPPED=0
FAILED=0
COPIED_BYTES=0
DELETED=0
FREED_BYTES=0
PRUNED_LOGS=0
COPY_PAIR_COUNT=0
MISSING_SERVERS=0
EMPTY_DBS=0
PUBLISHED_LOGS=0
CURRENT=""
SERVER_NAMES=()
SOURCE_DIRS=()
DEST_DIRS=()

publish_logs() {
  [[ "$PUBLISHED_LOGS" == "1" ]] && return 0
  PUBLISHED_LOGS=1
  [[ -n "${DEST_LOG_DIR:-}" ]] || return 0

  # An unmounted destination is an empty local directory that mkdir -p is happy
  # to populate — on the root filesystem, where nobody looks.
  if ! mountpoint -q "$DEST_MOUNT_POINT" 2>/dev/null; then
    printf '%s\n' " [WARN] destination not mounted — logs kept in $LOCAL_STAGE:" >&2
    printf '%s\n' "        $RUN_LOG" >&2
    return 0
  fi

  mkdir -p "$DEST_LOG_DIR" 2>/dev/null || {
    printf '%s\n' " [WARN] cannot create $DEST_LOG_DIR — logs kept in $LOCAL_STAGE" >&2
    return 0
  }

  local pair src dst kept=0
  for pair in "${RUN_LOG}:sync.log" \
              "${ERROR_LOG}:errors.log"; do
    src="${pair%:*}"; dst="${pair##*:}"
    [[ -n "$src" && -f "$src" ]] || continue
    if cp "$src" "${DEST_LOG_DIR}/${dst}" 2>/dev/null \
       && [[ -s "${DEST_LOG_DIR}/${dst}" ]]; then
      rm -f "$src" 2>/dev/null || true
    else
      kept=$((kept + 1))
    fi
  done

  if [[ $kept -gt 0 ]]; then
    printf '%s\n' " [WARN] $kept log(s) could not be published — kept in $LOCAL_STAGE" >&2
  fi
  printf '%s\n' " logs published to $DEST_LOG_DIR"
}

# Safety net only. A successful run leaves nothing in LOCAL_STAGE: the log is
# published to the share and the local copy dropped. This clears only what an
# earlier run kept BECAUSE the share was unreachable.
# Never touches this run's files: -mtime is in whole days.
prune_local() {
  local f n=0
  while IFS= read -r f; do
    rm -f "$f" 2>/dev/null && n=$((n + 1))
  done < <(find "$LOCAL_STAGE" -maxdepth 1 -type f -name 'backup_sync_*.log' \
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
  banner " BACKUP SYNC FAILED"
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

  PHASE="cleanup"; STEP="-"

  # Only this run's half-finished transfers, and only under the destinations
  # this run actually resolved. A .part is invisible to every consumer, but it
  # would also be permanent — no later run knows it is there.
  local d f n=0
  if [[ ${#DEST_DIRS[@]} -gt 0 ]] && mountpoint -q "$DEST_MOUNT_POINT" 2>/dev/null; then
    for d in "${DEST_DIRS[@]}"; do
      [[ -n "$d" && -d "$d" ]] || continue
      while IFS= read -r f; do
        rm -f "$f" 2>/dev/null && n=$((n + 1))
      done < <(find "$d" -type f -name '*.tar.gz.part' 2>/dev/null || true)
    done
    [[ $n -gt 0 ]] && info "removed $n unfinished transfer(s)"
  fi

  if [[ $COPIED -gt 0 ]]; then
    warn "$COPIED archive(s) WERE copied and verified before this failure"
    cont "they are complete; the run as a whole is not"
  fi

  sub
  kv "error log" "${ERROR_LOG:-(none)}"
  banner " RESULT failed phase=${at% *} step=${at#* } copied=${COPIED} skipped=${SKIPPED} failed=${FAILED} deleted=${DELETED} dur_s=$(( $(date +%s) - START_EPOCH )) warn=${WARN_COUNT}"

  publish_logs
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

free_mb() { df -BM --output=avail "$1" | tail -1 | tr -dc '0-9'; }

writable() {
  local probe="$1/.probe_$$"
  touch "$probe" 2>/dev/null || return 1
  rm -f "$probe"
  return 0
}

fsize() { stat -c%s "$1" 2>/dev/null || echo 0; }

jqv() { jq -r "$1" "$CONFIG_FILE" 2>/dev/null || true; }

is_non_db() {
  local name="$1" d
  [[ "$name" == .* || "$name" == _* ]] && return 0
  for d in $NON_DB_DIRS; do
    [[ "$name" == "$d" ]] && return 0
  done
  return 1
}

# Newest finished archive in a directory. .part files cannot match the glob, and
# -printf '%T@' orders on mtime rather than on the name, so this is independent
# of the producer's naming convention.
newest_archive() {
  find "$1" -maxdepth 1 -type f -name "$ARCHIVE_GLOB" -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# PART 5  USAGE AND ARGUMENTS
# ═══════════════════════════════════════════════════════════════════════════

usage() {
  cat <<EOF
Usage: $0 [--config=PATH] [--retention_days=N] [--dry-run]

  Step 1  discover   find the newest archive of every database
  Step 2  copy       copy and verify it onto the second share
  Step 3  retention  delete destination archives older than N days
  Step 4  prune      drop this script's own old logs

  --config=PATH        server list, default: $CONFIG_FILE
  --retention_days=N   destination retention, default: $DEST_RETENTION_DAYS
  --dry-run            report every copy and delete without performing any

Per entry in the config file:
  base_dir    required  the source — where logical.sh published the dumps
  sync_dest   opt-in    the destination on the second share

An entry without sync_dest is not copied anywhere. If no entry has one, there
is nothing to sync and this exits without touching anything.

Nothing on the source is ever deleted by this script. Source-side retention
belongs to db_cleanup.sh.
EOF
  trap - ERR INT TERM
  exit 1
}

argfail() { echo "[ERROR] $1" >&2; trap - ERR INT TERM; exit 1; }

for arg in "$@"; do
  case "$arg" in
    --config=*)          CONFIG_FILE="${arg#*=}" ;;
    --retention_days=*)  DEST_RETENTION_DAYS="${arg#*=}" ;;
    --dry-run)           DRY_RUN=1 ;;
    -h|--help)           usage ;;
    *) echo "[ERROR] Unknown argument: $arg" >&2; usage ;;
  esac
done

[[ -f "$CONFIG_FILE" ]] || argfail "Config file not found: $CONFIG_FILE"
[[ "$DEST_RETENTION_DAYS" =~ ^[0-9]+$ ]] \
  || argfail "--retention_days must be a whole number: $DEST_RETENTION_DAYS"
command -v jq >/dev/null 2>&1 || argfail "jq is required but not installed"

# ═══════════════════════════════════════════════════════════════════════════
# PART 6  SINGLE-INSTANCE LOCK
# ═══════════════════════════════════════════════════════════════════════════

mkdir -p "$LOCK_DIR" "$LOCAL_STAGE" 2>/dev/null || true
exec 200>"${LOCK_DIR}/backup_sync.lock"
if ! flock -n 200; then
  echo "[ERROR] Another backup_sync run is already in progress." >&2
  trap - ERR INT TERM
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 7  IDENTITY AND PATHS
# ═══════════════════════════════════════════════════════════════════════════

RUN_STAMP="$(date +%Y%m%d_%H%M%S)"
RUN_LOG="${LOCAL_STAGE}/backup_sync_${RUN_STAMP}.log"
ERROR_LOG="${LOCAL_STAGE}/backup_sync_${RUN_STAMP}_errors.log"
DEST_LOG_DIR="${SYNC_LOG_BASE}/${RUN_STAMP}"

mkdir -p "$LOCAL_STAGE" 2>/dev/null || {
  echo "[ERROR] Failed to create $LOCAL_STAGE" >&2
  trap - ERR INT TERM; exit 1; }

printf 'errors for backup sync %s\n\n' "$RUN_STAMP" > "$ERROR_LOG"

banner " BACKUP SYNC RUN  $RUN_STAMP"
kv "started"   "$(date '+%F %T %Z')"
kv "host"      "$(hostname -s 2>/dev/null || echo unknown)"
kv "mode"      "$([[ $DRY_RUN -eq 1 ]] && echo 'DRY RUN — nothing is copied or deleted' || echo 'live')"
kv "config"    "$CONFIG_FILE"
kv "source"    "under $SOURCE_MOUNT_POINT — each server's base_dir"
kv "dest"      "under $DEST_MOUNT_POINT — each server's sync_dest"
kv "retention" "${DEST_RETENTION_DAYS} day(s), destination only"
kv "logs"      "$LOCAL_STAGE during the run, published at the end"
sub

prune_local

# ═══════════════════════════════════════════════════════════════════════════
# PART 8  PRE-FLIGHT
# ═══════════════════════════════════════════════════════════════════════════

phase preflight
PREFLIGHT_EPOCH="$PHASE_EPOCH"

check
if [[ $EUID -ne 0 ]]; then
  nok "user privileges" "NOT ROOT"
  cont "both shares are usually mounted for root only — reads or writes may fail"
else
  ok "user privileges"
fi

check
for cmd in jq cp mv rm find sort stat sha256sum awk df mountpoint flock basename; do
  command -v "$cmd" >/dev/null 2>&1 \
    || die "$(leader 'required binaries' 'MISSING')" "not found in PATH: $cmd"
done
ok "required binaries"

# The whole config is read and validated here, into arrays, so a bad entry
# cannot be discovered after part of the copy set has already moved — and so
# editing the file mid-run cannot change what this run does.
check
jq empty "$CONFIG_FILE" >/dev/null 2>&1 \
  || die "$(leader 'config parses' 'INVALID JSON')" "$CONFIG_FILE"
[[ "$(jqv 'type')" == "array" ]] \
  || die "$(leader 'config parses' 'NOT AN ARRAY')" "expected an array of server objects"
SERVER_COUNT="$(jqv 'length')"
[[ "$SERVER_COUNT" =~ ^[0-9]+$ && "$SERVER_COUNT" -gt 0 ]] \
  || die "$(leader 'config parses' 'EMPTY')" "no entries in $CONFIG_FILE"

PROBLEMS=0
for i in $(seq 0 $((SERVER_COUNT - 1))); do
  n="$(jqv ".[$i].server_name // empty")"
  s="$(jqv ".[$i].base_dir // empty")"
  d="$(jqv ".[$i].sync_dest // empty")"
  label="entry $((i + 1))/$SERVER_COUNT"

  if [[ -z "$n" || -z "$s" ]]; then
    erro "$(leader "$label" 'INCOMPLETE')"
    cerr "server_name='$n' base_dir='$s' — both are required"
    PROBLEMS=$((PROBLEMS + 1))
    continue
  fi
  # Opt-in: no sync_dest, no copy. Counted and named, so a server that was
  # meant to be synced and lost its key is visible rather than silently absent.
  if [[ -z "$d" ]]; then
    NOT_CONFIGURED="${NOT_CONFIGURED}${n} "
    continue
  fi
  s="${s%/}"; d="${d%/}"

  # Both mounts get the same treatment as everywhere else: a path outside its
  # mount is an ordinary writable local directory, so the copies would land on
  # the root filesystem and the retention pass would expire real files from
  # wherever they did land.
  if [[ "$s" != "$SOURCE_MOUNT_POINT"/* ]]; then
    erro "$(leader "$label" 'SOURCE OFF THE SHARE')"
    cerr "base_dir '$s' is not under $SOURCE_MOUNT_POINT"
    PROBLEMS=$((PROBLEMS + 1))
  fi
  if [[ "$d" != "$DEST_MOUNT_POINT"/* ]]; then
    erro "$(leader "$label" 'DEST OFF THE SHARE')"
    cerr "sync_dest '$d' is not under $DEST_MOUNT_POINT"
    PROBLEMS=$((PROBLEMS + 1))
  fi
  if [[ "$s" == "$d" ]]; then
    erro "$(leader "$label" 'SOURCE IS THE DEST')"
    cerr "'$s' — copying a tree onto itself and then expiring it deletes backups"
    PROBLEMS=$((PROBLEMS + 1))
  fi

  SERVER_NAMES+=("$n"); SOURCE_DIRS+=("$s"); DEST_DIRS+=("$d")
done

[[ $PROBLEMS -eq 0 ]] \
  || die "$(leader 'config parses' "$PROBLEMS PROBLEM(S)")" \
         "listed above; nothing has been copied or deleted"

SYNC_COUNT=${#SERVER_NAMES[@]}
val "config parses" "$SERVER_COUNT entry/ies, $SYNC_COUNT with sync_dest"
[[ -n "$NOT_CONFIGURED" ]] && cont "no sync_dest, not copied: $NOT_CONFIGURED"

# Not an error: a config with no sync_dest anywhere is a deliberate statement
# that the dumps live on the primary share only. Exit 0 so the pipeline records
# a skipped step rather than a failed one.
if [[ $SYNC_COUNT -eq 0 ]]; then
  STEP="-"
  emit ""
  banner " BACKUP SYNC NOT CONFIGURED"
  kv "config"   "$CONFIG_FILE"
  kv "entries"  "$SERVER_COUNT, none with sync_dest"
  kv "effect"   "nothing copied; the dumps stay on the primary share"
  sub
  emit " to sync a server, give its entry a sync_dest under $DEST_MOUNT_POINT:"
  emit "   \"sync_dest\": \"${DEST_MOUNT_POINT}/backup_latest/<server_name>\""
  sub
  banner " RESULT ok servers=${SERVER_COUNT} copied=0 skipped=0 failed=0 deleted=0 bytes=0 dur_s=$(( $(date +%s) - START_EPOCH )) warn=${WARN_COUNT}"
  publish_logs
  trap - ERR INT TERM
  exit 0
fi

check
mountpoint -q "$SOURCE_MOUNT_POINT" \
  || die "$(leader 'source share' 'NOT MOUNTED')" \
         "expected a mount at $SOURCE_MOUNT_POINT" \
         "an unmounted share is an empty directory: every server would look" \
         "like it had produced no dumps at all"
ok "source share"

check
mountpoint -q "$DEST_MOUNT_POINT" \
  || die "$(leader 'destination share' 'NOT MOUNTED')" \
         "expected a mount at $DEST_MOUNT_POINT" \
         "writing there unmounted would fill the root filesystem"
if [[ $DRY_RUN -eq 1 ]]; then
  skp "destination share" "mounted (not writing, dry run)"
else
  for i in $(seq 0 $((${#DEST_DIRS[@]} - 1))); do
    mkdir -p "${DEST_DIRS[$i]}" 2>/dev/null \
      || die "$(leader 'destination share' 'MKDIR FAILED')" "${DEST_DIRS[$i]}"
    writable "${DEST_DIRS[$i]}" \
      || die "$(leader 'destination share' 'NOT WRITABLE')" \
             "mounted but not writable: ${DEST_DIRS[$i]}" \
             "stale handle, auth failure, or uid=/gid=/file_mode= mount options"
  done
  ok "destination share"
fi

# 0 days would delete an archive on the same day it was copied, leaving the
# second share empty until the next run — the opposite of the point.
check
[[ "$DEST_RETENTION_DAYS" -ge 1 ]] \
  || die "$(leader 'retention setting' "${DEST_RETENTION_DAYS} DAYS")" \
         "must be at least 1: a copy made today would be deleted today"
val "retention setting" "${DEST_RETENTION_DAYS} day(s)"

check
writable "$LOCAL_STAGE" \
  || die "$(leader 'local stage writable' 'NO')" "not writable: $LOCAL_STAGE"
ok "local stage writable"

check
if [[ $DRY_RUN -eq 1 ]]; then
  skp "sha256 utility" "not tested (dry run)"
else
  PROBE_FILE="${DEST_DIRS[0]}/.sha256_probe_$$"
  echo probe > "$PROBE_FILE" 2>/dev/null \
    || die "$(leader 'sha256 utility' 'WRITE FAILED')" "cannot write to ${DEST_DIRS[0]}"
  sha256sum "$PROBE_FILE" >/dev/null 2>&1 \
    || { rm -f "$PROBE_FILE"; die "$(leader 'sha256 utility' 'FAILED')" \
           "sha256sum cannot hash a file on $DEST_MOUNT_POINT"; }
  rm -f "$PROBE_FILE"
  ok "sha256 utility"
fi

check
STALE_PARTS=0
for i in $(seq 0 $((${#DEST_DIRS[@]} - 1))); do
  [[ -d "${DEST_DIRS[$i]}" ]] || continue
  STALE_PARTS=$(( STALE_PARTS + $(find "${DEST_DIRS[$i]}" -type f -name '*.tar.gz.part' 2>/dev/null | wc -l) ))
done
if [[ "$STALE_PARTS" -gt 0 ]]; then
  nok "stale transfers" "$STALE_PARTS FOUND"
  cont "left by an interrupted run; each is removed as its name is reused"
else
  ok "stale transfers"
fi

STEP="-"
info "$CHECK_N checks passed, ${WARN_COUNT} warning(s)   ($(elapsed "$PREFLIGHT_EPOCH"))"
sub

# ═══════════════════════════════════════════════════════════════════════════
# PART 9  DISCOVER  1/4
#
# The whole copy set is resolved before anything is written, so the destination
# can be sized once instead of being discovered full halfway through.
# ═══════════════════════════════════════════════════════════════════════════

phase discover 1/4

COPY_PLAN=()                                              # server|db|source|bytes|destdir
PLAN_BYTES=0

# Over the entries that HAVE a destination, not over the whole config: the
# arrays only hold the ones that opted in.
for i in $(seq 0 $((SYNC_COUNT - 1))); do
  server="${SERVER_NAMES[$i]}"
  src_root="${SOURCE_DIRS[$i]}"
  dst_root="${DEST_DIRS[$i]}"

  if [[ ! -d "$src_root" ]]; then
    nok "$server" "NO SOURCE DIRECTORY"
    cont "expected $src_root"
    MISSING_SERVERS=$((MISSING_SERVERS + 1))
    continue
  fi

  server_dbs=0
  while IFS= read -r db_dir; do
    [[ -n "$db_dir" ]] || continue
    db="$(basename "$db_dir")"
    is_non_db "$db" && continue

    latest="$(newest_archive "$db_dir")"
    if [[ -z "$latest" ]]; then
      nok "${server}/${db}" "NO ARCHIVE"
      EMPTY_DBS=$((EMPTY_DBS + 1))
      continue
    fi

    bytes="$(fsize "$latest")"
    COPY_PLAN+=("${server}|${db}|${latest}|${bytes}|${dst_root}/${db}")
    PLAN_BYTES=$(( PLAN_BYTES + bytes ))
    server_dbs=$((server_dbs + 1))
  done < <(find "$src_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

  val "$server" "$server_dbs database(s) -> $dst_root"
done

COPY_PAIR_COUNT=${#COPY_PLAN[@]}
[[ $COPY_PAIR_COUNT -gt 0 ]] \
  || die "$(leader 'copy set' 'EMPTY')" \
         "no archive was found for any database of any configured server" \
         "either nothing has been dumped yet, or the base_dir values in" \
         "$CONFIG_FILE do not point where logical.sh published"

sub
val "copy set" "$COPY_PAIR_COUNT archive(s), $(hsize "$PLAN_BYTES") before de-duplication"
[[ $MISSING_SERVERS -gt 0 ]] && cont "$MISSING_SERVERS server(s) had no source directory"
[[ $EMPTY_DBS -gt 0 ]] && cont "$EMPTY_DBS database directory/ies held no archive"

DEST_FREE_MB="$(free_mb "$DEST_MOUNT_POINT")"
NEED_MB=$(( PLAN_BYTES / 1048576 + 1 ))
if [[ "${DEST_FREE_MB:-0}" -lt "$NEED_MB" ]]; then
  # Not fatal: most of the set is usually already there and will be skipped,
  # and the retention pass has not run yet. A copy that genuinely does not fit
  # fails on its own and is reported.
  nok "destination space" "TIGHT"
  cont "worst case ${NEED_MB}MB, free ${DEST_FREE_MB:-0}MB"
  cont "already-present archives are skipped, so the real need is usually less"
else
  val "destination space" "worst case ${NEED_MB}MB / free ${DEST_FREE_MB}MB"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 10  COPY  2/4
#
# Copy to <name>.part, verify at the destination, then rename. A .part never
# matches the archive glob, so no consumer and no retention pass can see a
# half-written file as a backup.
# ═══════════════════════════════════════════════════════════════════════════

phase copy 2/4

for entry in "${COPY_PLAN[@]}"; do
  IFS='|' read -r server db src bytes dest_dir <<< "$entry"
  CURRENT="${server}/${db}"

  name="$(basename "$src")"
  dest="${dest_dir}/${name}"

  # Same name and same size: already carried over by an earlier run. Size is
  # enough here — the name embeds the run id, so a same-name archive is the
  # same archive.
  if [[ -f "$dest" && "$(fsize "$dest")" == "$bytes" ]]; then
    skp "${server}/${db}" "already present"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    val "${server}/${db}" "would copy $name ($(hsize "$bytes"))"
    COPIED=$((COPIED + 1))
    COPIED_BYTES=$(( COPIED_BYTES + bytes ))
    continue
  fi

  if ! mkdir -p "$dest_dir" 2>>"$ERROR_LOG"; then
    erro "$(leader "${server}/${db}" 'MKDIR FAILED')"
    cerr "$dest_dir"
    FAILED=$((FAILED + 1))
    continue
  fi

  rm -f "${dest}.part" 2>/dev/null || true
  if ! cp "$src" "${dest}.part" 2>>"$ERROR_LOG"; then
    erro "$(leader "${server}/${db}" 'COPY FAILED')"
    cerr "$src -> ${dest}.part"
    rm -f "${dest}.part" 2>/dev/null || true
    FAILED=$((FAILED + 1))
    continue
  fi
  sync "${dest}.part" 2>/dev/null || true

  # Prefer the checksum logical.sh wrote: it proves the copy matches what was
  # dumped, not merely what the source file currently reads as. Size is the
  # fallback for archives that predate the sidecars.
  verified=""
  if [[ -s "${src}.sha256" ]]; then
    expected="$(awk '{print $1; exit}' "${src}.sha256" || true)"
    actual="$(sha256sum "${dest}.part" 2>>"$ERROR_LOG" | awk '{print $1}')"
    if [[ -n "$expected" && "$expected" == "$actual" ]]; then
      verified="sha256"
    else
      erro "$(leader "${server}/${db}" 'CHECKSUM MISMATCH')"
      cerr "expected $expected"
      cerr "actual   ${actual:-(unreadable)}"
      cerr "the copy on the second share is corrupt and has been removed"
      rm -f "${dest}.part" 2>/dev/null || true
      FAILED=$((FAILED + 1))
      continue
    fi
  else
    if [[ "$(fsize "${dest}.part")" == "$bytes" ]]; then
      verified="size"
    else
      erro "$(leader "${server}/${db}" 'SIZE MISMATCH')"
      cerr "source $bytes bytes, copy $(fsize "${dest}.part") bytes"
      rm -f "${dest}.part" 2>/dev/null || true
      FAILED=$((FAILED + 1))
      continue
    fi
  fi

  if ! mv "${dest}.part" "$dest" 2>>"$ERROR_LOG"; then
    erro "$(leader "${server}/${db}" 'RENAME FAILED')"
    rm -f "${dest}.part" 2>/dev/null || true
    FAILED=$((FAILED + 1))
    continue
  fi

  # The sidecar travels with the archive, so the second share can be verified
  # on its own later without reaching back to the first.
  [[ -s "${src}.sha256" ]] && cp "${src}.sha256" "${dest}.sha256" 2>>"$ERROR_LOG" \
    || true

  COPIED=$((COPIED + 1))
  COPIED_BYTES=$(( COPIED_BYTES + bytes ))
  val "${server}/${db}" "$(hsize "$bytes") verified by $verified"
done
CURRENT=""

sub
if [[ $FAILED -gt 0 ]]; then
  nok "copied" "$COPIED  ($SKIPPED skipped, $FAILED failed)"
else
  val "copied" "$COPIED  ($SKIPPED already present)  $(hsize "$COPIED_BYTES")  ($(elapsed "$PHASE_EPOCH"))"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 11  RETENTION  3/4
#
# Destination only. The newest archive in a directory is never deleted, however
# old it is: a server that stops producing dumps must not have its last copy
# aged out — that is precisely when the copy matters.
# ═══════════════════════════════════════════════════════════════════════════

phase retention 3/4

for i in $(seq 0 $((SYNC_COUNT - 1))); do
  server="${SERVER_NAMES[$i]}"
  dst_root="${DEST_DIRS[$i]}"
  [[ -d "$dst_root" ]] || continue

  while IFS= read -r db_dir; do
    [[ -n "$db_dir" ]] || continue
    db="$(basename "$db_dir")"
    is_non_db "$db" && continue
    CURRENT="${server}/${db}"

    keep="$(newest_archive "$db_dir")"
    db_deleted=0

    while IFS= read -r old; do
      [[ -n "$old" ]] || continue
      [[ "$old" == "$keep" ]] && continue          # never the newest

      bytes="$(fsize "$old")"
      if [[ $DRY_RUN -eq 1 ]]; then
        cont "would delete $(basename "$old") ($(hsize "$bytes"))"
      elif rm -f "$old" 2>>"$ERROR_LOG"; then
        rm -f "${old}.sha256" 2>/dev/null || true
        cont "deleted $(basename "$old") ($(hsize "$bytes"))"
      else
        erro "$(leader "${server}/${db}" 'DELETE FAILED')"
        cerr "$old"
        FAILED=$((FAILED + 1))
        continue
      fi
      DELETED=$((DELETED + 1))
      FREED_BYTES=$(( FREED_BYTES + bytes ))
      db_deleted=$((db_deleted + 1))
    done < <(find "$db_dir" -maxdepth 1 -type f -name "$ARCHIVE_GLOB" \
               -mtime "+${DEST_RETENTION_DAYS}" 2>/dev/null | sort || true)

    [[ $db_deleted -gt 0 ]] && val "${server}/${db}" "$db_deleted expired"
  done < <(find "$dst_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
done
CURRENT=""

sub
val "retention" "$DELETED deleted, $(hsize "$FREED_BYTES") freed"

# ═══════════════════════════════════════════════════════════════════════════
# PART 12  PRUNE LOGS  4/4
#
# This script's own published logs. Deliberately last: this run's log directory
# is only created afterwards, by publish_logs, so it can never be a candidate
# for its own pass.
# ═══════════════════════════════════════════════════════════════════════════

phase prune 4/4

if [[ -d "$SYNC_LOG_BASE" ]]; then
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    if [[ $DRY_RUN -eq 1 ]]; then
      cont "would remove log directory $(basename "$d")"
    else
      rm -rf "$d" 2>>"$ERROR_LOG" || { nok "log prune" "FAILED on $d"; continue; }
    fi
    PRUNED_LOGS=$((PRUNED_LOGS + 1))
  done < <(find "$SYNC_LOG_BASE" -mindepth 1 -maxdepth 1 -type d \
             -mtime "+${DEST_LOG_DAYS}" 2>/dev/null | sort || true)
fi
val "log prune" "$PRUNED_LOGS directory/ies older than ${DEST_LOG_DAYS} days"

# ═══════════════════════════════════════════════════════════════════════════
# PART 13  SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

PHASE="done"; STEP="-"

emit ""
if [[ $FAILED -gt 0 ]]; then
  banner " BACKUP SYNC INCOMPLETE"
elif [[ $DRY_RUN -eq 1 ]]; then
  banner " BACKUP SYNC DRY RUN COMPLETE — NOTHING WAS CHANGED"
else
  banner " BACKUP SYNC OK"
fi
kv "duration" "$(elapsed "$START_EPOCH")"
kv "config"   "$CONFIG_FILE"
kv "servers"  "$SERVER_COUNT in config, $SYNC_COUNT with sync_dest, $MISSING_SERVERS with no dumps"
kv "copy set" "$COPY_PAIR_COUNT archive(s)"
kv "copied"   "$COPIED  $(hsize "$COPIED_BYTES")"
kv "skipped"  "$SKIPPED already present"
kv "failed"   "$FAILED"
kv "deleted"  "$DELETED  $(hsize "$FREED_BYTES") freed"
kv "warnings" "$WARN_COUNT"
sub
kv "logs" "$DEST_LOG_DIR/"

if [[ $FAILED -gt 0 ]]; then
  banner " RESULT failed servers=${SERVER_COUNT} copied=${COPIED} skipped=${SKIPPED} failed=${FAILED} deleted=${DELETED} bytes=${COPIED_BYTES} dur_s=$(( $(date +%s) - START_EPOCH )) warn=${WARN_COUNT}"
  publish_logs
  trap - ERR INT TERM
  exit 1
fi

banner " RESULT ok servers=${SERVER_COUNT} copied=${COPIED} skipped=${SKIPPED} failed=0 deleted=${DELETED} bytes=${COPIED_BYTES} dur_s=$(( $(date +%s) - START_EPOCH )) warn=${WARN_COUNT}"

publish_logs

trap - ERR INT TERM
exit 0
