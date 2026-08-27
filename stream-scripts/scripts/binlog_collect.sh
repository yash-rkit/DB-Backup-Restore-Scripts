#!/usr/bin/env bash
#
# stream-scripts/physical/binlog_collect.sh — collect binlogs for PITR, SMB/CIFS
#
# Anchors on the newest *_binlog_info on the share and copies every closed
# binlog from that position forward. Runs every 15 minutes from cron.
# Docs: stream-scripts/physical/README.md
#
#   PART 1   configuration        1A set per VM / 1B tune / 1C shared
#   PART 2   log engine
#   PART 3   failure handling
#   PART 4   probes
#   PART 5   share reachability
#   PART 6   backup lock interlock
#   PART 7   anchor discovery
#   PART 8   identity and paths
#   PART 9   pre-flight            10 checks
#   PART 10  start point
#   PART 11  flush and rotate
#   PART 12  copy
#   PART 13  continuity
#   PART 14  summary
#
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# PART 1  CONFIGURATION
#
#   1A  SET PER VM    __SET_ME__ until filled in; the script refuses to start
#   1B  TUNING        working defaults
#   1C  SHARED        must match the other scripts on this host
#   1D  NOT SET HERE  detected at run time, or passed as arguments
#
# What each one means, and what breaks when it is wrong: docs/README.md §11
# ═══════════════════════════════════════════════════════════════════════════

# ── 1A  SET PER VM ─────────────────────────────────────────────────────────
MYSQL_USER="__SET_ME__"                              # needs RELOAD, REPLICATION CLIENT
MYSQL_PASSWORD="__SET_ME__"
SECONDARY_STORAGE_DIR="__SET_ME__"                   # MUST equal backup.sh's, byte for byte
SMB_MOUNT_POINT="__SET_ME__"                         # MUST equal backup.sh's

# ── 1B  TUNING ─────────────────────────────────────────────────────────────
LOCK_STALE_SECONDS=21600                             # 6h; past this, assume backup.sh crashed

# ── 1C  SHARED ─────────────────────────────────────────────────────────────
LOCK_DIR="/var/lock/dbvault"                         # MUST match backup.sh
BACKUP_BASE_NAME="dbvault-stage"                     # basename of backup.sh's BACKUP_BASE

# ── 1D  NOT SET HERE ───────────────────────────────────────────────────────
# Binaries resolved at the end of PART 4, the binlog path at the top of PART 8.
# An env var still wins.
BINLOG_BASE="${BINLOG_BASE:-}"                       # SELECT @@log_bin_basename
MYSQL_BIN="${MYSQL_BIN:-}"                           # PATH
MYSQLBINLOG_BIN="${MYSQLBINLOG_BIN:-}"               # PATH

# ── 1E  GUARD ──────────────────────────────────────────────────────────────
# Refuses to start while any 1A value is still __SET_ME__.

SET_ME_VARS=(MYSQL_USER MYSQL_PASSWORD SECONDARY_STORAGE_DIR SMB_MOUNT_POINT)

