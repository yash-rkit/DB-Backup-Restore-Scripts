#!/usr/bin/env bash
#
# stream-scripts/physical/restore.sh — verify + restore + prepare + binlog apply
#
# ERASES MYSQL_DATADIR. Take a VM snapshot first.
# Docs: stream-scripts/physical/README.md
#
#   PART 1   configuration
#   PART 2   log engine
#   PART 3   failure handling
#   PART 4   probes
#   PART 5   usage and arguments
#   PART 6   single-instance lock
#   PART 7   identity and paths
#   PART 8   pre-flight            16 checks
#   PART 9   start point
#   PART 10  dry run               exits
#   PART 11  verify                phase 1/3
#   PART 12  restore               phase 2/3
#   PART 13  binlog apply          phase 3/3
#   PART 14  summary
#
# GTID is OFF, so recovery is by binlog file+position only: no duplicate
# detection, and the apply is ONE-SHOT.
#
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# PART 1  CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

MYSQL_USER="Admin"
MYSQL_PASSWORD=""

SECONDARY_STORAGE_DIR="/livestorage/YK/Restore-VM"   # MUST match backup.sh
SMB_MOUNT_POINT="/livestorage"                       # MUST match backup.sh

LOCAL_STAGE="/Data/dbvault-stage"                    # logs, staged binlogs, staged archive
MYSQL_DATADIR="/Data/mysql"                          # ERASED by this script

# Local logs and previews left behind when the share was unreachable are pruned
# after this many days. Published logs are moved, not copied, so nothing else
# accumulates here.
KEEP_LOCAL_DAYS=14

CONFIRM_WIPE=1                                       # 0 = refuse to run at all

DATADIR_SPACE_PCT=120                                # need, % of source datadir
ARCHIVE_EXPANSION_FACTOR=5                           # fallback: x compressed size

PARALLEL_THREADS=8                                   # xbstream and --decompress
PREPARE_USE_MEMORY="1G"                              # empty = do not pass it

# The archive is COPIED to local disk before the wipe, then extracted from
# there. Two reasons, in order of importance:
#   1. the network leaves the critical path. The wipe happens only once a
#      verified local copy exists, so a share that drops costs a retry rather
#      than a half-populated datadir.
#   2. it is much faster. xbstream reads its stdin serially in small chunks and
#      interleaves thousands of file creations; over SMB every one of those pays
#      link latency. Measured on a 14GiB archive: 71 MiB/s for a flat read of
#      the same file off the same share, 17 MiB/s for xbstream reading it.
# Set to 0 to extract straight off the share (the old behaviour).
STAGE_ARCHIVE=1
ARCHIVE_STAGE_DIR="/Data/dbvault-stage"              # staged .xbstream lives here
KEEP_STAGED_ON_FAILURE=1                             # 1 = a retry skips the copy

# Fold the decompress into the extract: xbstream writes the datadir already
# expanded, so the .zst files are never created and never read back. Saves a
# 1x-compressed write plus a 1x-compressed read, and removes the leftover-.zst
# hazard entirely rather than checking for it afterwards.
# 0 until verified on this host: not every xtrabackup build has it, and a build
# without zstd support fails the same way the two-pass path does.
#   check with:  xbstream --help | grep -i decompress
XBSTREAM_DECOMPRESS=0

# The old value was a hardcoded 60 x 2s. A freshly restored multi-terabyte
# datadir can spend well over two minutes opening tablespaces before it accepts
# a connection, and the wait is cheap compared to redoing the restore.
MYSQL_READY_TIMEOUT=900                              # seconds
MYSQL_READY_INTERVAL=2

BINLOG_PREFIX="binlog"                               # log_bin basename
BINLOG_GLOB="${BINLOG_PREFIX}.[0-9][0-9][0-9][0-9][0-9][0-9]"
BINLOG_FILE_START_POS=4                              # past the 4-byte magic

XTRABACKUP_BIN="/usr/bin/xtrabackup"
XBSTREAM_BIN="/usr/bin/xbstream"
MYSQL_BIN="/usr/bin/mysql"
MYSQLADMIN_BIN="/usr/bin/mysqladmin"
MYSQLBINLOG_BIN="/usr/bin/mysqlbinlog"
MYSQL_SERVICE="mysql"

LOCK_DIR="/var/lock/dbvault"                         # tmpfs; cleared by reboot
STATE_DIR="/var/lib/dbvault"                         # restore marker, persistent

# ═══════════════════════════════════════════════════════════════════════════
# PART 2  LOG ENGINE
#
#   HH:MM:SS LEVEL [phase     nn/nn] message
# ═══════════════════════════════════════════════════════════════════════════

RUN_LOG=""
ERROR_LOG=""
XTRABACKUP_LOG=""
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
CHECK_TOTAL=16
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
#
# One exit path. `exit 1` does NOT fire an ERR trap, so failures call die().
# The advice printed depends on how far the run got: DATADIR_WIPED and
# APPLY_STARTED select it, so no call site has to describe the situation.
# ═══════════════════════════════════════════════════════════════════════════

START_EPOCH="$(date +%s)"
BACKUP_ID=""
MYSQL_WAS_RUNNING=false
DATADIR_WIPED=false
RESTORE_COMPLETE=false
APPLY_STARTED=false
APPLIED_COUNT=0
LAST_APPLIED=""
GAPS=0
PUBLISHED_LOGS=0
DB_COUNT="n/a"
PREPARED_TYPE=""
PREVIEW=""

publish_logs() {
  [[ "$PUBLISHED_LOGS" == "1" ]] && return 0
  PUBLISHED_LOGS=1
  [[ -n "${SECONDARY_LOG_DIR:-}" ]] || return 0

  if ! mountpoint -q "$SMB_MOUNT_POINT" 2>/dev/null; then
    printf '%s\n' " [WARN] share not mounted — logs kept in $LOCAL_STAGE:" >&2
    printf '%s\n' "        $RUN_LOG" >&2
    return 0
  fi

  mkdir -p "$SECONDARY_LOG_DIR" 2>/dev/null || {
    printf '%s\n' " [WARN] cannot create $SECONDARY_LOG_DIR — logs kept in $LOCAL_STAGE" >&2
    return 0
  }
  # MOVED, not copied: two copies of a 30MB+ xtrabackup log per attempt would
  # accumulate on the VM forever. A local copy survives only when the share is
  # unreachable — which is exactly when it is worth having.
  local pair src dst kept=0
  for pair in "${RUN_LOG}:restore.log" \
              "${ERROR_LOG}:restore_errors.log" \
              "${XTRABACKUP_LOG}:xtrabackup.log" \
              "${PREVIEW}:binlog_preview.sql"; do
    src="${pair%:*}"; dst="${pair##*:}"
    [[ -n "$src" && -f "$src" ]] || continue
    if cp "$src" "${SECONDARY_LOG_DIR}/${dst}" 2>/dev/null \
       && [[ -s "${SECONDARY_LOG_DIR}/${dst}" ]]; then
      rm -f "$src" 2>/dev/null || true
    else
      kept=$((kept + 1))
    fi
  done

  if [[ $kept -gt 0 ]]; then
    printf '%s\n' " [WARN] $kept log(s) could not be published — kept in $LOCAL_STAGE" >&2
  fi
  printf '%s\n' " logs published to $SECONDARY_LOG_DIR"
}

