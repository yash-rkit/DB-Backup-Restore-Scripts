#!/usr/bin/env bash
set -euo pipefail

############################
# CONFIGURATION
############################

# MySQL credentials (source server credentials, same as restore_full.sh)
SOURCE_MYSQL_USER="Admin"
SOURCE_MYSQL_PASSWORD=""

# Archive directory (where _binlog_info and _restored_at marker files live)
ARCHIVE_DIR="/home/miracle/binlogdata"

# Backup base directory (where binlog subdirectories live)
BACKUP_BASE="/home/miracle/binlogdata"

# Binary paths
MYSQLBINLOG_BIN="/usr/bin/mysqlbinlog"
MYSQL_BIN="/usr/bin/mysql"

# Position 4 = start of first real event in a binlog file (past the 4-byte magic header).
# Used when --from is provided and points to a file DIFFERENT from the binlog_info file.
BINLOG_FILE_START_POS=4

############################
# EARLY INITIALIZATION
############################

RUN_LOG=""
ERROR_LOG=""
BACKUP_DATE=""
OVERRIDE_START_BINLOG=""
START_BINLOG=""
START_POS=""
APPLIED_COUNT=0
BINLOG_ERRORS=0
DB_COUNT=0

############################
# HELPER FUNCTIONS
############################

log_msg() {
  if [[ -n "$RUN_LOG" && -f "$RUN_LOG" ]]; then
    echo "[$(date '+%F %T')] [INFO] $1" | tee -a "$RUN_LOG"
  else
    echo "[$(date '+%F %T')] [INFO] $1"
  fi
}

log_error() {
  if [[ -n "$RUN_LOG" && -f "$RUN_LOG" ]]; then
    echo "[$(date '+%F %T')] [ERROR] $1" | tee -a "$RUN_LOG" >&2
  else
    echo "[$(date '+%F %T')] [ERROR] $1" >&2
  fi
  if [[ -n "$ERROR_LOG" && -f "$ERROR_LOG" ]]; then
    echo "[$(date '+%F %T')] [ERROR] $1" >> "$ERROR_LOG"
  fi
}

log_warn() {
  if [[ -n "$RUN_LOG" && -f "$RUN_LOG" ]]; then
    echo "[$(date '+%F %T')] [WARN] $1" | tee -a "$RUN_LOG"
  else
    echo "[$(date '+%F %T')] [WARN] $1"
  fi
}

cleanup_on_error() {
  log_error "Binlog apply failed."
  log_error "MySQL is still running. No data directory changes were made by this script."
  log_error "Check logs: ${RUN_LOG:-'(not initialized)'}"
  trap - ERR INT TERM
  exit 1
}

trap cleanup_on_error ERR INT TERM

mysql_cmd() {
  "$MYSQL_BIN" -u"${SOURCE_MYSQL_USER}" -p"${SOURCE_MYSQL_PASSWORD}" "$@"
}

