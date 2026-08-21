#!/usr/bin/env bash
#
# server/physical/binlog_collect.sh — collect binlogs for PITR, SMB/CIFS storage
#
# Docs: instructions/server/physical/README.md
#
set -euo pipefail

############################
# CONFIGURATION
############################

MYSQL_USER="Admin"
MYSQL_PASSWORD=""

# MUST match SECONDARY_STORAGE_DIR in backup.sh, or the anchors are never found.
SECONDARY_STORAGE_DIR="/livestorage/YK/Restore-VM"

# The CIFS MOUNT POINT itself — MUST match SMB_MOUNT_POINT in backup.sh.
SMB_MOUNT_POINT="/livestorage"

ARCHIVE_DIR="$SECONDARY_STORAGE_DIR"
BINLOG_ARCHIVE_BASE="${ARCHIVE_DIR}/binlog"
LOG_BASE="${ARCHIVE_DIR}/logs"

# MySQL binlog location (base name without extension)
BINLOG_BASE="/Data/mysql/binlog"

MYSQL_BIN="/usr/bin/mysql"

# Proves each copied binlog PARSES, not merely that it copied byte-for-byte.
MYSQLBINLOG_BIN="/usr/bin/mysqlbinlog"

# Backup lock — LOCAL. MUST match LOCK_DIR + the BACKUP_BASE basename in
# backup.sh: that script writes the lock, this one polls it.
LOCK_DIR="/var/lock/dbvault"
BACKUP_BASE_NAME="dbvault-stage"    # basename of BACKUP_BASE in backup.sh

# Past this age the backup probably crashed without cleanup — proceed anyway.
LOCK_STALE_SECONDS=21600

############################
# SECONDARY STORAGE REACHABILITY CHECK
# Must run BEFORE the anchor lookup: on an unreachable mount that lookup finds
# nothing and exits 0, reporting a healthy run that collected nothing. Failing
# loudly here is the whole point — see the README.
############################

if ! command -v mountpoint >/dev/null 2>&1; then
  echo "[$(date '+%F %T')] [ERROR] Required command not found: mountpoint" >&2
  exit 1
fi

if ! mountpoint -q "$SMB_MOUNT_POINT"; then
  echo "[$(date '+%F %T')] [ERROR] SMB share is NOT mounted at: $SMB_MOUNT_POINT" >&2
  echo "[$(date '+%F %T')] [ERROR] The path may still exist as an empty local directory." >&2
  echo "[$(date '+%F %T')] [ERROR] Refusing to run — collecting binlogs with no reachable" >&2
  echo "[$(date '+%F %T')] [ERROR] destination would silently lose PITR coverage." >&2
  exit 1
fi

if [[ ! -d "$ARCHIVE_DIR" ]]; then
  echo "[$(date '+%F %T')] [ERROR] Secondary storage not accessible: $ARCHIVE_DIR" >&2
  echo "[$(date '+%F %T')] [ERROR] The share is mounted but this directory is missing." >&2
  exit 1
fi

# A mounted share can still be dead (stale handle, expired credentials). Only
# an actual write proves otherwise — `ls` can come from the attribute cache.
SMB_PROBE="${ARCHIVE_DIR}/.probe_$$"
if ! touch "$SMB_PROBE" 2>/dev/null; then
  echo "[$(date '+%F %T')] [ERROR] Secondary storage not writable (stale handle or auth failure): $ARCHIVE_DIR" >&2
  echo "[$(date '+%F %T')] [ERROR] Refusing to run." >&2
  exit 1
fi
rm -f "$SMB_PROBE" 2>/dev/null || true

############################
# LOCK FILE CHECK — backup running: skip. Lock stale: warn and proceed.
############################

TODAY_LOCK="$(date +%Y%m%d)"
LOCK_FILE="${LOCK_DIR}/${BACKUP_BASE_NAME}_${TODAY_LOCK}_lock"