# Safety net only. A successful run leaves nothing in LOCAL_STAGE — logs and the
# dry-run preview are moved to the share — so this exists solely to clear what an
# earlier run kept because the share was unreachable.
# Never touches this run's files: -mtime is in whole days.
prune_local() {
  local f n=0
  while IFS= read -r f; do
    rm -f "$f" 2>/dev/null && n=$((n + 1))
  done < <(find "$LOCAL_STAGE" -maxdepth 1 -type f \
             \( -name '*_restore_*.log' -o -name '*_binlog_preview.sql' \) \
             -mtime "+${KEEP_LOCAL_DAYS}" 2>/dev/null || true)
  [[ $n -gt 0 ]] && info "pruned $n local log/preview file(s) older than ${KEEP_LOCAL_DAYS} days"
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
  banner " RESTORE FAILED  ${BACKUP_ID:-(no id)}"
  kv "failed in" "$at"
  if [[ ${INTERRUPTED:-0} -eq 1 ]]; then
    kv "cause" "interrupted — Ctrl-C or kill"
  elif [[ ${DIED:-0} -eq 0 && -n "${FAILED_CMD:-}" ]]; then
    kv "cause"          "uncaught failure — no check reported this"
    kv "failed command" "$FAILED_CMD"
    kv "at line"        "${FAILED_LINE:-?}  (exit ${FAILED_RC:-?})"
  fi
  kv "duration"  "$(elapsed "$START_EPOCH")"
  sub

  if [[ "$APPLY_STARTED" == true ]]; then
    erro "THIS INSTANCE IS PARTIALLY APPLIED"
    cerr "applied $APPLIED_COUNT file(s); last good: ${LAST_APPLIED:-none}"
    cerr ""
    cerr "recovery is file+position only (GTID is off), so this apply CANNOT be"
    cerr "resumed: continuing would duplicate data, skipping would lose it."
    cerr ""
    cerr "1. do NOT let applications use this server — the data is incomplete"
    cerr "2. read the cause in ${ERROR_LOG:-the error log}"
    cerr "3. roll back and retry the whole thing:  ${SELF_CMD:-$0 $BACKUP_ID}"
    if [[ -n "${STAGED_ARCHIVE:-}" && -f "${STAGED_ARCHIVE:-}" ]]; then
      cerr "   (the archive is still staged locally, so the retry skips the copy)"
    else
      cerr "   (re-reads the full archive from the share — allow for the transfer)"
    fi
  elif [[ "$RESTORE_COMPLETE" == true ]]; then
    # The restore itself worked: the datadir holds the backup and mysqld is
    # serving on it. Only the steps after that failed. Saying "the datadir was
    # wiped" here — as this handler used to — sends the operator to redo 25
    # minutes of work that is already done and intact.
    erro "THE RESTORE COMPLETED — THE FAILURE IS AFTER IT"
    cerr "$MYSQL_DATADIR holds the restored backup and MySQL is running on it."
    cerr "no binlogs were applied, so the server sits at the backup anchor."
    cerr ""
    cerr "the restore does NOT need repeating. fix the cause, then apply the"
    cerr "binlogs alone against the marker this run already wrote:"
    cerr "  ${SELF_CMD:-$0 $BACKUP_ID} --binlog-only"
  elif [[ "$DATADIR_WIPED" == true ]]; then
    erro "THE DATADIR WAS ALREADY WIPED WHEN THIS FAILED"
    # Observed, not assumed. This branch used to state "MySQL is stopped"
    # unconditionally, which was false whenever the failure came after the
    # start — and that is precisely when it misleads.
    if mysql_up; then
      cerr "$MYSQL_DATADIR is partially restored and mysqld IS RUNNING on it."
      cerr "stop it before retrying:  systemctl stop $MYSQL_SERVICE"
    else
      cerr "$MYSQL_DATADIR is empty or partially restored, and MySQL is stopped."
      cerr "it is NOT auto-started: mysqld on an incomplete or unprepared datadir"
      cerr "rewrites pages on top of an inconsistent redo state."
    fi
    cerr ""
    if [[ -n "${STAGED_ARCHIVE:-}" && -f "${STAGED_ARCHIVE:-}" ]]; then
      cerr "the verified archive is already staged on local disk — a re-run"
      cerr "checksums it and skips the copy from the share:"
    else
      cerr "the archive on the share is verified and intact — fix the cause and"
      cerr "re-run the same command, which starts over from a clean wipe:"
    fi
    cerr "  ${SELF_CMD:-$0 $BACKUP_ID}"
  elif [[ "$MYSQL_WAS_RUNNING" == true ]] && ! mysql_up; then
    erro "MySQL is stopped, but the datadir was NOT touched"
    cerr "safe to start it again:  systemctl start $MYSQL_SERVICE"
  else
    erro "nothing was modified"
    cerr "retry with:  ${SELF_CMD:-$0 $BACKUP_ID}"
  fi

  # The staged archive is KEPT by default: it is verified, and a retry that can
  # skip the copy from the share turns a 25-minute redo into an 8-minute one.
  if [[ "${KEEP_STAGED_ON_FAILURE:-1}" != "1" \
        && -n "${STAGED_ARCHIVE:-}" && -f "${STAGED_ARCHIVE:-}" ]]; then
    rm -f "$STAGED_ARCHIVE" 2>/dev/null || true
  fi

  [[ -n "${LOCAL_BINLOG_DIR:-}" && -d "$LOCAL_BINLOG_DIR" ]] \
    && rm -rf "$LOCAL_BINLOG_DIR" 2>/dev/null || true

  sub
  kv "error log"      "${ERROR_LOG:-(none)}"
  kv "xtrabackup log" "${XTRABACKUP_LOG:-(none)}"
  banner " RESULT failed id=${BACKUP_ID:-none} phase=${at% *} step=${at#* } applied=${APPLIED_COUNT} dur_s=$(( $(date +%s) - START_EPOCH )) warn=${WARN_COUNT}"

  publish_logs
  exit 1
}

# die <message> [detail...]
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

free_gb()  { df -BG "$1" | awk 'NR==2 {print $4}' | sed 's/G//'; }
# `-p"$MYSQL_PASSWORD"` collapses to a bare `-p` when the password is empty,
# which makes the client PROMPT instead of authenticating with an empty
# password. The long form always carries an `=`, so it never prompts.
# (The password is still visible in `ps` while a client runs — moving these to
# a 0600 --defaults-extra-file is the proper fix, tracked separately.)
mysql_q()  { "$MYSQL_BIN" --user="$MYSQL_USER" --password="$MYSQL_PASSWORD" -NBe "$1" 2>/dev/null; }
mysql_in() { "$MYSQL_BIN" --user="$MYSQL_USER" --password="$MYSQL_PASSWORD"; }

# Whether OUR credentials work, kept separate from whether the server is up.
mysql_auth_ok() {
  "$MYSQL_BIN" --user="$MYSQL_USER" --password="$MYSQL_PASSWORD" \
    -NBe "SELECT 1" >/dev/null 2>>"${ERROR_LOG:-/dev/null}"
}

# Whether the server is answering, WITHOUT depending on credentials.
#
# This is the distinction the old readiness loop missed. A physical restore
# replaces mysql.user with the SOURCE server's accounts, so this host's Admin
# password can be rejected by a server that is up and perfectly healthy. The
# old probe was `mysql ... -e 'SELECT 1' 2>/dev/null` — it discarded the error,
# so ERROR 1045 (up, wrong password) and ERROR 2002 (not listening) were
# indistinguishable, and both were reported as "did not accept connections".
#
# `Access denied` is proof the server is serving: it parsed our handshake to
# reject it. MYSQL_PROBE_ERR carries the real client error for the caller.
MYSQL_PROBE_ERR=""
mysql_serving() {
  # Flattened to one line: this text is printed through cerr, which pads a
  # single leader, so an embedded newline would break the log alignment.
  MYSQL_PROBE_ERR="$("$MYSQLADMIN_BIN" --user="$MYSQL_USER" \
                     --password="$MYSQL_PASSWORD" ping 2>&1 | tr "\n" " ")"
  case "$MYSQL_PROBE_ERR" in
    *"is alive"*)      return 0 ;;
    *"Access denied"*) return 0 ;;
    *1045*)            return 0 ;;
  esac
  return 1
}

