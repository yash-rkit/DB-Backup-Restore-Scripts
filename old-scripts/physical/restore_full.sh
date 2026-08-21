#!/usr/bin/env bash
set -euo pipefail

############################
# CONFIGURATION
############################

# MySQL credentials for CURRENT server (before restore)
MYSQL_USER="Admin"
MYSQL_PASSWORD=""

# MySQL credentials from SOURCE server (after restore)
SOURCE_MYSQL_USER="Admin"
SOURCE_MYSQL_PASSWORD=""

# Backup base directory
BACKUP_BASE="/home/miracle/binlogdata"

# Archive directory (where .tar.gz, .sha256, _binlog_info files live)
ARCHIVE_DIR="/home/miracle/binlogdata"

# MySQL data directory
MYSQL_DATADIR="/Data/mysql"

# Binary paths
XTRABACKUP_BIN="/usr/bin/xtrabackup"
MYSQL_BIN="/usr/bin/mysql"

############################
# EARLY INITIALIZATION
############################

RUN_LOG=""
ERROR_LOG=""
BACKUP_DATE=""
COMPRESSED_BACKUP=""
CHECKSUM_FILE=""
BACKUP_SIZE="N/A"
BACKUP_SHA256="N/A"
MYSQL_WAS_RUNNING=false

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
  log_error "Full restore failed. Cleaning up..."

  # Attempt to restart MySQL if it was running before and is now stopped
  if [[ "$MYSQL_WAS_RUNNING" == true ]]; then
    if ! is_mysql_running; then
      log_msg "Attempting to restart MySQL..."
      systemctl start mysql 2>/dev/null || true
    fi
  fi

  log_error "Restore aborted. Check logs: ${RUN_LOG:-'(not initialized)'}"
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