if [[ -f "$LOCK_FILE" ]]; then
  LOCK_AGE=$(( $(date +%s) - $(stat -c%Y "$LOCK_FILE") ))

  if [[ $LOCK_AGE -lt $LOCK_STALE_SECONDS ]]; then
    echo "[$(date '+%F %T')] [INFO] Lock file present ($LOCK_FILE, age: ${LOCK_AGE}s). Backup in progress. Skipping this run."
    exit 0
  else
    echo "[$(date '+%F %T')] [WARN] Lock file is STALE ($LOCK_FILE, age: ${LOCK_AGE}s, threshold: ${LOCK_STALE_SECONDS}s)."
    echo "[$(date '+%F %T')] [WARN] backup.sh may have crashed without cleanup. Proceeding with binlog collection."
    echo "[$(date '+%F %T')] [WARN] Manual investigation of backup.sh status is recommended."
  fi
fi

############################
# EARLY INITIALIZATION
############################

TARGET_BINLOG_DIR=""
STATE_FILE=""
RUN_LOG=""
ERROR_LOG=""
COPIED_COUNT=0
SKIPPED_COUNT=0
ERROR_COUNT=0
START_BINLOG=""
CURRENT_BINLOG=""
FOUND_START=false

############################
# HELPER FUNCTIONS
############################

log_msg() {
  if [[ -n "$RUN_LOG" && -d "$(dirname "$RUN_LOG")" ]]; then
    echo "[$(date '+%F %T')] [INFO] $1" | tee -a "$RUN_LOG"
  else
    echo "[$(date '+%F %T')] [INFO] $1"
  fi
}

log_error() {
  if [[ -n "$RUN_LOG" && -d "$(dirname "$RUN_LOG")" ]]; then
    echo "[$(date '+%F %T')] [ERROR] $1" | tee -a "$RUN_LOG" >&2
  else
    echo "[$(date '+%F %T')] [ERROR] $1" >&2
  fi

  if [[ -n "$ERROR_LOG" && -d "$(dirname "$ERROR_LOG")" ]]; then
    echo "[$(date '+%F %T')] [ERROR] $1" >> "$ERROR_LOG"
  fi
}

log_warn() {
  if [[ -n "$RUN_LOG" && -d "$(dirname "$RUN_LOG")" ]]; then
    echo "[$(date '+%F %T')] [WARN] $1" | tee -a "$RUN_LOG"
  else
    echo "[$(date '+%F %T')] [WARN] $1"
  fi
}

cleanup_on_error() {
  log_error "Binlog collection failed. Cleaning up..."

  # Only if WE created it this run — removing a pre-existing one would reset
  # the resume point and re-collect from the anchor.
  if [[ "$STATE_FILE_PRE_EXISTED" == false && -n "${STATE_FILE:-}" && -f "$STATE_FILE" ]]; then
    log_msg "Removing newly created state file: $STATE_FILE"
    rm -f "$STATE_FILE" 2>/dev/null || true
  else
    log_msg "Preserving pre-existing state file: $STATE_FILE"
  fi

  if [[ -n "${CURRENT_COPYING_FILE:-}" && -f "$TARGET_BINLOG_DIR/$CURRENT_COPYING_FILE" ]]; then
    log_msg "Removing partially copied file: $CURRENT_COPYING_FILE"
    rm -f "$TARGET_BINLOG_DIR/$CURRENT_COPYING_FILE" 2>/dev/null || true
  fi

  log_error "Binlog collection aborted. Check logs: ${RUN_LOG:-'(not initialized)'}"

  trap - ERR INT TERM
  exit 1
}

trap cleanup_on_error ERR INT TERM

mysql_cmd() {
  "$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$@"
}