# Where mysqld actually writes its errors. Asked of the config, not of the
# server: the server is exactly what is unavailable when this is needed.
mysql_error_log_path() {
  local p
  p="$(my_print_defaults mysqld 2>/dev/null \
       | sed -n 's/^--log[-_]error=//p' | tail -1)"
  [[ -n "$p" && -f "$p" ]] && { printf '%s\n' "$p"; return 0; }
  for p in /var/log/mysql/error.log /var/log/mysqld.log /var/log/mysql/mysqld.log; do
    [[ -f "$p" ]] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

# The thing the operator had to go and find by hand. Printed into the run log at
# the moment of failure, so the published log carries the cause with it.
mysql_error_log_tail() {
  local path n="${1:-25}"
  if ! path="$(mysql_error_log_path)"; then
    cerr "could not locate mysqld's error log (checked my_print_defaults and"
    cerr "the usual paths) — find it with: my_print_defaults mysqld | grep log"
    return 0
  fi
  cerr ""
  cerr "last $n line(s) of $path:"
  local l
  while IFS= read -r l; do cerr "  $l"; done < <(tail -n "$n" "$path" 2>/dev/null)
  return 0
}

mysql_up() {
  systemctl is-active --quiet "$MYSQL_SERVICE" 2>/dev/null && return 0
  systemctl is-active --quiet mysqld           2>/dev/null && return 0
  pgrep -x mysqld >/dev/null 2>&1                          && return 0
  return 1
}

# A dropped CIFS mount reverts to an empty local dir that passes [[ -d ]].
smb_ready() {
  mountpoint -q "$SMB_MOUNT_POINT"            || return 1
  [[ -d "$SECONDARY_STORAGE_DIR" ]]           || return 1
  ls "$SECONDARY_STORAGE_DIR" >/dev/null 2>&1 || return 1
  return 0
}

kf() { [[ -f "$2" ]] && awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$2"; return 0; }
manifest_get() { kf "$1" "$MANIFEST_FILE"; }
marker_get()   { kf "$1" "$RESTORE_MARKER"; }

is_binlog() { [[ "$1" =~ ^${BINLOG_PREFIX}\.[0-9]{6}$ ]]; }

# Leading zeros stripped: bash reads 000042 as OCTAL, 000008 is invalid octal.
seq_of() {
  local s="${1##*.}"
  s="${s#"${s%%[!0]*}"}"
  printf '%s' "${s:-0}"
}

# ═══════════════════════════════════════════════════════════════════════════
# PART 5  USAGE AND ARGUMENTS
# ═══════════════════════════════════════════════════════════════════════════

DRY_RUN=0
SKIP_BINLOG=0
BINLOG_ONLY=0
FROM_BINLOG=""

usage() {
  cat <<EOF
Usage: $0 <backup_id> [--from <binlog>] [--dry-run] [--skip-binlog] [--binlog-only]

  Phase 1  verify   SHA-256 the .xbstream on the share
  Phase 2  restore  wipe the datadir, extract, decompress, PREPARE, start MySQL
  Phase 3  apply    replay the collected binlogs from the backup position

  Phase 2 PERMANENTLY ERASES $MYSQL_DATADIR. Take a VM snapshot first.

  backup_id           as published by backup.sh — 20260820, or 20260820_143005
                      for a second run on the same day
  --from <binlog>     start the apply here instead of the backup anchor
  --dry-run           verify the archive and preview the binlogs. Changes nothing.
  --skip-binlog       phases 1-2 only; stops at the backup point
  --binlog-only       phase 3 only; needs a previous restore of this backup_id

Examples:
  $0 20260820 --dry-run
  $0 20260820
  $0 20260820_143005 --skip-binlog
  $0 20260820_143005 --binlog-only --from ${BINLOG_PREFIX}.000123

Available backups on the share:
EOF
  if [[ -d "$SECONDARY_STORAGE_DIR" ]]; then
    find "$SECONDARY_STORAGE_DIR" -maxdepth 1 -type f -name '*.xbstream' 2>/dev/null \
      | sort | while read -r f; do echo "  $(basename "$f" .xbstream)"; done
  else
    echo "  (share not reachable)"
  fi
  trap - ERR INT TERM
  exit 1
}

argfail() { echo "[ERROR] $1" >&2; trap - ERR INT TERM; exit 1; }

[[ $# -ge 1 ]] || usage
BACKUP_ID="$1"; shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)
      [[ $# -ge 2 ]] || argfail "--from requires a binlog filename"
      FROM_BINLOG="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=1;     shift ;;
    --skip-binlog) SKIP_BINLOG=1; shift ;;
    --binlog-only) BINLOG_ONLY=1; shift ;;
    *) echo "[ERROR] Unknown argument: $1" >&2; usage ;;
  esac
done

[[ "$BACKUP_ID" =~ ^[0-9]{8}(_[0-9]{6})?$ ]] \
  || argfail "Invalid backup ID: $BACKUP_ID (expected YYYYMMDD or YYYYMMDD_HHMMSS)"
[[ $SKIP_BINLOG -eq 0 || $BINLOG_ONLY -eq 0 ]] \
  || argfail "--skip-binlog and --binlog-only are contradictory."
[[ -z "$FROM_BINLOG" || $SKIP_BINLOG -eq 0 ]] \
  || argfail "--from is meaningless with --skip-binlog."
if [[ -n "$FROM_BINLOG" ]] && ! is_binlog "$FROM_BINLOG"; then
  argfail "Invalid binlog filename: $FROM_BINLOG (expected ${BINLOG_PREFIX}.NNNNNN)"
fi

# Every check and phase below tests these, never the raw flags.
DO_RESTORE=1
DO_APPLY=1
[[ $BINLOG_ONLY -eq 1 ]] && DO_RESTORE=0
[[ $SKIP_BINLOG -eq 1 ]] && DO_APPLY=0

# The exact command to re-run, quoted back to the operator by every failure
# path. Built once here so those messages cannot drift from the real argument
# list as flags are added.
SELF_CMD="$0 $BACKUP_ID"

RUN_MODE="full (verify + restore + apply)"
[[ $SKIP_BINLOG -eq 1 ]] && RUN_MODE="restore only (--skip-binlog)"
[[ $BINLOG_ONLY -eq 1 ]] && RUN_MODE="binlog apply only (--binlog-only)"
[[ $DRY_RUN     -eq 1 ]] && RUN_MODE="DRY RUN — $RUN_MODE"

# ═══════════════════════════════════════════════════════════════════════════
# PART 6  SINGLE-INSTANCE LOCK
# ═══════════════════════════════════════════════════════════════════════════

mkdir -p "$LOCK_DIR" "$STATE_DIR" "$LOCAL_STAGE" 2>/dev/null || true
exec 200>"${LOCK_DIR}/restore.lock"
if ! flock -n 200; then
  echo "[ERROR] Another restore is already running." >&2
  trap - ERR INT TERM
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 7  IDENTITY AND PATHS
# ═══════════════════════════════════════════════════════════════════════════

SMB_ARCHIVE="${SECONDARY_STORAGE_DIR}/${BACKUP_ID}.xbstream"
CHECKSUM_FILE="${SECONDARY_STORAGE_DIR}/${BACKUP_ID}.sha256"
MANIFEST_FILE="${SECONDARY_STORAGE_DIR}/${BACKUP_ID}.manifest"
ANCHOR_FILE="${SECONDARY_STORAGE_DIR}/${BACKUP_ID}_binlog_info"
SMB_BINLOG_DIR="${SECONDARY_STORAGE_DIR}/binlog/${BACKUP_ID}"

RESTORE_MARKER="${STATE_DIR}/${BACKUP_ID}_restore_state"
STAGED_ARCHIVE="${ARCHIVE_STAGE_DIR}/${BACKUP_ID}.xbstream"
LOCAL_BINLOG_DIR="${LOCAL_STAGE}/binlog_${BACKUP_ID}"

# Defaulted here so the summary and the failure handler can read it on any path,
# including --binlog-only, which never reaches the verify phase that sets it.
RESTORE_SOURCE="$SMB_ARCHIVE"

RUN_STAMP="$(date +%Y%m%d_%H%M%S)"
RUN_LOG="${LOCAL_STAGE}/${BACKUP_ID}_restore_${RUN_STAMP}.log"
ERROR_LOG="${LOCAL_STAGE}/${BACKUP_ID}_restore_${RUN_STAMP}_errors.log"
XTRABACKUP_LOG="${LOCAL_STAGE}/${BACKUP_ID}_restore_${RUN_STAMP}_xtrabackup.log"
SECONDARY_LOG_DIR="${SECONDARY_STORAGE_DIR}/logs/${BACKUP_ID}/restore_${RUN_STAMP}"

mkdir -p "$LOCAL_STAGE" 2>/dev/null || {
  echo "[ERROR] Failed to create $LOCAL_STAGE" >&2
  trap - ERR INT TERM; exit 1; }

printf 'errors for restore of %s (attempt %s)\n\n' "$BACKUP_ID" "$RUN_STAMP" > "$ERROR_LOG"

banner " RESTORE RUN  $BACKUP_ID"
kv "started"  "$(date '+%F %T %Z')"
kv "host"     "$(hostname -s 2>/dev/null || echo unknown)"
kv "mode"     "$RUN_MODE"
kv "attempt"  "$RUN_STAMP"
kv "archive"  "$SMB_ARCHIVE"
kv "datadir"  "$MYSQL_DATADIR"
kv "from"     "${FROM_BINLOG:-(none, using the backup anchor)}"
kv "marker"   "$RESTORE_MARKER"
kv "logs"     "$LOCAL_STAGE during the run, moved to the share at the end"
sub

prune_local

# ═══════════════════════════════════════════════════════════════════════════
# PART 8  PRE-FLIGHT
# ═══════════════════════════════════════════════════════════════════════════

phase preflight
PREFLIGHT_EPOCH="$PHASE_EPOCH"

check
[[ $EUID -eq 0 ]] || die "$(leader 'user privileges' 'NOT ROOT')" \
                         "this script stops MySQL and rewrites $MYSQL_DATADIR"
ok "user privileges"

check
for cmd in awk sed find sort wc du df stat chown rm sleep basename sha256sum mountpoint flock systemctl; do
  command -v "$cmd" >/dev/null 2>&1 \
    || die "$(leader 'required binaries' 'MISSING')" "not found in PATH: $cmd"
done
for bin in "$XTRABACKUP_BIN" "$XBSTREAM_BIN" "$MYSQL_BIN" "$MYSQLADMIN_BIN" "$MYSQLBINLOG_BIN"; do
  [[ -x "$bin" ]] || die "$(leader 'required binaries' 'MISSING')" "not executable: $bin"
done
ok "required binaries"

# Deliberately before any long-running work: no point reading an archive for an
# hour only to refuse at the wipe.
check
if [[ $DO_RESTORE -eq 0 ]]; then
  skp "wipe switch" "n/a (--binlog-only)"
elif [[ $DRY_RUN -eq 1 ]]; then
  skp "wipe switch" "n/a (dry run)"
elif [[ "${CONFIRM_WIPE:-0}" != "1" ]]; then
  die "$(leader 'wipe switch' 'DISABLED')" \
      "CONFIRM_WIPE=0 — restores are disabled on this server" \
      "this script PERMANENTLY ERASES $MYSQL_DATADIR, and a restore that cannot" \
      "wipe cannot restore, so it stops here." \
      "" \
      "to enable it, set CONFIRM_WIPE=1 in this script — but first confirm you" \
      "have EITHER a VM snapshot of this host OR a forensic copy of the current" \
      "datadir. If the current data is damaged, it is still evidence."
else
  ok "wipe switch"
fi

check
smb_ready || die "$(leader 'smb share' 'UNREACHABLE')" \
                 "not mounted at $SMB_MOUNT_POINT, or $SECONDARY_STORAGE_DIR is" \
                 "missing or unreadable (stale handle?)"
ok "smb share"

# SECONDARY_STORAGE_DIR is a constant here rather than an argument, but an edit
# that moves it off the mount is silent: a path OUTSIDE the mount reads as a
# valid empty directory on the root filesystem, so the run reports 'no archives
# found' rather than 'wrong path'. mountpoint is only ever true for the mount
# point itself, never a subdirectory, so the check has to be a prefix test.
check
[[ "$SECONDARY_STORAGE_DIR" == "$SMB_MOUNT_POINT"/* ]] \
  || die "$(leader 'backup base' 'OFF THE SHARE')" \
         "SECONDARY_STORAGE_DIR is $SECONDARY_STORAGE_DIR" \
         "which is not under the mount point $SMB_MOUNT_POINT" \
         "reading from local disk here would restore whatever happens to be" \
         "at that path, or find nothing and look like a missing backup"
val "backup base" "under $SMB_MOUNT_POINT"

check
ARCHIVE_SIZE="n/a"
ARCHIVE_BYTES=0
if [[ $DO_RESTORE -eq 0 ]]; then
  skp "archive present" "n/a (--binlog-only)"
else
  if [[ ! -f "$SMB_ARCHIVE" ]]; then
    erro "$(leader 'archive present' 'NOT FOUND')"
    cerr "missing: $SMB_ARCHIVE"
    cerr "available backups:"
    while read -r f; do cerr "  $(basename "$f" .xbstream)"; done \
      < <(find "$SECONDARY_STORAGE_DIR" -maxdepth 1 -type f -name '*.xbstream' 2>/dev/null | sort)
    fail_run
  fi
  ARCHIVE_BYTES=$(stat -c%s "$SMB_ARCHIVE")
  ARCHIVE_SIZE="$(hsize "$ARCHIVE_BYTES")"
  val "archive present" "$ARCHIVE_SIZE"
fi

# Manifest first, .sha256 as the fallback. Neither present is a hard refusal:
# restoring an unverified archive over a wiped datadir is not acceptable.
check
EXPECTED_SHA=""
if [[ $DO_RESTORE -eq 0 ]]; then
  skp "expected sha256" "n/a (--binlog-only)"
else
  SHA_FROM=""
  if [[ -f "$MANIFEST_FILE" ]]; then
    EXPECTED_SHA="$(manifest_get archive_sha256)"
    [[ -n "$EXPECTED_SHA" ]] && SHA_FROM="manifest"
  fi
  if [[ -z "$EXPECTED_SHA" && -s "$CHECKSUM_FILE" ]]; then
    EXPECTED_SHA=$(awk '{print $1}' "$CHECKSUM_FILE")
    [[ -n "$EXPECTED_SHA" ]] && SHA_FROM="${BACKUP_ID}.sha256"
  fi
  [[ -n "$EXPECTED_SHA" ]] \
    || die "$(leader 'expected sha256' 'UNAVAILABLE')" \
           "no archive_sha256 in $MANIFEST_FILE" \
           "and no usable $CHECKSUM_FILE" \
           "refusing to restore an unverified archive over a wiped datadir"
  val "expected sha256" "${EXPECTED_SHA:0:16}… ($SHA_FROM)"
fi

# The inverse of the tar chain's guard: prepared=no is EXPECTED here, and
# prepared=yes means an archive from the other pipeline.
check
SRC_VERSION=""
if [[ $DO_RESTORE -eq 0 ]]; then
  skp "manifest" "n/a (--binlog-only)"
elif [[ -f "$MANIFEST_FILE" ]]; then
  M_FORMAT="$(manifest_get archive_format)"
  M_PREPARED="$(manifest_get prepared)"
  SRC_VERSION="$(manifest_get mysql_version)"
  [[ -z "$M_FORMAT" || "$M_FORMAT" == "xbstream" ]] \
    || die "$(leader 'manifest' "format=$M_FORMAT")" \
           "expected 'xbstream' — this archive came from a different pipeline" \
           "for a .tar.gz backup use server/physical/restore_full.sh"
  [[ "$M_PREPARED" != "yes" ]] \
    || die "$(leader 'manifest' 'prepared=yes')" \
           "this script expects an UNPREPARED streamed archive and runs --prepare" \
           "itself; refusing to prepare an already-prepared backup again"
  val "manifest" "format=${M_FORMAT:-unset} prepared=${M_PREPARED:-unset} type=$(manifest_get backup_type)"
else
  nok "manifest" "ABSENT"
  cont "format and prepared state cannot be confirmed in advance"
  cont "both are still verified against the disk after extract and prepare"
fi

# Informational only: the comparison is a crude string match, and a false
# positive that blocked the restore would leave you unable to recover at all.
check
LOCAL_VERSION=$("$MYSQL_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
if [[ -n "$SRC_VERSION" && "$SRC_VERSION" != "unknown" && -n "$LOCAL_VERSION" ]]; then
  if [[ "${SRC_VERSION%%-*}" != "$LOCAL_VERSION" ]]; then
    nok "mysql version" "MISMATCH"
    cont "backup from $SRC_VERSION, this server runs $LOCAL_VERSION"
    cont "restoring a NEWER datadir onto an OLDER server usually fails"
    cont "if MySQL will not start at the end of this restore, check this first"
  else
    val "mysql version" "$LOCAL_VERSION"
  fi
else
  skp "mysql version" "not compared"
fi

# Sized off the manifest's measured datadir_bytes, not a guess.
check
if [[ $DO_RESTORE -eq 0 ]]; then
  skp "datadir space" "n/a (--binlog-only)"
else
  [[ -d "$MYSQL_DATADIR" ]] \
    || die "$(leader 'datadir space' 'NO DATADIR')" "not found: $MYSQL_DATADIR"
  [[ -n "$MYSQL_DATADIR" && "$MYSQL_DATADIR" != "/" ]] \
    || die "$(leader 'datadir space' 'UNSAFE PATH')" "refusing to operate on '$MYSQL_DATADIR'"

  SRC_BYTES="$(manifest_get datadir_bytes)"
  if [[ "$SRC_BYTES" =~ ^[1-9][0-9]*$ ]]; then
    NEED_GB=$(( (SRC_BYTES / 1073741824 + 1) * DATADIR_SPACE_PCT / 100 + 1 ))
    BASIS="manifest datadir_bytes $(hsize "$SRC_BYTES") x ${DATADIR_SPACE_PCT}%"
  else
    NEED_GB=$(( (ARCHIVE_BYTES / 1073741824 + 1) * ARCHIVE_EXPANSION_FACTOR ))
    BASIS="archive $(hsize "$ARCHIVE_BYTES") x ${ARCHIVE_EXPANSION_FACTOR} (no datadir_bytes)"
  fi

  # The datadir's current contents count as available — they are about to go.
  RECLAIM_GB=$(du -sb "$MYSQL_DATADIR" 2>/dev/null | awk '{print int($1/1073741824)}')
  USABLE_GB=$(( $(free_gb "$MYSQL_DATADIR") + RECLAIM_GB ))

  [[ $USABLE_GB -ge $NEED_GB ]] \
    || die "$(leader 'datadir space' 'INSUFFICIENT')" \
           "need ${NEED_GB}GB, usable ${USABLE_GB}GB (free + ${RECLAIM_GB}GB reclaimed by the wipe)" \
           "basis: $BASIS" \
           "extract, decompress and prepare all happen in place in the datadir"
  val "datadir space" "need ${NEED_GB}GB / usable ${USABLE_GB}GB"
  cont "basis: $BASIS"
fi

# Staging adds a second claim on disk, and if it shares a filesystem with the
# datadir the two compete for one budget. Getting this wrong means ENOSPC
# *after* the wipe, which is the worst moment available — hence a check of its
# own, before anything is touched.
check
if [[ $DO_RESTORE -eq 0 ]]; then
  skp "archive staging space" "n/a (--binlog-only)"
elif [[ $STAGE_ARCHIVE -ne 1 ]]; then
  skp "archive staging space" "n/a (STAGE_ARCHIVE=0)"
else
  [[ -d "$ARCHIVE_STAGE_DIR" ]] \
    || mkdir -p "$ARCHIVE_STAGE_DIR" 2>>"$ERROR_LOG" \
    || die "$(leader 'archive staging space' 'NO STAGE DIR')" \
           "cannot create $ARCHIVE_STAGE_DIR"

  # Never inside the datadir: the wipe would delete the archive it is about to
  # extract, mid-run, with the old data already gone.
  case "$ARCHIVE_STAGE_DIR/" in
    "$MYSQL_DATADIR"/*)
      die "$(leader 'archive staging space' 'UNSAFE PATH')" \
          "ARCHIVE_STAGE_DIR is inside the datadir and would be erased by the wipe" \
          "stage: $ARCHIVE_STAGE_DIR" \
          "datadir: $MYSQL_DATADIR" ;;
  esac

  # +10%: xbstream writes nothing here, but leave room for the run's logs.
  STAGE_GB=$(( ARCHIVE_BYTES / 1073741824 * 110 / 100 + 2 ))

  # Same device means one shared budget. stat -c %d is the device number, so
  # this is true for bind mounts and subdirectories alike, unlike comparing paths.
  STAGE_DEV="$(stat -c %d "$ARCHIVE_STAGE_DIR" 2>/dev/null || echo x)"
  DATA_DEV="$(stat -c %d "$MYSQL_DATADIR"      2>/dev/null || echo y)"

  if [[ "$STAGE_DEV" == "$DATA_DEV" ]]; then
    COMBINED_GB=$(( ${NEED_GB:-0} + STAGE_GB ))
    [[ ${USABLE_GB:-0} -ge $COMBINED_GB ]] \
      || die "$(leader 'archive staging space' 'INSUFFICIENT')" \
             "need ${COMBINED_GB}GB, usable ${USABLE_GB:-0}GB" \
             "the stage and the datadir are on ONE filesystem, so the staged" \
             "archive (${STAGE_GB}GB) and the expanded datadir (${NEED_GB:-0}GB) share it" \
             "free space, stage elsewhere, or set STAGE_ARCHIVE=0"
    val "archive staging space" "need ${COMBINED_GB}GB / usable ${USABLE_GB:-0}GB"
    cont "shared filesystem: stage ${STAGE_GB}GB + datadir ${NEED_GB:-0}GB"
  else
    FREE_STAGE_GB=$(free_gb "$ARCHIVE_STAGE_DIR")
    [[ $FREE_STAGE_GB -ge $STAGE_GB ]] \
      || die "$(leader 'archive staging space' 'INSUFFICIENT')" \
             "need ${STAGE_GB}GB, free ${FREE_STAGE_GB}GB in $ARCHIVE_STAGE_DIR" \
             "free space, stage elsewhere, or set STAGE_ARCHIVE=0"
    val "archive staging space" "need ${STAGE_GB}GB / free ${FREE_STAGE_GB}GB"
    cont "separate filesystem from the datadir"
  fi
fi

check
if mysql_up; then
  MYSQL_WAS_RUNNING=true
  if [[ $DO_RESTORE -eq 1 && $DRY_RUN -eq 0 ]]; then
    val "mysql status" "running (will be STOPPED)"
  else
    val "mysql status" "running"
  fi
else
  [[ $DO_RESTORE -eq 1 || $DRY_RUN -eq 1 ]] \
    || die "$(leader 'mysql status' 'STOPPED')" \
           "--binlog-only needs a running MySQL to replay into" \
           "start it, or run a full restore instead"
  val "mysql status" "stopped"
fi

# The double-apply guard. A FULL run does not need it: it wipes and re-restores
# first, so binlogs always land on a fresh baseline. --binlog-only does.
check
if [[ -f "$RESTORE_MARKER" ]]; then
  PREV_APPLIED="$(marker_get binlogs_applied)"
  val "restore marker" "exists, binlogs_applied=${PREV_APPLIED:-unknown}"
  cont "restored_at $(marker_get restored_at)"
  if [[ $DO_RESTORE -eq 0 && "$PREV_APPLIED" == "yes" && $DRY_RUN -eq 0 ]]; then
    die "$(leader 'restore marker' 'ALREADY APPLIED')" \
        "applied at $(marker_get applied_at)" \
        "last applied: $(marker_get last_applied_binlog), files: $(marker_get files_applied)" \
        "" \
        "re-applying would re-execute EVERY transaction on a database that" \
        "already contains them. Recovery is file+position only — there is no" \
        "duplicate detection. This WOULD corrupt data." \
        "" \
        "to genuinely redo the apply, restore the full backup first:" \
        "  $SELF_CMD"
  fi
  [[ $DO_RESTORE -eq 0 ]] \
    || cont "re-running the full restore is the correct ROLLBACK — the marker resets"
else
  [[ $DO_RESTORE -eq 1 || $DRY_RUN -eq 1 ]] \
    || die "$(leader 'restore marker' 'MISSING')" \
           "expected: $RESTORE_MARKER" \
           "--binlog-only requires that this exact backup was already restored here." \
           "applying binlogs to a database that was NOT restored from this backup" \
           "replays against the wrong starting state: silent, unrecoverable" \
           "divergence, not an error message." \
           "" \
           "run the full restore instead:  $SELF_CMD"
  val "restore marker" "none (clean restore)"
fi

check
SMB_BINLOG_COUNT=0
INFO_BINLOG=""
INFO_POS=""
if [[ $DO_APPLY -eq 0 ]]; then
  skp "collected binlogs" "n/a (--skip-binlog)"
else
  [[ -d "$SMB_BINLOG_DIR" ]] \
    || die "$(leader 'collected binlogs' 'NONE')" \
           "not found: $SMB_BINLOG_DIR" \
           "binlog_collect.sh has not collected anything for this backup" \
           "to restore to the backup point only, re-run with --skip-binlog"
  SMB_BINLOG_COUNT=$(find "$SMB_BINLOG_DIR" -maxdepth 1 -type f -name "$BINLOG_GLOB" 2>/dev/null | wc -l)
  [[ $SMB_BINLOG_COUNT -gt 0 ]] \
    || die "$(leader 'collected binlogs' 'EMPTY')" \
           "no ${BINLOG_GLOB} in $SMB_BINLOG_DIR" \
           "to restore to the backup point only, re-run with --skip-binlog"

  # On --binlog-only the MARKER wins: it records what this server restored.
  ANCHOR_FROM=""
  if [[ $DO_RESTORE -eq 0 ]]; then
    INFO_BINLOG="$(marker_get binlog_file)"; INFO_POS="$(marker_get binlog_pos)"
    [[ -n "$INFO_BINLOG" ]] && ANCHOR_FROM="restore marker"
  fi
  if [[ -z "$INFO_BINLOG" && -f "$MANIFEST_FILE" ]]; then
    INFO_BINLOG="$(manifest_get binlog_file)"; INFO_POS="$(manifest_get binlog_pos)"
    [[ -n "$INFO_BINLOG" ]] && ANCHOR_FROM="manifest"
  fi
  if [[ -z "$INFO_BINLOG" && -s "$ANCHOR_FILE" ]]; then
    INFO_BINLOG=$(awk '{print $1}' "$ANCHOR_FILE"); INFO_POS=$(awk '{print $2}' "$ANCHOR_FILE")
    [[ -n "$INFO_BINLOG" ]] && ANCHOR_FROM="$(basename "$ANCHOR_FILE")"
  fi

  [[ -n "$INFO_BINLOG" && -n "$INFO_POS" ]] \
    || die "$(leader 'collected binlogs' 'NO ANCHOR')" \
           "cannot determine the backup's binlog position" \
           "checked the marker, the manifest and $ANCHOR_FILE"
  is_binlog "$INFO_BINLOG" \
    || die "$(leader 'collected binlogs' "bad anchor: $INFO_BINLOG")" \
           "the backup may have been taken with binary logging disabled," \
           "in which case only --skip-binlog is possible"
  [[ "$INFO_POS" =~ ^[0-9]+$ ]] \
    || die "$(leader 'collected binlogs' "bad position: $INFO_POS")"

  val "collected binlogs" "$SMB_BINLOG_COUNT files"
  cont "anchor ${INFO_BINLOG}:${INFO_POS} (from $ANCHOR_FROM)"
fi

check
if [[ $DO_APPLY -eq 0 ]]; then
  skp "binlog staging space" "n/a (--skip-binlog)"
else
  NEED_BL_GB=$(( $(du -sb "$SMB_BINLOG_DIR" 2>/dev/null | awk '{print $1}') / 1073741824 + 1 ))
  FREE_BL_GB=$(free_gb "$LOCAL_STAGE")
  [[ $FREE_BL_GB -ge $NEED_BL_GB ]] \
    || die "$(leader 'binlog staging space' 'INSUFFICIENT')" \
           "need ${NEED_BL_GB}GB in $LOCAL_STAGE, have ${FREE_BL_GB}GB"
  val "binlog staging space" "need ${NEED_BL_GB}GB / free ${FREE_BL_GB}GB"
fi

check
if [[ -z "$FROM_BINLOG" ]]; then
  skp "--from file" "n/a (no override)"
elif [[ ! -f "$SMB_BINLOG_DIR/$FROM_BINLOG" ]]; then
  erro "$(leader '--from file' 'NOT FOUND')"
  cerr "missing: $SMB_BINLOG_DIR/$FROM_BINLOG"
  cerr "available:"
  while read -r f; do cerr "  $(basename "$f")"; done \
    < <(find "$SMB_BINLOG_DIR" -maxdepth 1 -type f -name "$BINLOG_GLOB" 2>/dev/null | sort)
  fail_run
else
  val "--from file" "$FROM_BINLOG"
fi

STEP="-"
info "$CHECK_N checks passed, ${WARN_COUNT} warning(s)   ($(elapsed "$PREFLIGHT_EPOCH"))"
sub

# ═══════════════════════════════════════════════════════════════════════════
# PART 9  START POINT
#
# Resolved once, here, so the dry run and the real apply cannot disagree.
#   no --from            -> anchor file at the anchor position
#   --from, other file   -> that file at position 4 (whole file)
#   --from, SAME file    -> that file at the ANCHOR position, not 4, or the
#                           transactions already in the full backup replay
# ═══════════════════════════════════════════════════════════════════════════

START_BINLOG=""
START_POS=""
if [[ $DO_APPLY -eq 1 ]]; then
  phase start
  if [[ -z "$FROM_BINLOG" ]]; then
    START_BINLOG="$INFO_BINLOG"; START_POS="$INFO_POS"
    val "start point" "${START_BINLOG}:${START_POS} (backup anchor)"
  elif [[ "$FROM_BINLOG" != "$INFO_BINLOG" ]]; then
    START_BINLOG="$FROM_BINLOG"; START_POS="$BINLOG_FILE_START_POS"
    val "start point" "${START_BINLOG}:${START_POS} (--from, whole file)"
  else
    START_BINLOG="$FROM_BINLOG"; START_POS="$INFO_POS"
    nok "start point" "EDGE CASE"
    cont "--from names the same file as the backup anchor"
    cont "the full backup already contains it up to position $INFO_POS"
    cont "using $INFO_POS instead of 4, or those transactions replay twice"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 10  DRY RUN
#
# Verifies the archive and decodes what WOULD be replayed. Touches nothing.
# ═══════════════════════════════════════════════════════════════════════════

if [[ $DRY_RUN -eq 1 ]]; then
  phase dryrun

  SHA_RESULT="skipped"
  if [[ $DO_RESTORE -eq 1 ]]; then
    info "reading the whole archive off the share to checksum it ($ARCHIVE_SIZE)"
    ACTUAL_SHA=$(sha256sum "$SMB_ARCHIVE" 2>>"$ERROR_LOG" | awk '{print $1}')
    if [[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]]; then
      SHA_RESULT="ok"; ok "archive checksum"
    else
      SHA_RESULT="MISMATCH"
      erro "$(leader 'archive checksum' 'MISMATCH')"
      cerr "expected $EXPECTED_SHA"
      cerr "actual   ${ACTUAL_SHA:-(unreadable)}"
      cerr "do NOT restore from this backup ID"
    fi
  fi

  PREVIEW=""
  PREVIEW_FILES=0
  if [[ $DO_APPLY -eq 1 ]]; then
    mapfile -t ALL < <(find "$SMB_BINLOG_DIR" -maxdepth 1 -type f -name "$BINLOG_GLOB" -printf '%f\n' 2>/dev/null | sort)
    PATHS=(); SEEN=false
    for f in "${ALL[@]}"; do
      [[ "$f" == "$START_BINLOG" ]] && SEEN=true
      [[ "$SEEN" == true ]] && PATHS+=("$SMB_BINLOG_DIR/$f")
    done
    if [[ "$SEEN" != true ]]; then
      erro "$(leader 'start binlog' 'NOT COLLECTED')"
      cerr "$START_BINLOG is not among the collected binlogs; available:"
      for f in "${ALL[@]}"; do cerr "  $f"; done
      fail_run
    fi
    PREVIEW_FILES=${#PATHS[@]}
    PREVIEW="${LOCAL_STAGE}/${BACKUP_ID}_binlog_preview.sql"
    info "decoding $PREVIEW_FILES binlog file(s) from ${START_BINLOG}:${START_POS}"
    "$MYSQLBINLOG_BIN" --start-position="$START_POS" "${PATHS[@]}" > "$PREVIEW" 2>>"$ERROR_LOG" \
      || die "failed to decode the binlogs for preview"
    val "preview" "$PREVIEW ($(du -sh "$PREVIEW" | awk '{print $1}'))"
    val "row events" "$(grep -c '^### ' "$PREVIEW" 2>/dev/null || echo 0)"
  fi

  emit ""
  banner " DRY RUN COMPLETE — NOTHING WAS MODIFIED"
  kv "backup id"        "$BACKUP_ID"
  kv "archive checksum" "$SHA_RESULT"
  if [[ $DO_APPLY -eq 1 ]]; then
    kv "start point"    "${START_BINLOG}:${START_POS}"
    kv "files in scope" "$PREVIEW_FILES"
    kv "preview"        "$(hsize "$(stat -c%s "$PREVIEW")") — published below as binlog_preview.sql"
  else
    kv "binlog preview" "skipped (--skip-binlog)"
  fi
  sub

  if [[ $DO_APPLY -eq 1 ]]; then
    emit " destructive statements in scope (first 20):"
    # grep exits 1 when it finds nothing, which is the good outcome here.
    DESTRUCTIVE=$(grep -inE '^[[:space:]]*(DROP|TRUNCATE|ALTER)[[:space:]]' "$PREVIEW" | head -20 || true)
    if [[ -n "$DESTRUCTIVE" ]]; then
      while IFS= read -r l; do emit "   $l"; done <<< "$DESTRUCTIVE"
      sub
      nok "destructive statements" "PRESENT"
      cont "if the incident you are recovering from WAS one of these, applying"
      cont "everything re-executes it — consider --from to narrow the range"
    else
      emit "   (none)"
    fi
    sub
  fi

  kv "run it with" "$SELF_CMD${FROM_BINLOG:+ --from $FROM_BINLOG}"
  PHASE="done"; STEP="-"

  # Non-zero ONLY on a checksum mismatch, so this works as a monitored check.
  if [[ "$SHA_RESULT" == "MISMATCH" ]]; then
    banner " RESULT failed id=${BACKUP_ID} phase=dryrun reason=checksum dur_s=$(( $(date +%s) - START_EPOCH ))"
    publish_logs
    trap - ERR INT TERM
    exit 1
  fi
  banner " RESULT ok id=${BACKUP_ID} phase=dryrun files=${PREVIEW_FILES} dur_s=$(( $(date +%s) - START_EPOCH )) warn=${WARN_COUNT}"
  publish_logs
  trap - ERR INT TERM
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 11  VERIFY  1/3
#
# Before MySQL is stopped and before anything is erased, so failing here is
# free — the database is still running on its existing data.
#
# With STAGE_ARCHIVE=1 this phase also COPIES the archive to local disk and
# checksums the copy. Everything that needs the network is therefore finished
# before the wipe: the whole transfer moves out of the destructive window, and
# the checksum certifies the exact bytes the extract will read rather than a
# separate earlier read of the same path.
# ═══════════════════════════════════════════════════════════════════════════

phase verify 1/3
if [[ $DO_RESTORE -eq 0 ]]; then
  skp "archive verification" "n/a (--binlog-only)"
elif [[ $STAGE_ARCHIVE -ne 1 ]]; then
  # STAGE_ARCHIVE=0: verify on the share and extract from it. The archive is
  # then read over the network TWICE — once here, once by xbstream — and the
  # second read happens with the datadir already wiped.
  info "reading the whole archive off the share ($ARCHIVE_SIZE) — this takes a while"
  ACTUAL_SHA=$(sha256sum "$SMB_ARCHIVE" 2>>"$ERROR_LOG" | awk '{print $1}')
  [[ -n "$ACTUAL_SHA" ]] \
    || die "could not read the archive from the share to checksum it" \
           "the share may have dropped; the datadir has NOT been touched"
  [[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] \
    || die "$(leader 'archive checksum' 'MISMATCH')" \
           "expected $EXPECTED_SHA" \
           "actual   $ACTUAL_SHA" \
           "the archive is corrupt or truncated" \
           "the datadir has NOT been touched — nothing is lost" \
           "restore from a different backup ID"
  ok "archive checksum"
  RESTORE_SOURCE="$SMB_ARCHIVE"
  info "verified in $(elapsed "$PHASE_EPOCH")"
else
  # Copy first, then checksum what landed. The checksum is taken from the LOCAL
  # file, not the share, so it certifies the exact bytes the extract will read —
  # the share version left a window where the two reads could disagree.
  STAGED_REUSED=false
  if [[ -f "$STAGED_ARCHIVE" ]]; then
    STAGED_BYTES=$(stat -c %s "$STAGED_ARCHIVE" 2>/dev/null || echo 0)
    if [[ "$STAGED_BYTES" == "$ARCHIVE_BYTES" ]]; then
      info "a staged archive is already present — checksumming it instead of re-copying"
      ACTUAL_SHA=$(sha256sum "$STAGED_ARCHIVE" 2>>"$ERROR_LOG" | awk '{print $1}')
      if [[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]]; then
        STAGED_REUSED=true
        ok "staged archive reused"
      else
        nok "staged archive" "STALE — re-copying"
      fi
    else
      nok "staged archive" "size mismatch — re-copying"
    fi
    [[ "$STAGED_REUSED" == true ]] || rm -f "$STAGED_ARCHIVE" 2>/dev/null || true
  fi

  if [[ "$STAGED_REUSED" != true ]]; then
    info "copying the archive to local disk ($ARCHIVE_SIZE) — the network ends here"
    set +e
    cp "$SMB_ARCHIVE" "$STAGED_ARCHIVE" 2>>"$ERROR_LOG"
    COPY_STATUS=$?
    set -e
    [[ $COPY_STATUS -eq 0 ]] \
      || die "copying the archive from the share failed (cp exited $COPY_STATUS)" \
             "the share may have dropped, or $ARCHIVE_STAGE_DIR is full" \
             "the datadir has NOT been touched — nothing is lost"
    STAGED_BYTES=$(stat -c %s "$STAGED_ARCHIVE" 2>/dev/null || echo 0)
    [[ "$STAGED_BYTES" == "$ARCHIVE_BYTES" ]] \
      || die "$(leader 'staged archive' 'SHORT')" \
             "expected $ARCHIVE_BYTES bytes, got $STAGED_BYTES" \
             "the copy was truncated — most likely the stage filesystem filled" \
             "the datadir has NOT been touched — nothing is lost"
    val "copied to local disk" "$(elapsed "$PHASE_EPOCH")"

    info "checksumming the local copy"
    ACTUAL_SHA=$(sha256sum "$STAGED_ARCHIVE" 2>>"$ERROR_LOG" | awk '{print $1}')
    [[ -n "$ACTUAL_SHA" ]] \
      || die "could not read the staged archive back to checksum it" \
             "the datadir has NOT been touched — nothing is lost"
    [[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] \
      || die "$(leader 'archive checksum' 'MISMATCH')" \
             "expected $EXPECTED_SHA" \
             "actual   $ACTUAL_SHA" \
             "the copy on local disk does not match the manifest — the archive is" \
             "corrupt on the share, or the transfer or local disk damaged it" \
             "the datadir has NOT been touched — nothing is lost" \
             "re-run to copy again, or restore from a different backup ID"
    ok "archive checksum"
  fi

  RESTORE_SOURCE="$STAGED_ARCHIVE"
  val "restore source" "local stage"
  info "verified in $(elapsed "$PHASE_EPOCH")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 12  RESTORE  2/3
#
# Extract, decompress and prepare all happen IN PLACE in the datadir: no staging
# copy and no --copy-back, so ~1x the data size rather than 2x. Everything from
# the stop onward is destructive.
# ═══════════════════════════════════════════════════════════════════════════

phase restore 2/3
if [[ $DO_RESTORE -eq 0 ]]; then
  skp "restore" "n/a (--binlog-only)"
else
  info "stopping MySQL"
  if mysql_up; then
    systemctl stop "$MYSQL_SERVICE" 2>>"$ERROR_LOG" \
      || die "failed to stop the MySQL service: $MYSQL_SERVICE"
    sleep 3
    ! mysql_up || die "MySQL is still running after the stop command" \
                      "refusing to wipe a datadir with a live server attached"
    ok "mysql stopped"
  else
    skp "mysql stopped" "already stopped"
  fi

  # Re-asserted immediately before the delete: cheap, and the one place where a
  # mistake is unrecoverable.
  [[ -n "$MYSQL_DATADIR" && "$MYSQL_DATADIR" != "/" ]] \
    || die "safety check failed: unsafe MYSQL_DATADIR '$MYSQL_DATADIR'"

  info "erasing $MYSQL_DATADIR"
  DATADIR_WIPED=true
  # find, not a glob: the glob misses dotfiles and, on an already-empty datadir,
  # stays unexpanded so rm fails on a literal '*'.
  find "${MYSQL_DATADIR:?}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>>"$ERROR_LOG" \
    || die "failed to clear the data directory"
  [[ -z "$(ls -A "$MYSQL_DATADIR" 2>/dev/null)" ]] \
    || die "the data directory is not empty after the wipe"
  ok "datadir cleared"

  # With STAGE_ARCHIVE=1 this reads from local disk, so the network is already
  # out of the picture by here and the only exposure left is a local failure.
  XBSTREAM_ARGS=(-x --parallel="$PARALLEL_THREADS" -C "$MYSQL_DATADIR")
  if [[ $XBSTREAM_DECOMPRESS -eq 1 ]]; then
    XBSTREAM_ARGS+=(--decompress --decompress-threads="$PARALLEL_THREADS")
    EXTRACT_WHAT="extracting and decompressing the xbstream in one pass"
  else
    EXTRACT_WHAT="extracting the xbstream"
  fi
  if [[ "$RESTORE_SOURCE" == "$STAGED_ARCHIVE" ]]; then
    info "$EXTRACT_WHAT from local disk"
  else
    info "$EXTRACT_WHAT from the share (network in the critical path)"
  fi
  "$XBSTREAM_BIN" "${XBSTREAM_ARGS[@]}" \
    < "$RESTORE_SOURCE" 2>>"$ERROR_LOG" \
    || die "xbstream extraction failed" \
           "$([[ $XBSTREAM_DECOMPRESS -eq 1 ]] \
              && echo 'this build may not support --decompress: check xbstream --help' \
              || echo 'if the share dropped, restore it and re-run the same command')"
  [[ -n "$(ls -A "$MYSQL_DATADIR" 2>/dev/null)" ]] \
    || die "the datadir is empty after extraction — the archive produced nothing"
  ok "extracted"

  # Skipped entirely when xbstream already expanded everything in the pass
  # above: there is nothing compressed left on disk to walk.
  if [[ $XBSTREAM_DECOMPRESS -eq 1 ]]; then
    skp "decompressed" "n/a (folded into the extract)"
  else
    # --remove-original deletes each .zst as it expands, keeping peak usage just
    # above the uncompressed size instead of holding both copies.
    info "decompressing (zstd, --remove-original, $PARALLEL_THREADS threads)"
    set +e
    "$XTRABACKUP_BIN" --decompress --remove-original \
      --parallel="$PARALLEL_THREADS" --target-dir="$MYSQL_DATADIR" \
      >> "$XTRABACKUP_LOG" 2>&1
    DECOMP_STATUS=$?
    set -e
    if [[ $DECOMP_STATUS -ne 0 ]]; then
      erro "xtrabackup --decompress exited $DECOMP_STATUS"
      cerr "last 40 lines of $XTRABACKUP_LOG:"
      while IFS= read -r l; do cerr "  $l"; done < <(tail -40 "$XTRABACKUP_LOG" 2>/dev/null || true)
      fail_run
    fi
    ok "decompressed"
  fi

  # The real assertion, run either way: --prepare skips a leftover compressed
  # file silently and it becomes an unreadable tablespace at runtime. `|| true`
  # because find gets SIGPIPE from head, which pipefail would turn into a
  # spurious failure.
  LEFTOVER=$(find "$MYSQL_DATADIR" -type f \( -name '*.zst' -o -name '*.qp' -o -name '*.lz4' \) 2>/dev/null | head -5 || true)
  if [[ -n "$LEFTOVER" ]]; then
    erro "$(leader 'compressed files' 'REMAIN')"
    while IFS= read -r f; do cerr "  $f"; done <<< "$LEFTOVER"
    cerr "this xtrabackup build may lack support for the compression used"
    cerr "compare the manifest's compression= against your xtrabackup version"
    fail_run
  fi

  # The step the tar chain performed at BACKUP time.
  info "preparing (applying the redo log)${PREPARE_USE_MEMORY:+, --use-memory=$PREPARE_USE_MEMORY}"
  PREPARE_ARGS=(--prepare --target-dir="$MYSQL_DATADIR")
  [[ -n "$PREPARE_USE_MEMORY" ]] && PREPARE_ARGS+=(--use-memory="$PREPARE_USE_MEMORY")

  set +e
  "$XTRABACKUP_BIN" "${PREPARE_ARGS[@]}" >> "$XTRABACKUP_LOG" 2>&1
  PREPARE_STATUS=$?
  set -e
  if [[ $PREPARE_STATUS -ne 0 ]]; then
    erro "xtrabackup --prepare exited $PREPARE_STATUS"
    cerr "last 40 lines of $XTRABACKUP_LOG:"
    while IFS= read -r l; do cerr "  $l"; done < <(tail -40 "$XTRABACKUP_LOG" 2>/dev/null || true)
    cerr "MySQL is left STOPPED — starting it on an unprepared datadir corrupts it"
    fail_run
  fi
  grep -q 'completed OK!' "$XTRABACKUP_LOG" \
    || die "xtrabackup did not report 'completed OK!' — refusing to continue"

  # Authoritative: --prepare rewrites backup_type from full-backuped to
  # full-prepared. Read off the disk, not from the manifest.
  [[ -f "$MYSQL_DATADIR/xtrabackup_checkpoints" ]] \
    || die "xtrabackup_checkpoints is missing after --prepare" \
           "the archive is not a complete XtraBackup datadir"
  PREPARED_TYPE=$(awk '/backup_type/ {print $3}' "$MYSQL_DATADIR/xtrabackup_checkpoints")
  [[ "$PREPARED_TYPE" == "full-prepared" ]] \
    || die "$(leader 'prepared' "${PREPARED_TYPE:-(empty)}")" \
           "expected 'full-prepared'" \
           "starting MySQL on an unprepared backup WILL corrupt it" \
           "MySQL has been left STOPPED deliberately"
  val "prepared" "$PREPARED_TYPE"

  for artifact in ibdata1 mysql; do
    [[ -e "$MYSQL_DATADIR/$artifact" ]] \
      || die "$(leader 'core artifacts' "missing $artifact")" \
             "the archive is not a complete XtraBackup datadir"
  done
  ok "core artifacts"

  chown -R mysql:mysql "$MYSQL_DATADIR" 2>>"$ERROR_LOG" \
    || die "failed to set ownership on $MYSQL_DATADIR"
  ok "ownership set"

  info "starting MySQL"
  systemctl start "$MYSQL_SERVICE" 2>>"$ERROR_LOG" \
    || { erro "MySQL failed to start after the restore"
         cerr "systemctl start returned non-zero — mysqld never came up"
         mysql_error_log_tail 30
         fail_run; }

  # ────────────────────────────────────────────────────────────────────────
  # Readiness, kept strictly separate from authentication.
  #
  # The old loop was `mysql -e 'SELECT 1' 2>/dev/null` x60. It conflated three
  # different states into one timeout message:
  #   - mysqld not listening yet  (ERROR 2002)  -> keep waiting
  #   - mysqld gone/crashed                     -> stop waiting NOW
  #   - mysqld up, password rejected (1045)     -> it is READY; the credential
  #                                                is the problem, not the server
  # The third is not hypothetical here: a physical restore overwrites mysql.user
  # with the SOURCE server's accounts, so this host's Admin password can be
  # rejected by a server that restored perfectly.
  # ────────────────────────────────────────────────────────────────────────
  WAIT_START=$(date +%s)
  WAIT_DEADLINE=$(( WAIT_START + MYSQL_READY_TIMEOUT ))
  WAIT_NEXT_REPORT=$(( WAIT_START + 20 ))
  while :; do
    mysql_serving && break

    # Fail fast instead of burning the whole timeout on a dead process. This is
    # the difference between learning at 2s and learning at 15m.
    if ! mysql_up; then
      erro "mysqld exited while starting up"
      cerr "systemd reported the unit started, but no mysqld process remains."
      cerr "last client error: ${MYSQL_PROBE_ERR:-(none)}"
      mysql_error_log_tail 40
      fail_run
    fi

    NOW=$(date +%s)
    if [[ $NOW -ge $WAIT_DEADLINE ]]; then
      erro "MySQL did not answer within ${MYSQL_READY_TIMEOUT}s"
      cerr "mysqld IS running, but it never began serving connections."
      cerr "last client error: ${MYSQL_PROBE_ERR:-(none)}"
      cerr ""
      cerr "a large datadir can spend a long time opening tablespaces — if the"
      cerr "error log below shows it still working, raise MYSQL_READY_TIMEOUT"
      cerr "(currently ${MYSQL_READY_TIMEOUT}s) rather than re-running the restore."
      mysql_error_log_tail 40
      fail_run
    fi
    if [[ $NOW -ge $WAIT_NEXT_REPORT ]]; then
      info "still waiting for MySQL... ($(( NOW - WAIT_START ))s of ${MYSQL_READY_TIMEOUT}s)"
      WAIT_NEXT_REPORT=$(( NOW + 20 ))
    fi
    sleep "$MYSQL_READY_INTERVAL"
  done
  ok "mysql serving"

  # A live, consistent database from here: later failures are apply failures.
  DATADIR_WIPED=false
  RESTORE_COMPLETE=true

  # A safety mechanism, not bookkeeping: --binlog-only reads binlogs_applied
  # from this to refuse a second apply.
  MARKER_BINLOG="$(manifest_get binlog_file)"
  MARKER_POS="$(manifest_get binlog_pos)"
  if [[ -z "$MARKER_BINLOG" && -s "$ANCHOR_FILE" ]]; then
    MARKER_BINLOG=$(awk '{print $1}' "$ANCHOR_FILE")
    MARKER_POS=$(awk '{print $2}' "$ANCHOR_FILE")
  fi
  cat > "$RESTORE_MARKER" <<EOF
restored_at=$(date '+%F %T')
backup_id=${BACKUP_ID}
archive_format=xbstream
prepared_by=restore.sh
binlog_file=${MARKER_BINLOG}
binlog_pos=${MARKER_POS}
recovery_method=file_position
binlogs_applied=no
EOF
  ok "restore marker written"

  # Only NOW is it worth asking whether our credentials still work. The marker
  # is already on disk, so if this fails the operator fixes the password and
  # runs --binlog-only rather than repeating the whole restore.
  #
  # This is a real failure — the apply needs a working connection — but it is a
  # completely different one from "MySQL did not start", and it used to be
  # reported as the latter.
  if ! mysql_auth_ok; then
    erro "$(leader 'credentials' 'REJECTED')"
    cerr "mysqld is up and serving, but '$MYSQL_USER' cannot log in."
    cerr "client error: ${MYSQL_PROBE_ERR:-see $ERROR_LOG}"
    cerr ""
    cerr "expected after a physical restore: the datadir carries the SOURCE"
    cerr "server's mysql.user table, so this host's password for '$MYSQL_USER'"
    cerr "is no longer the one that applies. The restored DATA is fine."
    cerr ""
    cerr "recover the account, then apply the binlogs alone:"
    cerr "  systemctl stop $MYSQL_SERVICE"
    cerr "  # start with --skip-grant-tables, reset the password, restart"
    cerr "  $SELF_CMD --binlog-only"
    fail_run
  fi
  ok "credentials accepted"

  DB_COUNT=$(mysql_q "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema','mysql','performance_schema','sys')" || echo 0)
  info "restored in $(elapsed "$PHASE_EPOCH")  —  $DB_COUNT user database(s)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 13  BINLOG APPLY  3/3
# ═══════════════════════════════════════════════════════════════════════════

phase apply 3/3
if [[ $DO_APPLY -eq 0 ]]; then
  skp "binlog apply" "SKIPPED (--skip-binlog)"
else
  # `mysqlbinlog <path> | mysql` holds a live pipe open for the whole file. On
  # CIFS a stall breaks it mid-transaction-stream — the exact failure a one-shot
  # apply cannot recover from. Copying first takes the network off that path.
  info "staging binlogs from the share to local disk"
  rm -rf "$LOCAL_BINLOG_DIR" 2>/dev/null || true
  mkdir -p "$LOCAL_BINLOG_DIR" 2>/dev/null || die "failed to create $LOCAL_BINLOG_DIR"

  STAGED=false
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --include="$BINLOG_GLOB" --include="binlog.sha256" --exclude='*' \
      "${SMB_BINLOG_DIR}/" "${LOCAL_BINLOG_DIR}/" 2>>"$ERROR_LOG" && STAGED=true
  else
    nok "staging method" "cp (rsync not installed)"
    if find "$SMB_BINLOG_DIR" -maxdepth 1 -type f -name "$BINLOG_GLOB" \
         -exec cp {} "${LOCAL_BINLOG_DIR}/" \; 2>>"$ERROR_LOG"; then
      cp "${SMB_BINLOG_DIR}/binlog.sha256" "${LOCAL_BINLOG_DIR}/" 2>/dev/null || true
      STAGED=true
    fi
  fi
  [[ "$STAGED" == true ]] || die "failed to stage the binlogs from the share"
  sync
  ok "binlogs staged"

  # Against the checksums recorded at collection time — the only check that
  # catches a binlog which rotted on the share since it was collected.
  if [[ -f "${LOCAL_BINLOG_DIR}/binlog.sha256" ]]; then
    ( cd "$LOCAL_BINLOG_DIR" && sha256sum -c --quiet binlog.sha256 ) 2>>"$ERROR_LOG" \
      || die "$(leader 'binlog checksums' 'FAILED')" \
             "at least one binlog does not match what was recorded when collected" \
             "it was corrupted on the share or in transit" \
             "applying it would inject corrupt data — refusing"
    ok "binlog checksums"
  else
    nok "binlog checksums" "NO RECORD"
    cont "these binlogs predate checksum recording; integrity unverifiable"
  fi

  # A gap does NOT error during replay: the database comes up looking healthy
  # while every transaction in the hole is missing.
  PREV_SEQ=""
  while read -r f; do
    S="$(seq_of "$(basename "$f")")"
    if [[ -n "$PREV_SEQ" && $((PREV_SEQ + 1)) -ne $S ]]; then
      erro "SEQUENCE GAP: $PREV_SEQ is followed by $S (missing $((PREV_SEQ + 1)))"
      GAPS=$((GAPS + 1))
    fi
    PREV_SEQ="$S"
  done < <(find "$LOCAL_BINLOG_DIR" -maxdepth 1 -type f -name "$BINLOG_GLOB" 2>/dev/null | sort)

  if [[ $GAPS -gt 0 ]]; then
    nok "sequence continuity" "$GAPS GAP(S)"
    cont "replay does NOT error on a gap: those transactions will simply be"
    cont "absent and the database will come up looking healthy. THAT DATA IS LOST."
    cont "usual cause: MySQL purged a binlog before the collector copied it"
    cont "if losing that range is NOT acceptable, press Ctrl+C NOW"
  else
    ok "sequence continuity"
  fi

  mapfile -t STAGED_FILES < <(find "$LOCAL_BINLOG_DIR" -maxdepth 1 -type f -name "$BINLOG_GLOB" -printf '%f\n' 2>/dev/null | sort)
  [[ ${#STAGED_FILES[@]} -gt 0 ]] || die "no binlog files staged locally"

  APPLY_LIST=()
  SEEN=false
  for f in "${STAGED_FILES[@]}"; do
    is_binlog "$f" || continue
    [[ "$f" == "$START_BINLOG" ]] && SEEN=true
    [[ "$SEEN" == true ]] && APPLY_LIST+=("$f")
  done
  if [[ "$SEEN" != true ]]; then
    erro "$(leader 'start binlog' 'NOT COLLECTED')"
    cerr "$START_BINLOG is not among the staged binlogs; available:"
    for f in "${STAGED_FILES[@]}"; do cerr "  $f"; done
    fail_run
  fi
  val "files to apply" "${#APPLY_LIST[@]} from ${START_BINLOG}:${START_POS}"
  sub

  # Everything after a failed file is deliberately NOT applied. APPLY_STARTED
  # switches fail_run to the partially-applied advice.
  APPLY_STARTED=true
  for f in "${APPLY_LIST[@]}"; do
    # --disable-log-bin: replayed events must not re-enter this server's own
    # binlog, or the next backup's chain contains them twice. --skip-gtids is
    # deliberately NOT passed — gtid_mode is OFF, so it would imply duplicate
    # protection this setup does not have.
    if [[ "$f" == "$START_BINLOG" ]]; then
      "$MYSQLBINLOG_BIN" --disable-log-bin --start-position="$START_POS" \
        "$LOCAL_BINLOG_DIR/$f" 2>>"$ERROR_LOG" | mysql_in 2>>"$ERROR_LOG" \
        || die "$(leader "$f" "FAILED from $START_POS")"
      val "$f" "applied from $START_POS"
    else
      "$MYSQLBINLOG_BIN" --disable-log-bin \
        "$LOCAL_BINLOG_DIR/$f" 2>>"$ERROR_LOG" | mysql_in 2>>"$ERROR_LOG" \
        || die "$(leader "$f" 'FAILED')"
      val "$f" "applied"
    fi
    APPLIED_COUNT=$((APPLIED_COUNT + 1))
    LAST_APPLIED="$f"
  done
  APPLY_STARTED=false

  sub
  mysql_up                      || die "MySQL is not running after the binlog apply"
  mysql_q "SELECT 1" >/dev/null || die "cannot connect to MySQL after the binlog apply"
  ok "mysql healthy"

  DB_COUNT=$(mysql_q "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema','mysql','performance_schema','sys')" || echo 0)

  # This is what makes the --binlog-only guard refuse a second run, so it lands
  # immediately after success.
  sed -i "s/^binlogs_applied=.*/binlogs_applied=yes/" "$RESTORE_MARKER" 2>>"$ERROR_LOG" \
    || die "CRITICAL: could not update $RESTORE_MARKER" \
           "the apply SUCCEEDED, but a second --binlog-only run would not be refused" \
           "fix by hand NOW: set binlogs_applied=yes in that file"
  {
    echo "applied_at=$(date '+%F %T')"
    echo "last_applied_binlog=${LAST_APPLIED}"
    echo "files_applied=${APPLIED_COUNT}"
  } >> "$RESTORE_MARKER"
  ok "restore marker updated"

  rm -rf "$LOCAL_BINLOG_DIR" 2>/dev/null || true
  info "applied $APPLIED_COUNT file(s) in $(elapsed "$PHASE_EPOCH")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 14  SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

PHASE="done"; STEP="-"

# The run succeeded, so the staged archive has served its purpose. Left behind
# it would silently hold 14-30GB until someone noticed.
if [[ $STAGE_ARCHIVE -eq 1 && -f "$STAGED_ARCHIVE" ]]; then
  STAGED_FREED="$(hsize "$(stat -c %s "$STAGED_ARCHIVE" 2>/dev/null || echo 0)")"
  rm -f "$STAGED_ARCHIVE" 2>/dev/null \
    && info "removed the staged archive ($STAGED_FREED reclaimed)" \
    || warn "could not remove $STAGED_ARCHIVE — $STAGED_FREED still in use"
fi

emit ""
banner " RESTORE OK  $BACKUP_ID"
kv "duration" "$(elapsed "$START_EPOCH")"
kv "mode"     "$RUN_MODE"
if [[ $DO_RESTORE -eq 1 ]]; then
  kv "archive"       "$SMB_ARCHIVE ($ARCHIVE_SIZE)"
  kv "extracted from" "$([[ "${RESTORE_SOURCE:-}" == "${STAGED_ARCHIVE:-}" ]] \
                         && echo 'local stage (network out of the critical path)' \
                         || echo 'the share directly (STAGE_ARCHIVE=0)')"
  kv "sha256"        "$EXPECTED_SHA"
  kv "backup_type"   "${PREPARED_TYPE:-?}  (prepared by this script)"
fi
if [[ $DO_APPLY -eq 1 ]]; then
  kv "start point"   "${START_BINLOG}:${START_POS}"
  kv "files applied" "$APPLIED_COUNT"
  kv "last applied"  "${LAST_APPLIED:-none}"
  kv "sequence gaps" "$GAPS"
else
  kv "binlog apply"  "SKIPPED — this server is at the BACKUP POINT only"
fi
kv "user databases" "$DB_COUNT"
kv "marker"         "$RESTORE_MARKER"
kv "warnings"       "$WARN_COUNT"
sub
emit " next steps:"
emit "   1. verify row counts on your busiest tables, run application smoke tests"
if [[ $DO_APPLY -eq 0 ]]; then
  emit "   2. binlogs are NOT applied. To bring this server current:"
  emit "        $SELF_CMD --binlog-only --dry-run"
  emit "        $SELF_CMD --binlog-only"
  emit "   3. then take a fresh full backup:  ./backup.sh"
else
  emit "   2. take a fresh full backup IMMEDIATELY:  ./backup.sh"
fi
emit "      the binlog chain restarts at this recovery point — until a new full"
emit "      backup exists, this server has no usable recovery baseline."
sub
kv "logs" "$SECONDARY_LOG_DIR/"
banner " RESULT ok id=${BACKUP_ID} applied=${APPLIED_COUNT} gaps=${GAPS} dur_s=$(( $(date +%s) - START_EPOCH )) warn=${WARN_COUNT}"

publish_logs

trap - ERR INT TERM
exit 0