check_set_me() {
  local v
  local -a missing=()
  for v in "${SET_ME_VARS[@]}"; do
    if [[ "${!v}" == "__SET_ME__" ]]; then missing+=("$v"); fi
  done
  if (( ${#missing[@]} == 0 )); then return 0; fi
  {
    printf '[ERROR] %s has not been configured for this host.\n' "${BASH_SOURCE[0]##*/}"
    printf '        Open it, find PART 1A, and replace __SET_ME__ in:\n'
    printf '          %s\n' "${missing[@]}"
    printf '        Nothing has been read, written or deleted.\n'
  } >&2
  exit 1
}
check_set_me

# ═══════════════════════════════════════════════════════════════════════════
# PART 2  LOG ENGINE
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

CHECK_N=0
CHECK_TOTAL=10
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
# ═══════════════════════════════════════════════════════════════════════════

START_EPOCH="$(date +%s)"
COPIED=0
SKIPPED=0
ERRORS=0
COPYING=""
STATE_PRE_EXISTED=false

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
  banner " COLLECTION FAILED  ${ANCHOR_BASE:-(no anchor)}"
  kv "failed in" "$at"
  if [[ ${INTERRUPTED:-0} -eq 1 ]]; then
    kv "cause" "interrupted — Ctrl-C or kill"
  elif [[ ${DIED:-0} -eq 0 && -n "${FAILED_CMD:-}" ]]; then
    kv "cause"          "uncaught failure — no check reported this"
    kv "failed command" "$FAILED_CMD"
    kv "at line"        "${FAILED_LINE:-?}  (exit ${FAILED_RC:-?})"
  fi
  kv "duration"  "$(elapsed "$START_EPOCH")"
  kv "copied"    "$COPIED before the failure"
  sub

  # Only a state file WE created: removing a pre-existing one would reset the
  # resume point and re-collect from the anchor.
  if [[ "$STATE_PRE_EXISTED" == false && -n "${STATE_FILE:-}" && -f "$STATE_FILE" ]]; then
    info "removing the state file this run created: $STATE_FILE"
    rm -f "$STATE_FILE" 2>/dev/null || true
  elif [[ -n "${STATE_FILE:-}" ]]; then
    info "preserving the pre-existing state file: $STATE_FILE"
  fi

  if [[ -n "$COPYING" && -n "${TARGET_DIR:-}" && -f "$TARGET_DIR/$COPYING" ]]; then
    info "removing the partially copied $COPYING"
    rm -f "$TARGET_DIR/$COPYING" 2>/dev/null || true
  fi

  sub
  kv "error log" "${ERROR_LOG:-(none)}"
  banner " RESULT failed anchor=${ANCHOR_BASE:-none} phase=${at% *} step=${at#* } copied=${COPIED} dur_s=$(( $(date +%s) - START_EPOCH )) warn=${WARN_COUNT}"
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

free_gb() { df -BG "$1" | awk 'NR==2 {print $4}' | sed 's/G//'; }
mysql_q() { "$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -NBe "$1" 2>/dev/null; }

# PART 1D: looked up in PATH, unless the environment named one.
resolve_bin() {
  local var="$1" name="$2"
  local path="${!var}"
  if [[ -n "$path" ]]; then
    if [[ -x "$path" ]]; then return 0; fi
    echo "[ERROR] $var is set to '$path', which is not an executable file." >&2
    exit 1
  fi
  path="$(command -v "$name" 2>/dev/null || true)"
  if [[ -z "$path" ]]; then
    echo "[ERROR] '$name' is not in PATH — install it, or run with $var=/full/path/to/$name" >&2
    exit 1
  fi
  printf -v "$var" '%s' "$path"
}

writable() {
  local probe="$1/.probe_$$"
  touch "$probe" 2>/dev/null || return 1
  rm -f "$probe"
  return 0
}

mysql_up() {
  systemctl is-active --quiet mysql  2>/dev/null && return 0
  systemctl is-active --quiet mysqld 2>/dev/null && return 0
  pgrep -x mysqld >/dev/null 2>&1    && return 0
  return 1
}

# A real binlog ends in .NNNNNN — excludes binlog.index and binlog.sha256.
is_binlog() { [[ "$1" =~ \.[0-9]{6}$ ]]; }

# SHOW BINARY LOG STATUS is 8.4+; SHOW MASTER STATUS covers older servers.
active_binlog() {
  local r
  r=$(mysql_q "SHOW BINARY LOG STATUS" | awk '{print $1}') \
    || r=$(mysql_q "SHOW MASTER STATUS" | awk '{print $1}')
  printf '%s' "$r"
}

# Leading zeros stripped: bash reads 000042 as OCTAL and 000008 is invalid octal.
seq_of() {
  local s="${1##*.}"
  s="${s#"${s%%[!0]*}"}"
  printf '%s' "${s:-0}"
}

resolve_bin MYSQL_BIN       mysql
resolve_bin MYSQLBINLOG_BIN mysqlbinlog

# ═══════════════════════════════════════════════════════════════════════════
# PART 5  SHARE REACHABILITY
#
# Before the anchor lookup: on an unreachable mount that lookup finds nothing
# and would exit 0, reporting a healthy run that collected nothing.
# ═══════════════════════════════════════════════════════════════════════════

command -v mountpoint >/dev/null 2>&1 || {
  echo "[ERROR] Required command not found: mountpoint (util-linux)." >&2
  exit 1
}

if ! mountpoint -q "$SMB_MOUNT_POINT"; then
  echo "[ERROR] SMB share is NOT mounted at: $SMB_MOUNT_POINT" >&2
  echo "[ERROR] Refusing to run — collecting with no reachable destination" >&2
  echo "[ERROR] would silently lose PITR coverage." >&2
  exit 1
fi

# A missing directory is ambiguous, and the parent tells the two cases apart.
# backup.sh is the only thing that creates this path, so on a server whose
# binlog cron starts before its first backup the directory is simply not there
# yet — the normal state of a new server between midnight and its noon backup,
# and not worth an error every fifteen minutes. But if the PARENT is missing
# too, the share layout is wrong rather than merely empty, and that is the
# typo this check has always existed to catch.
if [[ ! -d "$SECONDARY_STORAGE_DIR" ]]; then
  PARENT_DIR="$(dirname "$SECONDARY_STORAGE_DIR")"
  if [[ -d "$PARENT_DIR" ]]; then
    echo " no backup directory yet: $SECONDARY_STORAGE_DIR"
    echo " backup.sh creates it on its first run — nothing to collect"
    exit 0
  fi
  echo "[ERROR] Mounted, but missing: $SECONDARY_STORAGE_DIR" >&2
  echo "[ERROR] Its parent is missing too: $PARENT_DIR" >&2
  echo "[ERROR] That is a wrong path, not a server awaiting its first backup." >&2
  exit 1
fi

# `ls` can be served from the attribute cache; only a write proves the mount is
# alive rather than a stale handle.
if ! writable "$SECONDARY_STORAGE_DIR"; then
  echo "[ERROR] Not writable (stale handle or auth failure): $SECONDARY_STORAGE_DIR" >&2
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 6  BACKUP LOCK INTERLOCK
# ═══════════════════════════════════════════════════════════════════════════

LOCK_FILE="${LOCK_DIR}/${BACKUP_BASE_NAME}_$(date +%Y%m%d)_lock"

if [[ -f "$LOCK_FILE" ]]; then
  LOCK_AGE=$(( $(date +%s) - $(stat -c%Y "$LOCK_FILE") ))
  if [[ $LOCK_AGE -lt $LOCK_STALE_SECONDS ]]; then
    echo " backup in progress (lock ${LOCK_AGE}s old) — skipping this run"
    exit 0
  fi
  LOCK_STALE_NOTE="lock was STALE (${LOCK_AGE}s > ${LOCK_STALE_SECONDS}s) — backup.sh may have crashed"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 7  ANCHOR DISCOVERY
#
# Newest *_binlog_info, chosen by FILENAME: SMB mtime is the server's clock and
# is attribute-cached, so a skew would silently pick an older backup. Date and
# time sort as SEPARATE keys — a plain lexical sort puts 20260820_143005 before
# 20260820 ('_' sorts before end-of-string).
# ═══════════════════════════════════════════════════════════════════════════

ANCHOR_FILE=$(
  find "$SECONDARY_STORAGE_DIR" -maxdepth 1 -type f -name "*_binlog_info" 2>/dev/null |
  while IFS= read -r p; do
    b="$(basename "$p" _binlog_info)"
    d="${b%%_*}"; t="${b#"$d"}"; t="${t#_}"
    printf '%s %s %s\n' "$d" "${t:-000000}" "$p"
  done | sort -k1,1 -k2,2 | tail -1 | cut -d' ' -f3-
)

if [[ -z "$ANCHOR_FILE" ]]; then
  echo " no backup anchor (*_binlog_info) in $SECONDARY_STORAGE_DIR"
  echo " the backup has probably not completed yet — nothing to collect"
  exit 0
fi

ANCHOR_BASE="$(basename "$ANCHOR_FILE" _binlog_info)"

# ═══════════════════════════════════════════════════════════════════════════
# PART 8  IDENTITY AND PATHS
# ═══════════════════════════════════════════════════════════════════════════

TARGET_DIR="${SECONDARY_STORAGE_DIR}/binlog/${ANCHOR_BASE}"
STATE_FILE="${TARGET_DIR}/last_copied_binlog"
LOG_DIR="${SECONDARY_STORAGE_DIR}/logs/${ANCHOR_BASE}/collect"
RUN_LOG="${LOG_DIR}/collect.log"
ERROR_LOG="${LOG_DIR}/collect_errors.log"

# PART 1D: a stale path finds an empty directory, copies nothing, and reports
# a clean run — the worst failure available to this script.
if [[ -z "$BINLOG_BASE" ]]; then
  BINLOG_BASE="$(mysql_q 'SELECT @@log_bin_basename' || true)"
  BINLOG_SOURCE="@@log_bin_basename"
  if [[ -z "$BINLOG_BASE" ]]; then
    {
      echo "[ERROR] could not read @@log_bin_basename from MySQL."
      echo "        MySQL may be down, or binary logging may be off."
      echo "        To override: BINLOG_BASE=/path/to/binlog $0"
    } >&2
    exit 1
  fi
else
  BINLOG_SOURCE="environment"
fi

BINLOG_DIR="$(dirname "$BINLOG_BASE")"
BINLOG_PREFIX="$(basename "$BINLOG_BASE")"
BINLOG_GLOB="${BINLOG_PREFIX}.[0-9][0-9][0-9][0-9][0-9][0-9]"

# Must be read BEFORE anything can create it, or fail_run deletes a state file
# it did not create.
[[ -f "$STATE_FILE" ]] && STATE_PRE_EXISTED=true

mkdir -p "$TARGET_DIR" 2>/dev/null || {
  echo "[ERROR] Failed to create $TARGET_DIR" >&2
  exit 1
}
mkdir -p "$LOG_DIR" 2>/dev/null || {
  echo "[ERROR] Failed to create $LOG_DIR" >&2
  exit 1
}
[[ -f "$ERROR_LOG" ]] || printf 'binlog collection errors for anchor %s\n\n' "$ANCHOR_BASE" > "$ERROR_LOG"

# Appended across runs — this fires every ~15 minutes.
emit ""
banner " COLLECT RUN  anchor $ANCHOR_BASE"
kv "started"     "$(date '+%F %T %Z')"
kv "host"        "$(hostname -s 2>/dev/null || echo unknown)"
kv "anchor file" "$ANCHOR_FILE"
kv "source"      "$BINLOG_DIR  ($BINLOG_SOURCE)"
kv "destination" "$TARGET_DIR"
sub

[[ -n "${LOCK_STALE_NOTE:-}" ]] && { nok "backup lock" "STALE"; cont "$LOCK_STALE_NOTE"; cont "proceeding; check backup.sh status manually"; }

# ═══════════════════════════════════════════════════════════════════════════
# PART 9  PRE-FLIGHT
# ═══════════════════════════════════════════════════════════════════════════

phase preflight
PREFLIGHT_EPOCH="$PHASE_EPOCH"

check
if [[ $EUID -ne 0 ]]; then
  nok "user privileges" "NOT ROOT"
  cont "must read $BINLOG_DIR"
else
  ok "user privileges"
fi

check
for cmd in awk sed cp du df find grep wc stat sort sync basename dirname; do
  command -v "$cmd" >/dev/null 2>&1 \
    || die "$(leader 'required binaries' 'MISSING')" "not found in PATH: $cmd"
done
for bin in "$MYSQL_BIN" "$MYSQLBINLOG_BIN"; do
  [[ -x "$bin" ]] || die "$(leader 'required binaries' 'MISSING')" "not executable: $bin"
done
ok "required binaries"

check
mysql_up || die "$(leader 'mysql running' 'NO')"
ok "mysql running"

check
mysql_q "SELECT 1" >/dev/null \
  || die "$(leader 'mysql connection' 'FAILED')" "user: $MYSQL_USER"
ok "mysql connection"

check
[[ "$(mysql_q 'SELECT @@log_bin' || echo 0)" == "1" ]] \
  || die "$(leader 'binary logging' 'DISABLED')" \
         "nothing to collect and no PITR is possible until it is enabled"
ok "binary logging"

check
[[ -d "$BINLOG_DIR" ]] \
  || die "$(leader 'binlog directory' 'MISSING')" "not found: $BINLOG_DIR"
ok "binlog directory"

check
writable "$TARGET_DIR" \
  || die "$(leader 'destination writable' 'NO')" "not writable: $TARGET_DIR"
ok "destination writable"

check
[[ -s "$ANCHOR_FILE" ]] \
  || die "$(leader 'anchor readable' 'NO')" "empty or unreadable: $ANCHOR_FILE"
ok "anchor readable"

check
SOURCE_GB=$(du -sb "$BINLOG_DIR" 2>/dev/null | awk '{print int($1/1073741824)+1}')
DEST_FREE_GB=$(free_gb "$TARGET_DIR")
[[ $DEST_FREE_GB -ge $SOURCE_GB ]] \
  || die "$(leader 'disk space' 'INSUFFICIENT')" \
         "need up to ${SOURCE_GB}GB on the share, have ${DEST_FREE_GB}GB"
val "disk space" "need <=${SOURCE_GB}GB / free ${DEST_FREE_GB}GB"

check
SOURCE_COUNT=$(find "$BINLOG_DIR" -maxdepth 1 -type f -name "$BINLOG_GLOB" 2>/dev/null | wc -l)
[[ $SOURCE_COUNT -gt 0 ]] \
  || die "$(leader 'binlogs present' 'NONE')" "no ${BINLOG_GLOB} in $BINLOG_DIR"
val "binlogs present" "$SOURCE_COUNT on the server"

STEP="-"
info "$CHECK_N checks passed, ${WARN_COUNT} warning(s)   ($(elapsed "$PREFLIGHT_EPOCH"))"
sub

# ═══════════════════════════════════════════════════════════════════════════
# PART 10  START POINT
#
# The state file if we have collected before, otherwise the backup anchor.
# ═══════════════════════════════════════════════════════════════════════════

phase start

if [[ -s "$STATE_FILE" ]]; then
  START_BINLOG="$(cat "$STATE_FILE")"
  val "resuming from" "$START_BINLOG"
else
  START_BINLOG="$(awk '{print $1}' "$ANCHOR_FILE")"
  val "starting from" "$START_BINLOG (backup anchor)"
fi

is_binlog "$START_BINLOG" \
  || die "$(leader 'start binlog' "invalid: $START_BINLOG")" "expected <prefix>.NNNNNN"

# Purged from the server: fall back to the earliest still on disk. Partial
# coverage beats none, but the gap is real.
if [[ ! -f "$BINLOG_DIR/$START_BINLOG" ]]; then
  EARLIEST=$(find "$BINLOG_DIR" -maxdepth 1 -type f -name "$BINLOG_GLOB" 2>/dev/null \
             | sort | head -1 || true)
  [[ -n "$EARLIEST" ]] \
    || die "$(leader 'start binlog' 'PURGED')" "and no binlogs remain on the server at all"
  EARLIEST="$(basename "$EARLIEST")"
  nok "start binlog" "PURGED"
  cont "$START_BINLOG is gone from $BINLOG_DIR — MySQL purged it"
  cont "falling back to the earliest available: $EARLIEST"
  cont "COVERAGE GAP between $START_BINLOG and $EARLIEST — PITR in that range is LOST"
  cont "prevent it: binlog_expire_logs_seconds >= 3x the backup duration"
  START_BINLOG="$EARLIEST"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 11  FLUSH AND ROTATE
#
# Closes the active binlog so it becomes copyable; the new active one is skipped.
# ═══════════════════════════════════════════════════════════════════════════

phase flush

mysql_q "FLUSH BINARY LOGS" >/dev/null || die "FLUSH BINARY LOGS failed"
sync
sleep 2

ACTIVE_BINLOG="$(active_binlog)"
[[ -n "$ACTIVE_BINLOG" ]] && is_binlog "$ACTIVE_BINLOG" \
  || die "$(leader 'active binlog' "invalid: ${ACTIVE_BINLOG:-(empty)}")" \
         "could not determine the current binlog from SHOW BINARY LOG STATUS"
val "rotated, now active" "$ACTIVE_BINLOG (skipped)"

# ═══════════════════════════════════════════════════════════════════════════
# PART 12  COPY
#
# Every file must survive: byte-size match, a mysqlbinlog parse, and a recorded
# checksum. Only then does the resume point advance.
# ═══════════════════════════════════════════════════════════════════════════

phase copy

mapfile -t CANDIDATES < <(
  find "$BINLOG_DIR" -maxdepth 1 -type f -name "$BINLOG_GLOB" -printf '%f\n' 2>/dev/null | sort
)
[[ ${#CANDIDATES[@]} -gt 0 ]] || die "no binlog files to process"

FOUND_START=false
for f in "${CANDIDATES[@]}"; do
  [[ "$f" == "$START_BINLOG" ]] && FOUND_START=true
  if [[ "$FOUND_START" != true ]]; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  [[ "$f" == "$ACTIVE_BINLOG" ]] && continue          # still being written
  [[ -f "$TARGET_DIR/$f" ]]      && continue          # already collected

  SRC="$BINLOG_DIR/$f"
  if [[ ! -r "$SRC" ]]; then
    warn "$f unreadable — skipped"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  SRC_BYTES=$(stat -c%s "$SRC" 2>/dev/null || echo 0)
  if [[ "$SRC_BYTES" -eq 0 ]]; then
    warn "$f is empty — skipped"
    continue
  fi

  COPYING="$f"

  # `cp` without -p: CIFS cannot preserve ownership, so -p returns non-zero on
  # copies whose DATA landed fine. The checks below are the real guarantee.
  if ! cp "$SRC" "$TARGET_DIR/" 2>>"$ERROR_LOG"; then
    warn "$(leader "$f" 'COPY FAILED')"
    rm -f "$TARGET_DIR/$f" 2>/dev/null || true
    COPYING=""; ERRORS=$((ERRORS + 1))
    continue
  fi

  DST_BYTES=$(stat -c%s "$TARGET_DIR/$f" 2>/dev/null || echo 0)
  if [[ "$SRC_BYTES" -ne "$DST_BYTES" ]]; then
    warn "$(leader "$f" 'SIZE MISMATCH')"
    cont "source $SRC_BYTES, destination $DST_BYTES"
    rm -f "$TARGET_DIR/$f" 2>/dev/null || true
    COPYING=""; ERRORS=$((ERRORS + 1))
    continue
  fi

  # A matching size proves the COPY completed, not that the SOURCE was intact:
  # a truncated binlog copies perfectly and fails during recovery.
  if ! "$MYSQLBINLOG_BIN" "$TARGET_DIR/$f" >/dev/null 2>>"$ERROR_LOG"; then
    warn "$(leader "$f" 'PARSE FAILED')"
    cont "truncated or corrupt — not archiving a binlog that cannot be replayed"
    rm -f "$TARGET_DIR/$f" 2>/dev/null || true
    COPYING=""; ERRORS=$((ERRORS + 1))
    continue
  fi

  # Bare filenames, so restore.sh can verify from its own staging directory.
  if ! (cd "$TARGET_DIR" && sha256sum "$f" >> binlog.sha256) 2>>"$ERROR_LOG"; then
    warn "$(leader "$f" 'CHECKSUM WRITE FAILED')"
    rm -f "$TARGET_DIR/$f" 2>/dev/null || true
    COPYING=""; ERRORS=$((ERRORS + 1))
    continue
  fi

  COPYING=""
  echo "$f" > "$STATE_FILE"                           # advance only when clean
  COPIED=$((COPIED + 1))
  val "$f" "$(hsize "$SRC_BYTES")"
done

[[ "$FOUND_START" == true ]] \
  || die "$(leader 'start binlog' 'NOT IN LIST')" \
         "$START_BINLOG is missing after the purge fallback — investigate"

if [[ $COPIED -eq 0 ]]; then
  info "nothing new to copy ($SKIPPED before the start point, active one skipped)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 13  CONTINUITY
#
# Replay does NOT error on a gap: it applies what is there and carries on,
# losing every transaction in the hole. Nothing downstream can detect it.
# ═══════════════════════════════════════════════════════════════════════════

phase verify

GAPS=0
PREV_SEQ=""
while read -r f; do
  S="$(seq_of "$(basename "$f")")"
  if [[ -n "$PREV_SEQ" && $((PREV_SEQ + 1)) -ne $S ]]; then
    erro "SEQUENCE GAP: $PREV_SEQ is followed by $S (missing $((PREV_SEQ + 1)))"
    GAPS=$((GAPS + 1))
  fi
  PREV_SEQ="$S"
done < <(find "$TARGET_DIR" -maxdepth 1 -type f -name "$BINLOG_GLOB" 2>/dev/null | sort)

if [[ $GAPS -gt 0 ]]; then
  cerr "point-in-time recovery across the gap(s) above is NOT possible"
  cerr "usual cause: MySQL purged a binlog before it was collected"
  cerr "prevent it: binlog_expire_logs_seconds >= 3x the backup duration"
  ERRORS=$((ERRORS + GAPS))
else
  ok "sequence continuous"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 14  SUMMARY
#
# Any error exits non-zero: a monitored job that cannot fail is worse than no
# monitoring. Validated binlogs stay archived and the state file still points at
# the last good one, so the next run resumes correctly.
# ═══════════════════════════════════════════════════════════════════════════

trap - ERR INT TERM
PHASE="done"; STEP="-"

ARCHIVED=$(find "$TARGET_DIR" -maxdepth 1 -type f -name "$BINLOG_GLOB" 2>/dev/null | wc -l)

sub
if [[ $ERRORS -eq 0 ]]; then
  banner " COLLECT OK  anchor $ANCHOR_BASE"
else
  banner " COLLECT INCOMPLETE  anchor $ANCHOR_BASE"
fi
kv "duration"       "$(elapsed "$START_EPOCH")"
kv "copied"         "$COPIED"
kv "skipped"        "$SKIPPED (before the start point)"
kv "errors"         "$ERRORS"
kv "warnings"       "$WARN_COUNT"
kv "active binlog"  "$ACTIVE_BINLOG (not collected)"
kv "resume point"   "$([[ -s "$STATE_FILE" ]] && cat "$STATE_FILE" || echo none)"
kv "total archived" "$ARCHIVED"
kv "archive size"   "$(du -sh "$TARGET_DIR" 2>/dev/null | awk '{print $1}')"
kv "destination"    "$TARGET_DIR"
kv "logs"           "$LOG_DIR/"

if [[ $ERRORS -gt 0 ]]; then
  banner " RESULT failed anchor=${ANCHOR_BASE} copied=${COPIED} errors=${ERRORS} gaps=${GAPS} dur_s=$(( $(date +%s) - START_EPOCH ))"
  erro "the PITR chain is NOT intact — investigate before relying on it"
  exit 1
fi

banner " RESULT ok anchor=${ANCHOR_BASE} copied=${COPIED} archived=${ARCHIVED} dur_s=$(( $(date +%s) - START_EPOCH )) warn=${WARN_COUNT}"
exit 0