test_mysql_connection() {
  if ! mysql_cmd -e "SELECT 1" >/dev/null 2>&1; then
    return 1
  fi
  return 0
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

# Validate binlog filename format (binlog.NNNNNN)
is_valid_binlog_name() {
  local name="$1"
  if [[ "$name" =~ ^binlog\.[0-9]{6}$ ]]; then
    return 0
  fi
  return 1
}

show_usage() {
  echo "Usage: $0 <backup_date_YYYYMMDD> [--from <binlog_filename>]"
  echo ""
  echo "  Applies collected binlogs for the given backup date."
  echo "  MySQL must already be running (run restore_full.sh first)."
  echo ""
  echo "Arguments:"
  echo "  backup_date_YYYYMMDD  :  Date of the backup (required)"
  echo "  --from <filename>     :  Start applying from this binlog file (optional)"
  echo "                           If omitted, starts from position in _binlog_info file"
  echo ""
  echo "Examples:"
  echo "  $0 20260420                              # apply all binlogs from backup position"
  echo "  $0 20260420 --from binlog.000123         # apply from binlog.000123 onwards"
  echo ""
  echo "Notes:"
  echo "  - Without --from: uses exact file + position from _binlog_info (safe, no gaps/duplicates)"
  echo "  - With --from (different file): starts from position 4 of that file (full file applied)"
  echo "  - With --from (same file as binlog_info): uses position from binlog_info automatically"
  trap - ERR INT TERM
  exit 1
}

############################
# INPUT PARSING
############################

if [[ $# -lt 1 ]]; then
  show_usage
fi

BACKUP_DATE="$1"
shift

# Parse optional --from flag
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)
      if [[ $# -lt 2 ]]; then
        echo "[$(date '+%F %T')] [ERROR] --from requires a binlog filename argument" >&2
        trap - ERR INT TERM
        exit 1
      fi
      OVERRIDE_START_BINLOG="$2"
      shift 2
      ;;
    *)
      echo "[$(date '+%F %T')] [ERROR] Unknown argument: $1" >&2
      show_usage
      ;;
  esac
done

# Validate date format
if ! [[ "$BACKUP_DATE" =~ ^[0-9]{8}$ ]]; then
  echo "[$(date '+%F %T')] [ERROR] Invalid date format. Expected YYYYMMDD, got: $BACKUP_DATE" >&2
  trap - ERR INT TERM
  exit 1
fi

# Validate --from value if provided
if [[ -n "$OVERRIDE_START_BINLOG" ]]; then
  if ! is_valid_binlog_name "$OVERRIDE_START_BINLOG"; then
    echo "[$(date '+%F %T')] [ERROR] Invalid binlog filename: $OVERRIDE_START_BINLOG" >&2
    echo "[$(date '+%F %T')] [ERROR] Expected format: binlog.NNNNNN (e.g. binlog.000123)" >&2
    trap - ERR INT TERM
    exit 1
  fi
fi

############################
# DERIVED PATHS
############################

BINLOG_INFO_FILE="${ARCHIVE_DIR}/${BACKUP_DATE}_binlog_info"
BINLOG_DIR="${BACKUP_BASE}/binlog/${BACKUP_DATE}"
RESTORE_MARKER="${ARCHIVE_DIR}/${BACKUP_DATE}_restored_at"
RUN_LOG="${BACKUP_BASE}/${BACKUP_DATE}_binlog_apply.log"
ERROR_LOG="${BACKUP_BASE}/${BACKUP_DATE}_binlog_apply_errors.log"

START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
START_EPOCH="$(date +%s)"

############################
# INITIALIZE LOGS
############################

if [[ ! -d "$BACKUP_BASE" ]]; then
  if ! mkdir -p "$BACKUP_BASE" 2>/dev/null; then
    echo "[$(date '+%F %T')] [ERROR] Failed to create backup base directory: $BACKUP_BASE" >&2
    trap - ERR INT TERM
    exit 1
  fi
fi

cat > "$RUN_LOG" << EOF
========================================
BINLOG APPLY LOG
========================================
Backup Date    : $BACKUP_DATE
Override From  : ${OVERRIDE_START_BINLOG:-(none, using binlog_info)}
Started        : $(date '+%F %T')
========================================

EOF

cat > "$ERROR_LOG" << EOF
========================================
BINLOG APPLY ERROR LOG
========================================
Backup Date    : $BACKUP_DATE
Override From  : ${OVERRIDE_START_BINLOG:-(none, using binlog_info)}
Started        : $(date '+%F %T')
========================================

EOF

############################
# PRE-FLIGHT CHECKS
############################

log_msg "===================================================="
log_msg "Starting pre-flight checks..."
log_msg "===================================================="

# Check 1: Root
log_msg "Check 1/9: Verifying user privileges..."
if [[ $EUID -ne 0 ]]; then
  log_error "This script must be run as root"
  trap - ERR INT TERM
  exit 1
fi
log_msg "Running as root"

# Check 2: Required binaries
log_msg "Check 2/9: Verifying required binaries..."
REQUIRED_COMMANDS=(awk find sort wc basename)
for cmd in "${REQUIRED_COMMANDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "Required command not found: $cmd"
    trap - ERR INT TERM
    exit 1
  fi
done
if [[ ! -x "$MYSQL_BIN" ]]; then
  log_error "MySQL binary not found or not executable: $MYSQL_BIN"
  trap - ERR INT TERM
  exit 1
fi
if [[ ! -x "$MYSQLBINLOG_BIN" ]]; then
  log_error "mysqlbinlog binary not found or not executable: $MYSQLBINLOG_BIN"
  trap - ERR INT TERM
  exit 1
fi
log_msg "All required binaries found"

# Check 3: Restore marker
log_msg "Check 3/9: Verifying full restore was completed..."
if [[ ! -f "$RESTORE_MARKER" ]]; then
  log_warn "Restore marker not found: $RESTORE_MARKER"
  log_warn "This means restore_full.sh may not have been run for this backup date."
  log_warn "Applying binlogs to a non-restored database WILL cause data corruption."
  log_warn "Aborting for safety. Run restore_full.sh $BACKUP_DATE first."
  trap - ERR INT TERM
  exit 1
fi
RESTORED_AT=$(cat "$RESTORE_MARKER")
log_msg "Restore marker found - full restore was completed at: $RESTORED_AT"

# Check 4: binlog_info file
log_msg "Check 4/9: Verifying binlog info file..."
if [[ ! -f "$BINLOG_INFO_FILE" ]]; then
  log_error "Binlog info file not found: $BINLOG_INFO_FILE"
  trap - ERR INT TERM
  exit 1
fi
if [[ ! -s "$BINLOG_INFO_FILE" ]]; then
  log_error "Binlog info file is empty: $BINLOG_INFO_FILE"
  trap - ERR INT TERM
  exit 1
fi

INFO_BINLOG="$(awk '{print $1}' "$BINLOG_INFO_FILE")"
INFO_POS="$(awk '{print $2}' "$BINLOG_INFO_FILE")"

if [[ -z "$INFO_BINLOG" || -z "$INFO_POS" ]]; then
  log_error "Invalid binlog info format in: $BINLOG_INFO_FILE"
  trap - ERR INT TERM
  exit 1
fi
log_msg "Binlog info: file=$INFO_BINLOG, position=$INFO_POS"

# Check 5: Binlog directory exists and has files
log_msg "Check 5/9: Verifying binlog directory..."
if [[ ! -d "$BINLOG_DIR" ]]; then
  log_error "Binlog directory not found: $BINLOG_DIR"
  log_error "Run binlog_collect.sh to collect binlogs before applying"
  trap - ERR INT TERM
  exit 1
fi
BINLOG_COUNT=$(find "$BINLOG_DIR" -maxdepth 1 -type f -name "binlog.*" 2>/dev/null | wc -l)
if [[ $BINLOG_COUNT -eq 0 ]]; then
  log_error "No binlog files found in: $BINLOG_DIR"
  trap - ERR INT TERM
  exit 1
fi
log_msg "Found $BINLOG_COUNT binlog file(s) in: $BINLOG_DIR"

# Check 6: Validate --from file exists in binlog dir (if provided)
if [[ -n "$OVERRIDE_START_BINLOG" ]]; then
  log_msg "Check 6/9: Verifying --from file exists in binlog directory..."
  if [[ ! -f "$BINLOG_DIR/$OVERRIDE_START_BINLOG" ]]; then
    log_error "--from file not found in binlog directory: $BINLOG_DIR/$OVERRIDE_START_BINLOG"
    log_error "Available binlog files:"
    find "$BINLOG_DIR" -maxdepth 1 -type f -name "binlog.*" | sort | while read -r f; do
      log_error "  $(basename "$f")"
    done
    trap - ERR INT TERM
    exit 1
  fi
  log_msg "--from file verified: $OVERRIDE_START_BINLOG"
else
  log_msg "Check 6/9: No --from override provided (skipped)"
fi

# Check 7: MySQL is running
log_msg "Check 7/9: Verifying MySQL is running..."
if ! is_mysql_running; then
  log_error "MySQL is not running. Run restore_full.sh $BACKUP_DATE first."
  trap - ERR INT TERM
  exit 1
fi
log_msg "MySQL is running"

# Check 8: MySQL connection works
log_msg "Check 8/9: Verifying MySQL connection..."
if ! test_mysql_connection; then
  log_error "Cannot connect to MySQL. Check credentials in script configuration."
  trap - ERR INT TERM
  exit 1
fi
log_msg "MySQL connection successful"

# Check 9: No concurrent apply running
log_msg "Check 9/9: Checking for concurrent apply operations..."
SCRIPT_NAME=$(basename "$0")
RUNNING_COUNT=$(pgrep -f "$SCRIPT_NAME" | wc -l)
if [[ $RUNNING_COUNT -gt 2 ]]; then
  log_error "Another binlog apply process is already running. Aborting."
  trap - ERR INT TERM
  exit 1
fi
log_msg "No concurrent apply detected"

log_msg "===================================================="
log_msg "All pre-flight checks passed"
log_msg "===================================================="

############################
# RESOLVE START BINLOG AND POSITION
#
# Three cases:
#
# Case 1: No --from flag
#   START_BINLOG = INFO_BINLOG (from binlog_info)
#   START_POS    = INFO_POS    (exact position from XtraBackup)
#   Reason: safest - no gaps, no duplicate transactions.
#
# Case 2: --from provided, DIFFERENT file from binlog_info
#   START_BINLOG = OVERRIDE_START_BINLOG
#   START_POS    = 4 (start of first real event in file)
#   Reason: user wants to start from a later file, apply entire file.
#
# Case 3: --from provided, SAME file as binlog_info  <-- EDGE CASE
#   START_BINLOG = OVERRIDE_START_BINLOG (same as INFO_BINLOG)
#   START_POS    = INFO_POS (use binlog_info position, NOT 4)
#   Reason: if we used position 4, transactions already in the full backup
#   would be re-applied, causing duplicate data or errors.
#   We detect this automatically and use the safe position.
############################

log_msg "===================================================="
log_msg "Resolving start position..."
log_msg "===================================================="

if [[ -z "$OVERRIDE_START_BINLOG" ]]; then
  # Case 1: No --from flag
  START_BINLOG="$INFO_BINLOG"
  START_POS="$INFO_POS"
  log_msg "Mode             : Default (from binlog_info)"
  log_msg "Start binlog     : $START_BINLOG"
  log_msg "Start position   : $START_POS"

elif [[ "$OVERRIDE_START_BINLOG" != "$INFO_BINLOG" ]]; then
  # Case 2: --from points to a DIFFERENT file
  START_BINLOG="$OVERRIDE_START_BINLOG"
  START_POS="$BINLOG_FILE_START_POS"
  log_msg "Mode             : Override (--from, different file)"
  log_msg "Start binlog     : $START_BINLOG"
  log_msg "Start position   : $START_POS (position 4 = full file)"
  log_msg "binlog_info file : $INFO_BINLOG (at position $INFO_POS)"

else
  # Case 3: EDGE CASE - --from points to the SAME file as binlog_info
  START_BINLOG="$OVERRIDE_START_BINLOG"
  START_POS="$INFO_POS"
  log_warn "===================================================="
  log_warn "EDGE CASE DETECTED"
  log_warn "===================================================="
  log_warn "--from file ($OVERRIDE_START_BINLOG) is the SAME file recorded in binlog_info."
  log_warn "The full backup captured data up to position $INFO_POS in this file."
  log_warn "Applying from position 4 (full file) would re-apply already-included transactions."
  log_warn "Automatically using position $INFO_POS from binlog_info to prevent duplicate data."
  log_warn "===================================================="
  log_msg "Mode             : Override (--from, same file as binlog_info - edge case handled)"
  log_msg "Start binlog     : $START_BINLOG"
  log_msg "Start position   : $START_POS (from binlog_info, not position 4)"
fi

############################
# LOG START
############################

{
  echo ""
  echo "===================================================="
  echo "BINLOG APPLY STARTED"
  echo "===================================================="
  echo "Start time       : $START_TIME"
  echo "Backup date      : $BACKUP_DATE"
  echo "Binlog directory : $BINLOG_DIR"
  echo "binlog_info file : $INFO_BINLOG at position $INFO_POS"
  echo "Start binlog     : $START_BINLOG"
  echo "Start position   : $START_POS"
  echo "Override --from  : ${OVERRIDE_START_BINLOG:-(none)}"
  echo "Total binlogs    : $BINLOG_COUNT"
  echo "===================================================="
  echo ""
} | tee -a "$RUN_LOG"

############################
# APPLY BINLOGS
############################

log_msg "Collecting and sorting binlog files..."

shopt -s nullglob
mapfile -t BINLOG_FILES < <(
  for f in "$BINLOG_DIR"/binlog.*; do
    basename "$f"
  done | sort
)
shopt -u nullglob

if [[ ${#BINLOG_FILES[@]} -eq 0 ]]; then
  log_error "No binlog files found to process"
  trap - ERR INT TERM
  exit 1
fi

log_msg "Processing ${#BINLOG_FILES[@]} binlog file(s)..."

APPLY_STARTED=false
SKIPPED_BEFORE_START=0

for BINLOG_FILE in "${BINLOG_FILES[@]}"; do
  BINLOG_PATH="$BINLOG_DIR/$BINLOG_FILE"

  # Skip non-binlog files (state files, logs etc)
  if ! is_valid_binlog_name "$BINLOG_FILE"; then
    log_msg "Skipping non-binlog file: $BINLOG_FILE"
    continue
  fi

  # Skip files before start binlog
  if [[ "$APPLY_STARTED" != true && "$BINLOG_FILE" != "$START_BINLOG" ]]; then
    log_msg "Skipping (before start): $BINLOG_FILE"
    SKIPPED_BEFORE_START=$((SKIPPED_BEFORE_START + 1))
    continue
  fi

  # Found start binlog
  if [[ "$BINLOG_FILE" == "$START_BINLOG" ]]; then
    APPLY_STARTED=true
    log_msg "----------------------------------------------------"
    log_msg "Applying: $BINLOG_FILE (from position $START_POS)"
    log_msg "----------------------------------------------------"

    if ! "$MYSQLBINLOG_BIN" \
      --skip-gtids \
      --disable-log-bin \
      --start-position="$START_POS" \
      "$BINLOG_PATH" 2>>"$ERROR_LOG" \
      | mysql_cmd 2>>"$ERROR_LOG"; then
      log_error "Failed to apply $BINLOG_FILE from position $START_POS"
      BINLOG_ERRORS=$((BINLOG_ERRORS + 1))
    else
      APPLIED_COUNT=$((APPLIED_COUNT + 1))
      log_msg "Applied: $BINLOG_FILE"
    fi
    continue
  fi

  # Apply all subsequent binlog files fully (no position offset)
  if [[ "$APPLY_STARTED" == true ]]; then
    log_msg "----------------------------------------------------"
    log_msg "Applying: $BINLOG_FILE (full file)"
    log_msg "----------------------------------------------------"

    if ! "$MYSQLBINLOG_BIN" \
      --skip-gtids \
      --disable-log-bin \
      "$BINLOG_PATH" 2>>"$ERROR_LOG" \
      | mysql_cmd 2>>"$ERROR_LOG"; then
      log_error "Failed to apply $BINLOG_FILE"
      BINLOG_ERRORS=$((BINLOG_ERRORS + 1))
    else
      APPLIED_COUNT=$((APPLIED_COUNT + 1))
      log_msg "Applied: $BINLOG_FILE"
    fi
  fi
done

############################
# POST-APPLY VALIDATION
############################

if [[ "$APPLY_STARTED" != true ]]; then
  log_error "Start binlog '$START_BINLOG' was not found in: $BINLOG_DIR"
  log_error "Available files:"
  for f in "${BINLOG_FILES[@]}"; do
    log_error "  $f"
  done
  trap - ERR INT TERM
  exit 1
fi

if [[ $BINLOG_ERRORS -gt 0 ]]; then
  log_warn "$BINLOG_ERRORS binlog file(s) failed to apply. Check: $ERROR_LOG"
fi

log_msg "Verifying MySQL is still running after apply..."
if ! is_mysql_running; then
  log_error "MySQL is not running after binlog apply"
  trap - ERR INT TERM
  exit 1
fi

if ! test_mysql_connection; then
  log_error "Cannot connect to MySQL after binlog apply"
  trap - ERR INT TERM
  exit 1
fi

DB_COUNT=$(mysql_cmd -NBe "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema','mysql','performance_schema','sys')" 2>>"$ERROR_LOG" || echo "0")

############################
# COMPLETE
############################

END_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
END_EPOCH="$(date +%s)"
DURATION=$((END_EPOCH - START_EPOCH))
DURATION_MIN=$((DURATION / 60))
DURATION_SEC=$((DURATION % 60))

{
  echo ""
  echo "===================================================="
  echo "BINLOG APPLY COMPLETED"
  echo "===================================================="
  echo "Start time        : $START_TIME"
  echo "End time          : $END_TIME"
  echo "Duration          : ${DURATION_MIN}m ${DURATION_SEC}s"
  echo "Backup date       : $BACKUP_DATE"
  echo "Binlog directory  : $BINLOG_DIR"
  echo "Start binlog      : $START_BINLOG"
  echo "Start position    : $START_POS"
  echo "Override --from   : ${OVERRIDE_START_BINLOG:-(none)}"
  echo "Files skipped     : $SKIPPED_BEFORE_START"
  echo "Files applied     : $APPLIED_COUNT"
  echo "Apply errors      : $BINLOG_ERRORS"
  echo "User databases    : $DB_COUNT"
  echo "===================================================="
  echo "Log files:"
  echo "  Main log        : $RUN_LOG"
  echo "  Error log       : $ERROR_LOG"
  echo "===================================================="
} | tee -a "$RUN_LOG"

trap - ERR INT TERM
exit 0