test_mysql_connection() {
  if ! mysql_cmd -e "SELECT 1" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# SHOW BINARY LOG STATUS is 8.4+; SHOW MASTER STATUS covers older servers.
get_current_binlog() {
  local result
  result=$(mysql_cmd -NBe "SHOW BINARY LOG STATUS" 2>/dev/null | awk '{print $1}') || \
  result=$(mysql_cmd -NBe "SHOW MASTER STATUS" 2>/dev/null | awk '{print $1}')
  echo "$result"
}

# A real binlog ends in .NNNNNN — excludes binlog.index and binlog.sha256.
is_binlog_file() {
  local filename="$1"
  if [[ "$filename" =~ \.[0-9]{6}$ ]]; then
    return 0
  else
    return 1
  fi
}

validate_writable() {
  local dir="$1"
  local test_file="$dir/.write_test_$$"

  if ! touch "$test_file" 2>/dev/null; then
    return 1
  fi

  rm -f "$test_file"
  return 0
}

get_free_space_gb() {
  local path="$1"
  df -BG "$path" | awk 'NR==2 {print $4}' | sed 's/G//'
}

is_mysql_running() {
  if systemctl is-active --quiet mysql 2>/dev/null || \
     systemctl is-active --quiet mysqld 2>/dev/null; then
    return 0
  fi

  if pgrep -x mysqld >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

get_binlog_size_gb() {
  local binlog_dir="$1"
  du -sb "$binlog_dir" 2>/dev/null | awk '{print int($1/1024/1024/1024)+1}'
}

format_size() {
  local size="$1"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec-i --suffix=B "$size" 2>/dev/null || echo "${size} bytes"
  else
    echo "${size} bytes"
  fi
}

############################
# DERIVED PATHS
############################

TODAY="$(date +%Y%m%d)"

############################
# LOCATE THE BACKUP ANCHOR — the latest *_binlog_info in ARCHIVE_DIR
#
# Selected by FILENAME, not mtime: SMB mtime is the server's clock and is
# attribute-cached, so a skew would silently pick an older backup.
#
# Date and time are sorted as SEPARATE keys. A plain lexical sort puts
# 20260711_143005 BEFORE 20260711 ('_' sorts before end-of-string), which would
# ignore a same-day rerun. A bare date is treated as time 000000.
############################

ANCHOR_FILE=$(
  find "$ARCHIVE_DIR" -maxdepth 1 -type f -name "*_binlog_info" 2>/dev/null |
  while IFS= read -r p; do
    b="$(basename "$p" _binlog_info)"        # 20260711 or 20260711_143005
    d="${b%%_*}"                             # date part
    t="${b#"$d"}"; t="${t#_}"                # time part, empty if none
    printf '%s %s %s\n' "$d" "${t:-000000}" "$p"
  done | sort -k1,1 -k2,2 | tail -1 | cut -d' ' -f3-
)

if [[ -z "$ANCHOR_FILE" ]]; then
  echo "[$(date '+%F %T')] [INFO] No backup anchor (*_binlog_info) found in $ARCHIVE_DIR." >&2
  echo "[$(date '+%F %T')] [INFO] Backup has likely not completed yet. Nothing to collect. Exiting cleanly." >&2
  exit 0
fi

BINLOG_INFO_FILE="$ANCHOR_FILE"
ANCHOR_BASE="$(basename "$ANCHOR_FILE" _binlog_info)"    # 20260711 (or 20260711_143005)
REFERENCE_DATE="$(echo "$ANCHOR_BASE" | grep -oE '[0-9]{8}' | head -1)"
BINLOG_INFO_SOURCE="$ANCHOR_BASE"
TARGET_BINLOG_DIR="${BINLOG_ARCHIVE_BASE}/${ANCHOR_BASE}"
STATE_FILE="${TARGET_BINLOG_DIR}/last_copied_binlog"

# Under logs/<anchor>/collect/, not beside the binlogs, so binlog/<anchor>/
# stays pure restorable data. Appended across runs — this fires every ~15 min.
COLLECT_LOG_DIR="${LOG_BASE}/${ANCHOR_BASE}/collect"
RUN_LOG="${COLLECT_LOG_DIR}/collect.log"
ERROR_LOG="${COLLECT_LOG_DIR}/collect_errors.log"

START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
START_EPOCH="$(date +%s)"

BINLOG_DIR="$(dirname "$BINLOG_BASE")"

############################
# STATE FILE PRE-EXISTENCE CHECK
# Must stay AFTER STATE_FILE is defined, or it is always false and
# cleanup_on_error deletes a state file it did not create.
############################

STATE_FILE_PRE_EXISTED=false
if [[ -f "$STATE_FILE" ]]; then
  STATE_FILE_PRE_EXISTED=true
fi

############################
# SETUP
############################

if ! mkdir -p "$TARGET_BINLOG_DIR" 2>/dev/null; then
  echo "[$(date '+%F %T')] [ERROR] Failed to create target directory: $TARGET_BINLOG_DIR" >&2
  trap - ERR INT TERM
  exit 1
fi

# Log dir is separate from the binlog dir — create it before the first log write.
if ! mkdir -p "$COLLECT_LOG_DIR" 2>/dev/null; then
  echo "[$(date '+%F %T')] [ERROR] Failed to create log directory: $COLLECT_LOG_DIR" >&2
  trap - ERR INT TERM
  exit 1
fi

cat >> "$ERROR_LOG" << EOF
========================================
BINLOG COLLECTION ERROR LOG
========================================
Date: $(date '+%F %T')
========================================

EOF

############################
# PRE-FLIGHT CHECKS
############################

log_msg "===================================================="
log_msg "Starting comprehensive pre-flight checks..."
log_msg "===================================================="
log_msg "Backup anchor      : $BINLOG_INFO_FILE"
log_msg "Backup reference   : $BINLOG_INFO_SOURCE"
log_msg "Binlog target dir  : $TARGET_BINLOG_DIR"

log_msg "Check 1/10: Verifying user privileges..."
if [[ $EUID -ne 0 ]]; then
  log_warn "Not running as root. Ensure user has sufficient privileges."
else
  log_msg "Running as root"
fi

log_msg "Check 2/10: Verifying required binaries..."
REQUIRED_COMMANDS=(awk cp du df find basename dirname grep wc stat sync)
for cmd in "${REQUIRED_COMMANDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "Required command not found: $cmd"
    trap - ERR INT TERM
    exit 1
  fi
done

if [[ ! -x "$MYSQL_BIN" ]]; then
  log_error "MySQL binary not executable: $MYSQL_BIN"
  trap - ERR INT TERM
  exit 1
fi

# Required, not optional: it validates every copied binlog.
if [[ ! -x "$MYSQLBINLOG_BIN" ]]; then
  log_error "mysqlbinlog binary not executable: $MYSQLBINLOG_BIN"
  trap - ERR INT TERM
  exit 1
fi

log_msg "All required binaries found"

log_msg "Check 3/10: Verifying MySQL is running..."
if ! is_mysql_running; then
  log_error "MySQL is not running"
  trap - ERR INT TERM
  exit 1
fi
log_msg "MySQL is running"

log_msg "Check 4/10: Testing MySQL connection..."
if ! test_mysql_connection; then
  log_error "Cannot connect to MySQL with provided credentials"
  log_error "User: $MYSQL_USER"
  trap - ERR INT TERM
  exit 1
fi
log_msg "MySQL connection successful"

log_msg "Check 5/10: Verifying binary logging is enabled..."
if [[ ! -d "$BINLOG_DIR" ]]; then
  log_error "Binlog directory not found: $BINLOG_DIR"
  trap - ERR INT TERM
  exit 1
fi
log_msg "Binlog directory exists: $BINLOG_DIR"

log_msg "Check 6/10: Verifying target directory is writable..."
if ! validate_writable "$TARGET_BINLOG_DIR"; then
  log_error "Target directory is not writable: $TARGET_BINLOG_DIR"
  trap - ERR INT TERM
  exit 1
fi
log_msg "Target directory is writable"

log_msg "Check 7/10: Verifying binlog info file..."
log_msg "Using binlog info from: $BINLOG_INFO_SOURCE ($BINLOG_INFO_FILE)"
if [[ ! -s "$BINLOG_INFO_FILE" ]]; then
  log_error "Binlog info file is empty or unreadable: $BINLOG_INFO_FILE"
  trap - ERR INT TERM
  exit 1
fi
log_msg "Binlog info file verified"

log_msg "Check 8/10: Checking available disk space..."
BINLOG_SIZE=$(get_binlog_size_gb "$BINLOG_DIR")
TARGET_FREE=$(get_free_space_gb "$TARGET_BINLOG_DIR")
log_msg "Estimated binlog size: ${BINLOG_SIZE}GB"
log_msg "Free space in target: ${TARGET_FREE}GB"
if [[ $TARGET_FREE -lt $BINLOG_SIZE ]]; then
  log_error "Insufficient space in $TARGET_BINLOG_DIR"
  log_error "Required: ${BINLOG_SIZE}GB, Available: ${TARGET_FREE}GB"
  trap - ERR INT TERM
  exit 1
fi
log_msg "Sufficient disk space available"

log_msg "Check 9/10: Verifying binary logging is enabled..."
BINLOG_STATUS=$(mysql_cmd -NBe "SELECT @@log_bin" 2>/dev/null || echo "0")
if [[ "$BINLOG_STATUS" != "1" ]]; then
  log_error "Binary logging is not enabled on MySQL server"
  trap - ERR INT TERM
  exit 1
fi
log_msg "Binary logging is enabled"

log_msg "Check 10/10: Verifying binlog files exist..."
BINLOG_PREFIX="$(basename "$BINLOG_BASE")"

# EXACTLY six digits, never "${BINLOG_PREFIX}.*" — that also matches
# binlog.index and binlog.sha256, whose "sequence number" parses as a string
# that bash evaluates as a variable name inside $(( )) and aborts under set -u.
BINLOG_GLOB="${BINLOG_PREFIX}.[0-9][0-9][0-9][0-9][0-9][0-9]"

BINLOG_COUNT=$(find "$BINLOG_DIR" -maxdepth 1 -name "$BINLOG_GLOB" -type f 2>/dev/null | wc -l)

if [[ $BINLOG_COUNT -eq 0 ]]; then
  log_error "No binlog files found in $BINLOG_DIR"
  trap - ERR INT TERM
  exit 1
fi

log_msg "Found $BINLOG_COUNT binlog file(s)"

log_msg "===================================================="
log_msg "All pre-flight checks passed successfully"
log_msg "===================================================="

############################
# LOG START
############################

{
  echo ""
  echo "===================================================="
  echo "BINLOG COLLECTION STARTED"
  echo "Start time         : $START_TIME"
  echo "Reference backup   : $REFERENCE_DATE"
  echo "Binlog directory   : $BINLOG_DIR"
  echo "Target directory   : $TARGET_BINLOG_DIR"
  echo "Binlog info file   : $BINLOG_INFO_FILE"
  echo "Total binlogs      : $BINLOG_COUNT"
  echo "===================================================="
  echo ""
} | tee -a "$RUN_LOG"

############################
# DETERMINE START BINLOG
############################

log_msg "Determining binlog start point..."

if [[ -f "$STATE_FILE" ]]; then
  START_BINLOG="$(cat "$STATE_FILE")"

  if [[ -z "$START_BINLOG" ]]; then
    log_warn "State file is empty, using binlog info from backup"
    START_BINLOG="$(awk '{print $1}' "$BINLOG_INFO_FILE")"
  else
    log_msg "Resuming from last copied binlog: $START_BINLOG"
  fi
else
  START_BINLOG="$(awk '{print $1}' "$BINLOG_INFO_FILE")"
  log_msg "No state file found. Starting from backup binlog position: $START_BINLOG"
fi

if ! is_binlog_file "$START_BINLOG"; then
  log_error "Invalid start binlog format: $START_BINLOG"
  trap - ERR INT TERM
  exit 1
fi

log_msg "Start binlog validated: $START_BINLOG"

############################
# PURGED BINLOG FALLBACK
# Start binlog gone from disk: fall back to the earliest available rather than
# abort. Partial coverage beats none, but the gap is real — hence CRITICAL.
############################

BINLOG_PREFIX="$(basename "$BINLOG_BASE")"

if [[ ! -f "$BINLOG_DIR/$START_BINLOG" ]]; then
  log_warn "CRITICAL: Start binlog not found on disk — may have been purged by MySQL: $START_BINLOG"
  log_warn "CRITICAL: Recommendation — set binlog_expire_logs_seconds >= 3x your backup duration in MySQL config"

  EARLIEST_BINLOG=$(find "$BINLOG_DIR" -maxdepth 1 -name "$BINLOG_GLOB" -type f 2>/dev/null | sort | head -1 | xargs basename 2>/dev/null || echo "")

  if [[ -z "$EARLIEST_BINLOG" ]]; then
    log_error "No binlog files found on disk at all. Cannot proceed."
    trap - ERR INT TERM
    exit 1
  fi

  log_warn "CRITICAL: Falling back to earliest available binlog: $EARLIEST_BINLOG"
  log_warn "CRITICAL: Coverage gap exists between $START_BINLOG and $EARLIEST_BINLOG — point-in-time recovery in this range is NOT possible"
  START_BINLOG="$EARLIEST_BINLOG"
fi

############################
# FLUSH BINLOGS
############################

log_msg "Flushing binary logs to ensure current binlog is rotated and safe to skip..."

# Rotate, so the binlog that was active becomes closed and safe to copy.
if ! mysql_cmd -e "FLUSH BINARY LOGS;" 2>>"$ERROR_LOG"; then
  log_error "Failed to flush binary logs"
  trap - ERR INT TERM
  exit 1
fi

sync
sleep 2

log_msg "Binary logs flushed successfully"

############################
# GET CURRENT ACTIVE BINLOG
############################

log_msg "Determining current active binlog..."

CURRENT_BINLOG="$(get_current_binlog)"

if [[ -z "$CURRENT_BINLOG" ]]; then
  log_error "Unable to determine current binlog"
    log_error "MySQL may not have binary logging properly configured"
  trap - ERR INT TERM
  exit 1
fi

if ! is_binlog_file "$CURRENT_BINLOG"; then
  log_error "Invalid current binlog format: $CURRENT_BINLOG"
  trap - ERR INT TERM
  exit 1
fi

log_msg "Current active binlog (will be skipped): $CURRENT_BINLOG"

############################
# COLLECT BINLOGS
############################

log_msg "Starting binlog collection..."

# Tracked so cleanup_on_error can remove a half-written copy.
CURRENT_COPYING_FILE=""

shopt -s nullglob

mapfile -t BINLOG_FILES < <(
  for f in "$BINLOG_DIR/${BINLOG_PREFIX}."*; do
    basename "$f"
  done | sort
)

shopt -u nullglob

if [[ ${#BINLOG_FILES[@]} -eq 0 ]]; then
  log_error "No binlog files found to process"
  trap - ERR INT TERM
  exit 1
fi

log_msg "Found ${#BINLOG_FILES[@]} binlog files to process"

for BINLOG_FILE in "${BINLOG_FILES[@]}"; do
  BINLOG_PATH="$BINLOG_DIR/$BINLOG_FILE"

  if ! is_binlog_file "$BINLOG_FILE"; then
    continue
  fi

  if [[ "$BINLOG_FILE" == "$START_BINLOG" ]]; then
    FOUND_START=true
    log_msg "Found start binlog: $BINLOG_FILE"
  fi

  if [[ "$FOUND_START" != true ]]; then
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    continue
  fi

  # The active binlog is still being written to.
  if [[ "$BINLOG_FILE" == "$CURRENT_BINLOG" ]]; then
    log_msg "Skipping active binlog: $BINLOG_FILE"
    continue
  fi

  if [[ -f "$TARGET_BINLOG_DIR/$BINLOG_FILE" ]]; then
    log_msg "Already exists, skipping: $BINLOG_FILE"
    continue
  fi

  if [[ ! -f "$BINLOG_PATH" ]]; then
    log_warn "Source file disappeared: $BINLOG_FILE"
    ERROR_COUNT=$((ERROR_COUNT + 1))
    continue
  fi

  if [[ ! -r "$BINLOG_PATH" ]]; then
    log_error "Source file not readable: $BINLOG_FILE"
    ERROR_COUNT=$((ERROR_COUNT + 1))
    continue
  fi

  SOURCE_SIZE=$(stat -c%s "$BINLOG_PATH" 2>/dev/null || echo "0")

  if [[ "$SOURCE_SIZE" -eq 0 ]]; then
    log_warn "Source file is empty, skipping: $BINLOG_FILE"
    continue
  fi

  log_msg "Copying binlog: $BINLOG_FILE ($(format_size "$SOURCE_SIZE"))"

  CURRENT_COPYING_FILE="$BINLOG_FILE"

  # `cp` without -p: CIFS cannot preserve ownership, so -p returns non-zero on
  # copies whose DATA landed fine — good binlogs would count as errors. The
  # size and parse checks below are the real integrity guarantee.
  if ! cp "$BINLOG_PATH" "$TARGET_BINLOG_DIR/" 2>>"$ERROR_LOG"; then
    log_error "Failed to copy $BINLOG_FILE"
    rm -f "$TARGET_BINLOG_DIR/$BINLOG_FILE" 2>/dev/null || true
    CURRENT_COPYING_FILE=""
    ERROR_COUNT=$((ERROR_COUNT + 1))
    continue
  fi

  if [[ ! -f "$TARGET_BINLOG_DIR/$BINLOG_FILE" ]]; then
    log_error "Copied file not found after copy: $BINLOG_FILE"
    CURRENT_COPYING_FILE=""
    ERROR_COUNT=$((ERROR_COUNT + 1))
    continue
  fi

  DEST_SIZE=$(stat -c%s "$TARGET_BINLOG_DIR/$BINLOG_FILE" 2>/dev/null || echo "0")

  if [[ "$SOURCE_SIZE" -ne "$DEST_SIZE" ]]; then
    log_error "Size mismatch for $BINLOG_FILE (source: $SOURCE_SIZE, dest: $DEST_SIZE)"
    rm -f "$TARGET_BINLOG_DIR/$BINLOG_FILE"
    CURRENT_COPYING_FILE=""
    ERROR_COUNT=$((ERROR_COUNT + 1))
    continue
  fi

  # A matching size proves the COPY completed, not that the SOURCE was intact:
  # a truncated binlog copies perfectly and fails during recovery. Parsed
  # against the DESTINATION, so this covers both a corrupt original and a copy
  # mangled in transit.
  if ! "$MYSQLBINLOG_BIN" "$TARGET_BINLOG_DIR/$BINLOG_FILE" >/dev/null 2>>"$ERROR_LOG"; then
    log_error "Binlog failed to parse (truncated or corrupt): $BINLOG_FILE"
    log_error "Removing it rather than archiving a binlog that cannot be replayed."
    rm -f "$TARGET_BINLOG_DIR/$BINLOG_FILE" 2>/dev/null || true
    CURRENT_COPYING_FILE=""
    ERROR_COUNT=$((ERROR_COUNT + 1))
    continue
  fi

  # apply_binlog.sh re-verifies against this after staging the binlogs back to
  # local disk — the only way to catch one that rotted on the share in between.
  # Bare filenames, so verification works from the staging directory later.
  if ! (cd "$TARGET_BINLOG_DIR" && sha256sum "$BINLOG_FILE" >> "binlog.sha256") 2>>"$ERROR_LOG"; then
    log_error "Failed to record checksum for $BINLOG_FILE"
    rm -f "$TARGET_BINLOG_DIR/$BINLOG_FILE" 2>/dev/null || true
    CURRENT_COPYING_FILE=""
    ERROR_COUNT=$((ERROR_COUNT + 1))
    continue
  fi

  CURRENT_COPYING_FILE=""

  # Resume point advances only after a fully validated copy.
  echo "$BINLOG_FILE" > "$STATE_FILE"
  COPIED_COUNT=$((COPIED_COUNT + 1))

  log_msg "Successfully copied and validated: $BINLOG_FILE"
done

############################
# VALIDATION
############################

log_msg "Validating binlog collection results..."

if [[ "$FOUND_START" != true ]]; then
  log_error "Start binlog not found in file list: $START_BINLOG"
  log_error "This should not happen after the purge fallback — investigate manually"
  trap - ERR INT TERM
  exit 1
fi

############################
# SEQUENCE CONTINUITY
# Replay does NOT error on a gap — it applies what is there and carries on,
# losing every transaction in the hole. Caught here, while the missing file may
# still be sitting on the source server.
############################

log_msg "Checking binlog sequence continuity in: $TARGET_BINLOG_DIR"

GAP_FOUND=false
PREV_SEQ=""

while read -r f; do
  # Strip leading zeros: bash arithmetic reads 000042 as OCTAL, and 000008 is
  # an invalid octal literal outright. Empty after stripping means 000000.
  SEQ="$(basename "$f" | awk -F. '{print $NF}' | sed 's/^0*//')"
  SEQ="${SEQ:-0}"

  if [[ -n "$PREV_SEQ" && $((PREV_SEQ + 1)) -ne $SEQ ]]; then
    log_error "SEQUENCE GAP: binlog $PREV_SEQ is followed by $SEQ (missing $((PREV_SEQ + 1)))"
    GAP_FOUND=true
  fi
  PREV_SEQ="$SEQ"
done < <(find "$TARGET_BINLOG_DIR" -maxdepth 1 -type f -name "$BINLOG_GLOB" 2>/dev/null | sort)

if [[ "$GAP_FOUND" == true ]]; then
  log_error "Point-in-time recovery across the gap(s) above is NOT possible."
  log_error "A gap usually means MySQL purged a binlog before it was collected."
  log_error "Prevent it: raise binlog_expire_logs_seconds to >= 3x your backup duration."
  ERROR_COUNT=$((ERROR_COUNT + 1))
else
  log_msg "Binlog sequence is continuous — no gaps detected"
fi

if [[ $ERROR_COUNT -gt 0 ]]; then
  log_warn "Encountered $ERROR_COUNT error(s) during collection"
fi

log_msg "Validation completed"

############################
# SUMMARY
############################

TOTAL_BINLOGS=$(find "$TARGET_BINLOG_DIR" -maxdepth 1 -type f -name "$BINLOG_GLOB" 2>/dev/null | wc -l)
TOTAL_SIZE=$(du -sh "$TARGET_BINLOG_DIR" 2>/dev/null | awk '{print $1}')

END_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
END_EPOCH="$(date +%s)"
DURATION=$((END_EPOCH - START_EPOCH))
DURATION_MIN=$((DURATION / 60))
DURATION_SEC=$((DURATION % 60))

{
  echo ""
  echo "===================================================="
  echo "BINLOG COLLECTION COMPLETED"
  echo "===================================================="
  echo "Start time         : $START_TIME"
  echo "End time           : $END_TIME"
  echo "Duration           : ${DURATION_MIN}m ${DURATION_SEC}s"
  echo "Reference backup   : $REFERENCE_DATE"
  echo "Start binlog       : $START_BINLOG"
  echo "Current binlog     : $CURRENT_BINLOG"
  echo "Binlogs processed  : ${#BINLOG_FILES[@]}"
  echo "Binlogs skipped    : $SKIPPED_COUNT"
  echo "Binlogs copied     : $COPIED_COUNT"
  echo "Errors encountered : $ERROR_COUNT"
  echo "Total in archive   : $TOTAL_BINLOGS"
  echo "Archive size       : $TOTAL_SIZE"
  echo "Target directory   : $TARGET_BINLOG_DIR"
  echo "===================================================="
  echo "Log files:"
  echo "  Main log         : $RUN_LOG"
  echo "  Error log        : $ERROR_LOG"
  echo "===================================================="
} | tee -a "$RUN_LOG"

# From here the exit code is decided deliberately, not by the trap.
trap - ERR INT TERM

############################
# EXIT CODE
# Any error means the PITR chain is not intact, so the run must exit non-zero —
# a monitored job that cannot fail is worse than no monitoring.
#
# This is a partial-success exit: validated binlogs stay archived and the state
# file still points at the last good one, so the next run resumes correctly.
############################

if [[ $ERROR_COUNT -gt 0 ]]; then
  log_error "===================================================="
  log_error "Collection finished with $ERROR_COUNT error(s)."
  log_error "The PITR chain is NOT intact. Investigate before relying on it."
  log_error "Error log: $ERROR_LOG"
  log_error "===================================================="
  exit 1
fi

exit 0