get_free_space_gb() {
  local path="$1"
  df -BG "$path" | awk 'NR==2 {print $4}' | sed 's/G//'
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

show_usage() {
  echo "Usage: $0 <backup_date_YYYYMMDD>"
  echo ""
  echo "  Restores the full XtraBackup for the given date."
  echo "  Does NOT apply binlogs. Run apply_binlogs.sh separately for that."
  echo ""
  echo "Arguments:"
  echo "  backup_date_YYYYMMDD  :  Date of the backup to restore (required)"
  echo ""
  echo "Examples:"
  echo "  $0 20260420"
  trap - ERR INT TERM
  exit 1
}

############################
# INPUT VALIDATION
############################

if [[ $# -ne 1 ]]; then
  show_usage
fi

BACKUP_DATE="$1"

if ! [[ "$BACKUP_DATE" =~ ^[0-9]{8}$ ]]; then
  echo "[$(date '+%F %T')] [ERROR] Invalid date format. Expected YYYYMMDD, got: $BACKUP_DATE" >&2
  trap - ERR INT TERM
  exit 1
fi

############################
# DERIVED PATHS
############################

COMPRESSED_BACKUP="${ARCHIVE_DIR}/${BACKUP_DATE}.tar.gz"
CHECKSUM_FILE="${ARCHIVE_DIR}/${BACKUP_DATE}.sha256"
RESTORE_MARKER="${ARCHIVE_DIR}/${BACKUP_DATE}_restored_at"
RUN_LOG="${BACKUP_BASE}/${BACKUP_DATE}_full_restore.log"
ERROR_LOG="${BACKUP_BASE}/${BACKUP_DATE}_full_restore_errors.log"

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
MYSQL FULL RESTORE LOG
========================================
Backup Date : $BACKUP_DATE
Started     : $(date '+%F %T')
========================================

EOF

cat > "$ERROR_LOG" << EOF
========================================
MYSQL FULL RESTORE ERROR LOG
========================================
Backup Date : $BACKUP_DATE
Started     : $(date '+%F %T')
========================================

EOF

############################
# PRE-FLIGHT CHECKS
############################

log_msg "===================================================="
log_msg "Starting pre-flight checks..."
log_msg "===================================================="

# Check 1: Root
log_msg "Check 1/10: Verifying user privileges..."
if [[ $EUID -ne 0 ]]; then
  log_error "This script must be run as root"
  trap - ERR INT TERM
  exit 1
fi
log_msg "Running as root"

# Check 2: Required binaries
log_msg "Check 2/10: Verifying required binaries..."
REQUIRED_COMMANDS=(tar gzip awk du df stat wc pgrep chown rm sleep basename sha256sum)
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

if ! command -v systemctl >/dev/null 2>&1; then
  log_error "systemctl not found - this script requires systemd"
  trap - ERR INT TERM
  exit 1
fi
log_msg "All required binaries found"

# Check 3: Compressed backup exists
log_msg "Check 3/10: Verifying compressed backup exists..."
if [[ ! -f "$COMPRESSED_BACKUP" ]]; then
  log_error "Backup not found: $COMPRESSED_BACKUP"
  trap - ERR INT TERM
  exit 1
fi
if [[ ! -r "$COMPRESSED_BACKUP" ]]; then
  log_error "Backup file not readable: $COMPRESSED_BACKUP"
  trap - ERR INT TERM
  exit 1
fi
BACKUP_SIZE=$(du -sh "$COMPRESSED_BACKUP" | awk '{print $1}')
log_msg "Backup file found: $COMPRESSED_BACKUP ($BACKUP_SIZE)"

# Check 4: SHA-256 checksum
log_msg "Check 4/10: Verifying SHA-256 checksum..."
if [[ ! -f "$CHECKSUM_FILE" ]]; then
  log_warn "Checksum file not found: $CHECKSUM_FILE"
  log_warn "Skipping checksum verification - backup integrity cannot be guaranteed"
  BACKUP_SHA256="N/A (checksum file missing)"
else
  if [[ ! -s "$CHECKSUM_FILE" ]]; then
    log_error "Checksum file is empty: $CHECKSUM_FILE"
    trap - ERR INT TERM
    exit 1
  fi
  EXPECTED_SHA256=$(awk '{print $1}' "$CHECKSUM_FILE")
  log_msg "Expected SHA-256: $EXPECTED_SHA256"
  log_msg "Calculating SHA-256 of backup file (may take a while for large backups)..."
  ACTUAL_SHA256=$(sha256sum "$COMPRESSED_BACKUP" | awk '{print $1}')
  log_msg "Actual SHA-256:   $ACTUAL_SHA256"
  if [[ "$EXPECTED_SHA256" != "$ACTUAL_SHA256" ]]; then
    log_error "SHA-256 MISMATCH - backup file may be corrupted or tampered with"
    log_error "Expected: $EXPECTED_SHA256"
    log_error "Actual:   $ACTUAL_SHA256"
    trap - ERR INT TERM
    exit 1
  fi
  BACKUP_SHA256="$ACTUAL_SHA256"
  log_msg "SHA-256 checksum verified - backup integrity confirmed"
fi

# Check 5: MySQL data directory
log_msg "Check 5/10: Verifying MySQL data directory..."
if [[ ! -d "$MYSQL_DATADIR" ]]; then
  log_error "MySQL data directory not found: $MYSQL_DATADIR"
  trap - ERR INT TERM
  exit 1
fi
if [[ -z "$MYSQL_DATADIR" || "$MYSQL_DATADIR" == "/" ]]; then
  log_error "Invalid MySQL data directory path: $MYSQL_DATADIR"
  trap - ERR INT TERM
  exit 1
fi
log_msg "MySQL data directory exists: $MYSQL_DATADIR"

# Check 6: Data directory writable
log_msg "Check 6/10: Verifying MySQL data directory parent is writable..."
DATADIR_PARENT="$(dirname "$MYSQL_DATADIR")"
if ! validate_writable "$DATADIR_PARENT"; then
  log_error "MySQL data directory parent is not writable: $DATADIR_PARENT"
  trap - ERR INT TERM
  exit 1
fi
log_msg "Data directory parent is writable"

# Check 7: Disk space
log_msg "Check 7/10: Checking available disk space..."
DATADIR_FREE_SPACE=$(get_free_space_gb "$MYSQL_DATADIR")
COMPRESSED_SIZE_BYTES=$(stat -c%s "$COMPRESSED_BACKUP" 2>/dev/null || echo "0")
COMPRESSED_SIZE_GB=$((COMPRESSED_SIZE_BYTES / 1024 / 1024 / 1024 + 1))
REQUIRED_SPACE=$((COMPRESSED_SIZE_GB * 4))
log_msg "Free space: ${DATADIR_FREE_SPACE}GB, Required (est.): ${REQUIRED_SPACE}GB"
if [[ $DATADIR_FREE_SPACE -lt $REQUIRED_SPACE ]]; then
  log_error "Insufficient disk space. Required: ${REQUIRED_SPACE}GB, Available: ${DATADIR_FREE_SPACE}GB"
  trap - ERR INT TERM
  exit 1
fi
log_msg "Sufficient disk space available"

# Check 8: MySQL status
log_msg "Check 8/10: Verifying MySQL status..."
if is_mysql_running; then
  MYSQL_WAS_RUNNING=true
  log_msg "MySQL is currently running (will be stopped during restore)"
else
  log_msg "MySQL is not currently running"
fi

# Check 9: No concurrent restore
log_msg "Check 9/10: Checking for concurrent restore operations..."
SCRIPT_NAME=$(basename "$0")
RUNNING_COUNT=$(pgrep -f "$SCRIPT_NAME" | wc -l)
if [[ $RUNNING_COUNT -gt 2 ]]; then
  log_error "Another restore process is already running. Aborting."
  trap - ERR INT TERM
  exit 1
fi
log_msg "No concurrent restore detected"

# Check 10: Stale restore marker warning
log_msg "Check 10/10: Checking for existing restore marker..."
if [[ -f "$RESTORE_MARKER" ]]; then
  PREVIOUS_RESTORE=$(cat "$RESTORE_MARKER")
  log_warn "A restore marker already exists for $BACKUP_DATE (restored at: $PREVIOUS_RESTORE)"
  log_warn "This means a full restore for this date was already completed."
  log_warn "Proceeding will overwrite the existing restored state."
  log_warn "If you only need to apply binlogs, run apply_binlogs.sh instead."
  log_warn "Continuing in 10 seconds... Press Ctrl+C to abort."
  sleep 10
  log_msg "Continuing with restore (overwriting previous restore for $BACKUP_DATE)"
else
  log_msg "No previous restore marker found - clean restore"
fi

log_msg "===================================================="
log_msg "All pre-flight checks passed"
log_msg "===================================================="

############################
# LOG START
############################

{
  echo ""
  echo "===================================================="
  echo "FULL RESTORE STARTED"
  echo "===================================================="
  echo "Start time    : $START_TIME"
  echo "Backup date   : $BACKUP_DATE"
  echo "Backup file   : $COMPRESSED_BACKUP"
  echo "Backup size   : $BACKUP_SIZE"
  echo "SHA-256       : $BACKUP_SHA256"
  echo "MySQL datadir : $MYSQL_DATADIR"
  echo "===================================================="
  echo ""
} | tee -a "$RUN_LOG"

############################
# STEP 1: STOP MYSQL
############################

log_msg "[Step 1/4] Stopping MySQL server..."

if is_mysql_running; then
  if ! systemctl stop mysql 2>>"$ERROR_LOG"; then
    log_error "Failed to stop MySQL service"
    trap - ERR INT TERM
    exit 1
  fi
  sleep 3
  if is_mysql_running; then
    log_error "MySQL still running after stop command"
    trap - ERR INT TERM
    exit 1
  fi
  log_msg "MySQL stopped successfully"
else
  log_msg "MySQL was already stopped"
fi

############################
# STEP 2: CLEAR AND RESTORE
############################

log_msg "[Step 2/4] Clearing and restoring data directory..."

if [[ -z "$MYSQL_DATADIR" || "$MYSQL_DATADIR" == "/" ]]; then
  log_error "Safety check failed: Invalid MYSQL_DATADIR: $MYSQL_DATADIR"
  trap - ERR INT TERM
  exit 1
fi

log_msg "Clearing data directory: $MYSQL_DATADIR"
if ! rm -rf "${MYSQL_DATADIR:?}/"* 2>>"$ERROR_LOG"; then
  log_error "Failed to clear data directory"
  trap - ERR INT TERM
  exit 1
fi

if [[ -n "$(ls -A "$MYSQL_DATADIR" 2>/dev/null)" ]]; then
  log_error "Data directory is not empty after cleanup"
  trap - ERR INT TERM
  exit 1
fi
log_msg "Data directory cleared"

log_msg "Extracting backup to data directory..."
if ! tar -xzf "$COMPRESSED_BACKUP" -C "$MYSQL_DATADIR" --strip-components=1 2>>"$ERROR_LOG"; then
  log_error "Failed to extract backup"
  trap - ERR INT TERM
  exit 1
fi

if [[ ! -f "$MYSQL_DATADIR/ibdata1" ]]; then
  log_error "Core InnoDB files not found after extraction. Backup may be corrupt."
  trap - ERR INT TERM
  exit 1
fi
log_msg "Backup extracted successfully"

log_msg "Setting ownership on restored files..."
if ! chown -R mysql:mysql "$MYSQL_DATADIR" 2>>"$ERROR_LOG"; then
  log_error "Failed to set ownership on data directory"
  trap - ERR INT TERM
  exit 1
fi
log_msg "Ownership set"

############################
# STEP 3: POST-RESTORE SHA-256
############################

log_msg "[Step 3/4] Post-restore SHA-256 verification..."

POST_EXTRACT_SHA256=$(sha256sum "$COMPRESSED_BACKUP" | awk '{print $1}')

if [[ "$BACKUP_SHA256" != "N/A" && "$BACKUP_SHA256" != "N/A (checksum file missing)" ]]; then
  if [[ "$POST_EXTRACT_SHA256" != "$BACKUP_SHA256" ]]; then
    log_error "SHA-256 changed during extraction - possible filesystem corruption"
    log_error "Pre-extraction:  $BACKUP_SHA256"
    log_error "Post-extraction: $POST_EXTRACT_SHA256"
    trap - ERR INT TERM
    exit 1
  fi
  log_msg "Post-restore SHA-256 verification PASSED"
else
  log_msg "Skipping post-restore checksum comparison (no reference checksum)"
  log_msg "Current SHA-256: $POST_EXTRACT_SHA256"
fi

############################
# STEP 4: START MYSQL
############################

log_msg "[Step 4/4] Starting MySQL server..."

if ! systemctl start mysql 2>>"$ERROR_LOG"; then
  log_error "Failed to start MySQL service"
  log_error "Check MySQL error log for details"
  trap - ERR INT TERM
  exit 1
fi

log_msg "Waiting for MySQL to accept connections..."

MYSQL_READY=false
for i in {1..60}; do
  if mysql_cmd -e "SELECT 1" &>/dev/null; then
    log_msg "MySQL is ready"
    MYSQL_READY=true
    break
  fi
  if [[ $((i % 10)) -eq 0 ]]; then
    log_msg "Still waiting for MySQL... (${i}/60)"
  fi
  sleep 2
done

if [[ "$MYSQL_READY" != true ]]; then
  log_error "MySQL failed to become ready after 120 seconds"
  log_error "Check MySQL error log: /var/log/mysql/error.log"
  trap - ERR INT TERM
  exit 1
fi

############################
# WRITE RESTORE MARKER
# Records timestamp of successful restore.
# apply_binlogs.sh reads this to confirm restore was done.
############################

RESTORE_TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
echo "$RESTORE_TIMESTAMP" > "$RESTORE_MARKER"
log_msg "Restore marker written: $RESTORE_MARKER"
log_msg "Restore completed at  : $RESTORE_TIMESTAMP"

############################
# FINAL VALIDATION
############################

log_msg "Performing final validation..."

if ! is_mysql_running; then
  log_error "MySQL is not running after restore"
  trap - ERR INT TERM
  exit 1
fi

if ! test_mysql_connection; then
  log_error "Cannot connect to MySQL after restore"
  trap - ERR INT TERM
  exit 1
fi

DB_COUNT=$(mysql_cmd -NBe "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema','mysql','performance_schema','sys')" 2>>"$ERROR_LOG" || echo "0")
log_msg "Final validation passed"
log_msg "User databases found: $DB_COUNT"

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
  echo "FULL RESTORE COMPLETED SUCCESSFULLY"
  echo "===================================================="
  echo "Start time     : $START_TIME"
  echo "End time       : $END_TIME"
  echo "Duration       : ${DURATION_MIN}m ${DURATION_SEC}s"
  echo "Backup date    : $BACKUP_DATE"
  echo "Backup file    : $COMPRESSED_BACKUP"
  echo "SHA-256        : $BACKUP_SHA256"
  echo "User databases : $DB_COUNT"
  echo "Restore marker : $RESTORE_MARKER"
  echo "===================================================="
  echo "Next step:"
  echo "  Run apply_binlogs.sh $BACKUP_DATE to apply binlogs"
  echo "===================================================="
  echo "Log files:"
  echo "  Main log   : $RUN_LOG"
  echo "  Error log  : $ERROR_LOG"
  echo "===================================================="
} | tee -a "$RUN_LOG"

trap - ERR INT TERM
exit 0