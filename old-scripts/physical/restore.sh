#!/usr/bin/env bash
set -euo pipefail

############################
# CONFIGURATION
############################

# MySQL credentials for CURRENT server (before restore)
MYSQL_USER="percona"
MYSQL_PASSWORD=""

# MySQL credentials from SOURCE server (after restore)
SOURCE_MYSQL_USER="percona"
SOURCE_MYSQL_PASSWORD=""

# Backup directories
BACKUP_BASE="/home/miracle/binlogdata"

# MySQL data directory
MYSQL_DATADIR="/Data/mysql"

# Binary paths
XTRABACKUP_BIN="/usr/bin/xtrabackup"
MYSQLBINLOG_BIN="/usr/bin/mysqlbinlog"
MYSQL_BIN="/usr/bin/mysql"

ARCHIVE_DIR="/home/miracle/binlogdata"

# Track which credentials to use
USE_SOURCE_CREDS=false

############################
# EARLY INITIALIZATION
############################

# Initialize variables that might be used in cleanup before they're set
EXTRACTED_DIR=""
RUN_LOG=""
ERROR_LOG=""
BACKUP_DATE=""
COMPRESSED_BACKUP=""
CHECKSUM_FILE=""
BINLOG_INFO_FILE=""
BINLOG_DIR=""
START_BINLOG=""
START_POS=""
BINLOGS_AVAILABLE=false
APPLIED_COUNT=0
BINLOG_ERRORS=0
DB_COUNT=0
BACKUP_SIZE="N/A"
BACKUP_SHA256="N/A"

############################
# HELPER FUNCTIONS
############################

# Timestamped log function
log_msg() {
  if [[ -n "$RUN_LOG" && -f "$RUN_LOG" ]]; then
    echo "[$(date '+%F %T')] [INFO] $1" | tee -a "$RUN_LOG"
  else
    echo "[$(date '+%F %T')] [INFO] $1"
  fi
}

# Log error function
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

# Log warning function
log_warn() {
  if [[ -n "$RUN_LOG" && -f "$RUN_LOG" ]]; then
    echo "[$(date '+%F %T')] [WARN] $1" | tee -a "$RUN_LOG"
  else
    echo "[$(date '+%F %T')] [WARN] $1"
  fi
}

# Cleanup function on error
cleanup_on_error() {
  log_error "Restore failed. Cleaning up..."
  
  # Remove incomplete extracted directory
  if [[ -n "${EXTRACTED_DIR:-}" && -d "$EXTRACTED_DIR" ]]; then
    log_msg "Removing incomplete extracted directory: $EXTRACTED_DIR"
    rm -rf "$EXTRACTED_DIR" 2>/dev/null || true
  fi
  
  # Attempt to start MySQL if it was stopped
  if systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mysqld 2>/dev/null; then
    log_msg "MySQL is already running"
  else
    log_msg "Attempting to start MySQL..."
    systemctl start mysql 2>/dev/null || true
  fi
  
  log_error "Restore aborted. Check logs: ${RUN_LOG:-'(not initialized)'}"
  
  # Remove trap before exiting
  trap - ERR INT TERM
  exit 1
}

# Set trap for cleanup on error
trap cleanup_on_error ERR INT TERM

# MySQL command wrapper with credentials
mysql_cmd() {
  if [[ "$USE_SOURCE_CREDS" == true ]]; then
    "$MYSQL_BIN" -u"${SOURCE_MYSQL_USER}" -p"${SOURCE_MYSQL_PASSWORD}" "$@"
  else
    "$MYSQL_BIN" -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" "$@"
  fi
}

# Test MySQL connection
test_mysql_connection() {
  if ! mysql_cmd -e "SELECT 1" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# Get free space in GB
get_free_space_gb() {
  local path="$1"
  df -BG "$path" | awk 'NR==2 {print $4}' | sed 's/G//'
}

# Validate directory is writable
validate_writable() {
  local dir="$1"
  local test_file="$dir/.write_test_$$"
  
  if ! touch "$test_file" 2>/dev/null; then
    return 1
  fi
  
  rm -f "$test_file"
  return 0
}

# Check if MySQL is running
is_mysql_running() {
  if systemctl is-active --quiet mysql 2>/dev/null || \
     systemctl is-active --quiet mysqld 2>/dev/null; then
    return 0
  fi
  
  # Fallback: check process
  if pgrep -x mysqld >/dev/null 2>&1; then
    return 0
  fi
  
  return 1
}

# Show usage
show_usage() {
  echo "Usage: $0 <backup_date_YYYYMMDD>"
  echo ""
  echo "Arguments:"
  echo "  backup_date_YYYYMMDD  :  Date of backup to restore (required)"
  echo ""
  echo "Examples:"
  echo "  $0 20260106              # Restore and apply binlog for all user databases"
  
  # Remove trap before exiting
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

# Validate date format
if ! [[ "$BACKUP_DATE" =~ ^[0-9]{8}$ ]]; then
  echo "[$(date '+%F %T')] [ERROR] Invalid date format. Expected YYYYMMDD" >&2
  trap - ERR INT TERM
  exit 1
fi

############################
# DERIVED PATHS
############################

COMPRESSED_BACKUP="${BACKUP_BASE}/${BACKUP_DATE}.tar.gz"
CHECKSUM_FILE="${BACKUP_BASE}/${BACKUP_DATE}.sha256"
EXTRACTED_DIR="${BACKUP_BASE}/${BACKUP_DATE}"
BINLOG_INFO_FILE="${ARCHIVE_DIR}/${BACKUP_DATE}_binlog_info"
BINLOG_DIR="${BACKUP_BASE}/binlog/${BACKUP_DATE}"
RUN_LOG="${BACKUP_BASE}/${BACKUP_DATE}_restore.log"
ERROR_LOG="${BACKUP_BASE}/${BACKUP_DATE}_restore_errors.log"

# Timestamps for duration tracking
START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
START_EPOCH="$(date +%s)"

############################
# INITIALIZE LOGS
############################

# Ensure backup base directory exists
if [[ ! -d "$BACKUP_BASE" ]]; then
  if ! mkdir -p "$BACKUP_BASE" 2>/dev/null; then
    echo "[$(date '+%F %T')] [ERROR] Failed to create backup base directory: $BACKUP_BASE" >&2
    trap - ERR INT TERM
    exit 1
  fi
fi

# Initialize main log
cat > "$RUN_LOG" << EOF
========================================
MYSQL RESTORE LOG
========================================
Backup Date: $BACKUP_DATE
Started: $(date '+%F %T')
========================================

EOF

# Initialize error log
cat > "$ERROR_LOG" << EOF
========================================
MYSQL RESTORE ERROR LOG
========================================
Backup Date: $BACKUP_DATE
Started: $(date '+%F %T')
========================================

EOF

############################
# PRE-FLIGHT CHECKS
############################

log_msg "===================================================="
log_msg "Starting comprehensive pre-flight checks..."
log_msg "===================================================="

# Check 1: Verify running as root
log_msg "Check 1/14: Verifying user privileges..."
if [[ $EUID -ne 0 ]]; then
  log_error "This script must be run as root"
  trap - ERR INT TERM
  exit 1
fi
log_msg "Running as root"

# Check 2: Verify required commands exist
log_msg "Check 2/14: Verifying required binaries..."
REQUIRED_COMMANDS=(tar gzip awk du df stat wc pgrep chown rm sleep basename find sort sha256sum)
for cmd in "${REQUIRED_COMMANDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "Required command not found in PATH: $cmd"
    trap - ERR INT TERM
    exit 1
  fi
done

# Verify xtrabackup binary
if [[ ! -x "$XTRABACKUP_BIN" ]]; then
  log_error "XtraBackup binary not found or not executable: $XTRABACKUP_BIN"
  trap - ERR INT TERM
  exit 1
fi

# Verify mysql binary
if [[ ! -x "$MYSQL_BIN" ]]; then
  log_error "MySQL binary not found or not executable: $MYSQL_BIN"
  trap - ERR INT TERM
  exit 1
fi

# Verify mysqlbinlog binary
if [[ ! -x "$MYSQLBINLOG_BIN" ]]; then
  log_error "mysqlbinlog binary not found or not executable: $MYSQLBINLOG_BIN"
  trap - ERR INT TERM
  exit 1
fi

# Verify systemctl exists
if ! command -v systemctl >/dev/null 2>&1; then
  log_error "systemctl not found - this script requires systemd"
  trap - ERR INT TERM
  exit 1
fi

log_msg "All required binaries found"

# Check 3: Verify compressed backup exists
log_msg "Check 3/14: Verifying compressed backup exists..."
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

# Check 4: Verify SHA-256 checksum of backup (replaces tar archive integrity check)
log_msg "Check 4/14: Verifying SHA-256 checksum of backup..."
if [[ ! -f "$CHECKSUM_FILE" ]]; then
  log_warn "SHA-256 checksum file not found: $CHECKSUM_FILE"
  log_warn "Skipping checksum verification - backup integrity cannot be guaranteed"
  log_warn "Consider re-running the backup to generate a checksum file"
  BACKUP_SHA256="N/A (checksum file missing)"
else
  if [[ ! -r "$CHECKSUM_FILE" ]]; then
    log_error "SHA-256 checksum file not readable: $CHECKSUM_FILE"
    trap - ERR INT TERM
    exit 1
  fi
  
  if [[ ! -s "$CHECKSUM_FILE" ]]; then
    log_error "SHA-256 checksum file is empty: $CHECKSUM_FILE"
    trap - ERR INT TERM
    exit 1
  fi
  
  # Read the expected checksum
  EXPECTED_SHA256=$(awk '{print $1}' "$CHECKSUM_FILE")
  log_msg "Expected SHA-256: $EXPECTED_SHA256"
  
  # Calculate the actual checksum of the backup file
  log_msg "Calculating SHA-256 checksum of backup file (this may take a while for large backups)..."
  ACTUAL_SHA256=$(sha256sum "$COMPRESSED_BACKUP" | awk '{print $1}')
  log_msg "Actual SHA-256:   $ACTUAL_SHA256"
  
  # Compare checksums
  if [[ "$EXPECTED_SHA256" != "$ACTUAL_SHA256" ]]; then
    log_error "SHA-256 CHECKSUM MISMATCH!"
    log_error "Expected: $EXPECTED_SHA256"
    log_error "Actual:   $ACTUAL_SHA256"
    log_error "The backup file may be corrupted or tampered with"
    trap - ERR INT TERM
    exit 1
  fi
  
  BACKUP_SHA256="$ACTUAL_SHA256"
  log_msg "SHA-256 checksum verification PASSED - backup integrity confirmed"
fi

# Check 5: Verify binlog info file exists
log_msg "Check 5/14: Verifying binlog info file..."
if [[ ! -f "$BINLOG_INFO_FILE" ]]; then
  log_error "Binlog info not found: $BINLOG_INFO_FILE"
  trap - ERR INT TERM
  exit 1
fi

if [[ ! -r "$BINLOG_INFO_FILE" ]]; then
  log_error "Binlog info file not readable: $BINLOG_INFO_FILE"
  trap - ERR INT TERM
  exit 1
fi

# Validate binlog info content
if [[ ! -s "$BINLOG_INFO_FILE" ]]; then
  log_error "Binlog info file is empty"
  trap - ERR INT TERM
  exit 1
fi

log_msg "Binlog info file found and readable"

# Check 6: Check binlog directory
log_msg "Check 6/14: Checking binlog directory..."
BINLOGS_AVAILABLE=true
if [[ ! -d "$BINLOG_DIR" ]]; then
  log_warn "Binlog directory not found: $BINLOG_DIR"
  log_warn "Restore will proceed without point-in-time recovery"
  BINLOGS_AVAILABLE=false
else
  BINLOG_COUNT=$(find "$BINLOG_DIR" -type f -name "binlog.*" 2>/dev/null | wc -l)
  if [[ $BINLOG_COUNT -eq 0 ]]; then
    log_warn "No binlog files found in: $BINLOG_DIR"
    BINLOGS_AVAILABLE=false
  else
    log_msg "Found $BINLOG_COUNT binlog file(s) in: $BINLOG_DIR"
  fi
fi

# Check 7: Verify MySQL data directory exists
log_msg "Check 7/14: Verifying MySQL data directory..."
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

# Check 8: Verify backup base directory is writable
log_msg "Check 8/14: Verifying backup directory is writable..."
if ! validate_writable "$BACKUP_BASE"; then
  log_error "Backup directory is not writable: $BACKUP_BASE"
  trap - ERR INT TERM
  exit 1
fi
log_msg "Backup directory is writable"

# Check 9: Check available disk space
log_msg "Check 9/14: Checking available disk space..."
BACKUP_FREE_SPACE=$(get_free_space_gb "$BACKUP_BASE")
DATADIR_FREE_SPACE=$(get_free_space_gb "$MYSQL_DATADIR")

log_msg "Free space in $BACKUP_BASE: ${BACKUP_FREE_SPACE}GB"
log_msg "Free space in $MYSQL_DATADIR: ${DATADIR_FREE_SPACE}GB"

# Estimate required space (compressed size * 3 for extraction + some overhead)
COMPRESSED_SIZE_BYTES=$(stat -c%s "$COMPRESSED_BACKUP" 2>/dev/null || echo "0")
COMPRESSED_SIZE_GB=$((COMPRESSED_SIZE_BYTES / 1024 / 1024 / 1024 + 1))
REQUIRED_BACKUP_SPACE=$((COMPRESSED_SIZE_GB * 4))
REQUIRED_DATADIR_SPACE=$((COMPRESSED_SIZE_GB * 3))

if [[ $BACKUP_FREE_SPACE -lt $REQUIRED_BACKUP_SPACE ]]; then
  log_error "Insufficient space in $BACKUP_BASE"
  log_error "Required: ${REQUIRED_BACKUP_SPACE}GB, Available: ${BACKUP_FREE_SPACE}GB"
  trap - ERR INT TERM
  exit 1
fi

if [[ $DATADIR_FREE_SPACE -lt $REQUIRED_DATADIR_SPACE ]]; then
  log_error "Insufficient space in $MYSQL_DATADIR"
  log_error "Required: ${REQUIRED_DATADIR_SPACE}GB, Available: ${DATADIR_FREE_SPACE}GB"
  trap - ERR INT TERM
  exit 1
fi

log_msg "Sufficient disk space available"

# Check 10: Verify MySQL status
log_msg "Check 10/14: Verifying MySQL status..."
if is_mysql_running; then
  log_msg "MySQL is currently running (will be stopped during restore)"
  
  # Test connection with current credentials
  log_msg "Testing current MySQL credentials..."
  if test_mysql_connection; then
    log_msg "Current MySQL credentials are valid"
  else
    log_warn "Cannot connect with current credentials (may be expected)"
  fi
else
  log_msg "MySQL is not running (will be started after restore)"
fi

# Check 11: Verify no other restore is running
log_msg "Check 11/14: Checking for concurrent restore operations..."
SCRIPT_NAME=$(basename "$0")
RUNNING_COUNT=$(pgrep -f "$SCRIPT_NAME" | wc -l)

if [[ $RUNNING_COUNT -gt 2 ]]; then
  log_error "Another restore process is already running"
  trap - ERR INT TERM
  exit 1
fi
log_msg "No concurrent restore operations detected"

# Check 12: Verify extracted directory doesn't exist
log_msg "Check 12/14: Verifying extracted directory is clean..."
if [[ -d "$EXTRACTED_DIR" ]]; then
  log_warn "Extracted directory already exists: $EXTRACTED_DIR"
  log_msg "Removing existing extracted directory..."
  if ! rm -rf "$EXTRACTED_DIR" 2>>"$ERROR_LOG"; then
    log_error "Failed to remove existing extracted directory"
    trap - ERR INT TERM
    exit 1
  fi
fi
log_msg "Extracted directory is clean"

# Check 13: Verify xtrabackup version
log_msg "Check 13/14: Verifying xtrabackup binary..."
XTRABACKUP_VERSION=$("$XTRABACKUP_BIN" --version 2>&1 | head -1)
log_msg "XtraBackup version: $XTRABACKUP_VERSION"

# Check 14: Test sha256sum functionality
log_msg "Check 14/14: Testing SHA-256 checksum utility..."
TEST_FILE="$BACKUP_BASE/.sha256_test_$$"
echo "sha256test" > "$TEST_FILE"
if ! sha256sum "$TEST_FILE" >/dev/null 2>&1; then
  log_error "sha256sum test failed"
  rm -f "$TEST_FILE"
  trap - ERR INT TERM
  exit 1
fi
rm -f "$TEST_FILE"
log_msg "SHA-256 checksum utility working"

log_msg "===================================================="
log_msg "All pre-flight checks passed successfully"
log_msg "===================================================="

############################
# LOG START
############################

{
  echo ""
  echo "===================================================="
  echo "MYSQL RESTORE STARTED"
  echo "Start time         : $START_TIME"
  echo "Backup date        : $BACKUP_DATE"
  echo "Backup file        : $COMPRESSED_BACKUP"
  echo "Backup size        : $BACKUP_SIZE"
  echo "SHA-256 checksum   : $BACKUP_SHA256"
  echo "Binlog info        : $BINLOG_INFO_FILE"
  echo "Binlogs available  : $BINLOGS_AVAILABLE"
  echo "MySQL datadir      : $MYSQL_DATADIR"
  echo "===================================================="
  echo ""
} | tee -a "$RUN_LOG"

############################
# READ BINLOG CHECKPOINT
############################

START_BINLOG="$(awk '{print $1}' "$BINLOG_INFO_FILE")"
START_POS="$(awk '{print $2}' "$BINLOG_INFO_FILE")"

if [[ -z "$START_BINLOG" || -z "$START_POS" ]]; then
  log_error "Invalid binlog info format in $BINLOG_INFO_FILE"
  trap - ERR INT TERM
  exit 1
fi

log_msg "Binlog checkpoint - File: $START_BINLOG, Position: $START_POS"

############################
# STEP 1: DECOMPRESS BACKUP
############################

log_msg "[Step 1/7] Decompressing backup..."

# Decompress
if ! tar -xzf "$COMPRESSED_BACKUP" -C "$BACKUP_BASE" 2>>"$ERROR_LOG"; then
  log_error "Failed to decompress backup file"
  trap - ERR INT TERM
  exit 1
fi

# Verify extraction
if [[ ! -d "$EXTRACTED_DIR" ]]; then
  log_error "Decompression completed but directory not found: $EXTRACTED_DIR"
  trap - ERR INT TERM
  exit 1
fi

# Verify critical files exist
if [[ ! -f "$EXTRACTED_DIR/xtrabackup_checkpoints" ]]; then
  log_error "xtrabackup_checkpoints not found in extracted backup"
  trap - ERR INT TERM
  exit 1
fi

log_msg "Decompression completed successfully"

############################
# STEP 2: POST-EXTRACTION SHA-256 VERIFICATION
############################

log_msg "[Step 2/7] Post-extraction SHA-256 verification..."

# Re-verify the compressed backup hasn't changed during extraction
# This catches any filesystem-level corruption that might have occurred
log_msg "Re-verifying compressed backup checksum after extraction..."
POST_EXTRACT_SHA256=$(sha256sum "$COMPRESSED_BACKUP" | awk '{print $1}')

if [[ "$BACKUP_SHA256" != "N/A" && "$BACKUP_SHA256" != "N/A (checksum file missing)" ]]; then
  if [[ "$POST_EXTRACT_SHA256" != "$BACKUP_SHA256" ]]; then
    log_error "SHA-256 checksum changed during extraction!"
    log_error "Pre-extraction:  $BACKUP_SHA256"
    log_error "Post-extraction: $POST_EXTRACT_SHA256"
    log_error "Possible filesystem corruption detected"
    trap - ERR INT TERM
    exit 1
  fi
  log_msg "Post-extraction SHA-256 verification PASSED"
else
  log_msg "Skipping post-extraction checksum comparison (no reference checksum available)"
  log_msg "Current SHA-256: $POST_EXTRACT_SHA256"
fi

############################
# STEP 3: STOP MYSQL
############################

log_msg "[Step 3/7] Stopping MySQL server..."

if is_mysql_running; then
  if ! systemctl stop mysql 2>>"$ERROR_LOG"; then
    log_error "Failed to stop MySQL service"
    trap - ERR INT TERM
    exit 1
  fi
  
  # Wait for MySQL to fully stop
  sleep 3
  
  # Verify MySQL is stopped
  if is_mysql_running; then
    log_error "MySQL is still running after stop command"
    trap - ERR INT TERM
    exit 1
  fi
  
  log_msg "MySQL stopped successfully"
else
  log_msg "MySQL was already stopped"
fi

############################
# STEP 4: CLEAR DATA DIRECTORY
############################

log_msg "[Step 4/7] Clearing MySQL data directory..."

# Final safety check
if [[ -z "$MYSQL_DATADIR" || "$MYSQL_DATADIR" == "/" ]]; then
  log_error "Invalid MYSQL_DATADIR path: $MYSQL_DATADIR"
  trap - ERR INT TERM
  exit 1
fi

# Clear data directory
if ! rm -rf "${MYSQL_DATADIR:?}/"* 2>>"$ERROR_LOG"; then
  log_error "Failed to clear data directory"
  trap - ERR INT TERM
  exit 1
fi

# Verify directory is empty
if [[ -n "$(ls -A "$MYSQL_DATADIR" 2>/dev/null)" ]]; then
  log_error "Data directory is not empty after cleanup"
  trap - ERR INT TERM
  exit 1
fi

log_msg "Data directory cleared successfully"

############################
# STEP 5: RESTORE BACKUP
############################

log_msg "[Step 5/7] Restoring backup with xtrabackup..."

if ! "$XTRABACKUP_BIN" \
  --copy-back \
  --target-dir="$EXTRACTED_DIR" \
  >>"$RUN_LOG" 2>>"$ERROR_LOG"; then
  log_error "Xtrabackup restore failed"
  trap - ERR INT TERM
  exit 1
fi

# Verify restoration
if [[ ! -f "$MYSQL_DATADIR/ibdata1" ]]; then
  log_error "Core database files not found after restore"
  trap - ERR INT TERM
  exit 1
fi

# Fix ownership
log_msg "Setting ownership on restored files..."
if ! chown -R mysql:mysql "$MYSQL_DATADIR" 2>>"$ERROR_LOG"; then
  log_error "Failed to set ownership on data directory"
  trap - ERR INT TERM
  exit 1
fi

log_msg "Backup restored successfully"

############################
# STEP 6: START MYSQL
############################

log_msg "[Step 6/7] Starting MySQL server..."

if ! systemctl start mysql 2>>"$ERROR_LOG"; then
  log_error "Failed to start MySQL service"
  log_error "Check MySQL error log for details"
  trap - ERR INT TERM
  exit 1
fi

log_msg "Waiting for MySQL to accept connections..."

# After restore, use SOURCE credentials
USE_SOURCE_CREDS=true

MYSQL_READY=false
for i in {1..60}; do
  if mysql_cmd -e "SELECT 1" &>/dev/null; then
    log_msg "MySQL is ready (using source server credentials)"
    MYSQL_READY=true
    break
  fi
  
  if [[ $((i % 10)) -eq 0 ]]; then
    log_msg "Still waiting for MySQL... (${i}/60)"
  fi
  
  sleep 2
done

if [[ "$MYSQL_READY" != true ]]; then
  log_error "MySQL failed to start or credentials invalid after 120 seconds"
  log_error "Check MySQL error log: /var/log/mysql/error.log"
  trap - ERR INT TERM
  exit 1
fi

############################
# STEP 7: APPLY BINLOGS
############################

if [[ "$BINLOGS_AVAILABLE" != true ]]; then
  log_msg "[Step 7/7] Skipping binlog apply - no binlogs available"
else
  log_msg "[Step 7/7] Applying binary logs..."

  shopt -s nullglob
  BINLOG_FILES=("$BINLOG_DIR"/binlog.*)
  shopt -u nullglob

  if [[ ${#BINLOG_FILES[@]} -eq 0 ]]; then
    log_warn "No binlog files found to apply"
  else
    # Sort binlog files
    IFS=$'\n' BINLOG_FILES=($(sort <<<"${BINLOG_FILES[*]}"))
    unset IFS

    APPLY_STARTED=false

    log_msg "Found ${#BINLOG_FILES[@]} binlog file(s) to process"

    for BINLOG_PATH in "${BINLOG_FILES[@]}"; do
      BINLOG_FILE="$(basename "$BINLOG_PATH")"

      # Skip non-binlog files
      [[ "$BINLOG_FILE" == *".log" ]] && continue
      [[ "$BINLOG_FILE" == "last_copied_binlog" ]] && continue

      # Find start position
      if [[ "$BINLOG_FILE" == "$START_BINLOG" ]]; then
        log_msg "Applying $BINLOG_FILE from position $START_POS"

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

        APPLY_STARTED=true
        continue
      fi

      # Apply subsequent binlogs
      if [[ "$APPLY_STARTED" == true ]]; then
        log_msg "Applying $BINLOG_FILE"

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

    if [[ "$APPLY_STARTED" != true ]]; then
      log_warn "Start binlog $START_BINLOG not found in archive"
    fi

    if [[ $BINLOG_ERRORS -gt 0 ]]; then
      log_warn "$BINLOG_ERRORS binlog file(s) failed to apply. Check $ERROR_LOG"
    fi

    log_msg "Binlog application completed: $APPLIED_COUNT applied, $BINLOG_ERRORS errors"
  fi
fi

############################
# CLEANUP
############################

log_msg "Cleaning up extracted directory..."

if ! rm -rf "$EXTRACTED_DIR" 2>>"$ERROR_LOG"; then
  log_warn "Failed to remove extracted directory: $EXTRACTED_DIR"
else
  log_msg "Temporary files removed"
fi

############################
# FINAL VALIDATION
############################

log_msg "Performing final validation..."

# Verify MySQL is still running
if ! is_mysql_running; then
  log_error "MySQL is not running after restore"
  trap - ERR INT TERM
  exit 1
fi

# Verify connection still works
if ! test_mysql_connection; then
  log_error "Cannot connect to MySQL after restore"
  trap - ERR INT TERM
  exit 1
fi

# Get database count
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
  echo "RESTORE COMPLETED SUCCESSFULLY"
  echo "===================================================="
  echo "Start time         : $START_TIME"
  echo "End time           : $END_TIME"
  echo "Duration           : ${DURATION_MIN}m ${DURATION_SEC}s"
  echo "Backup date        : $BACKUP_DATE"
  echo "Backup file        : $COMPRESSED_BACKUP"
  echo "SHA-256 checksum   : $BACKUP_SHA256"
  echo "User databases     : $DB_COUNT"
  echo "Binlogs applied    : $APPLIED_COUNT"
  echo "Binlog errors      : $BINLOG_ERRORS"
  echo "Binlog position    : $START_BINLOG:$START_POS"
  echo "===================================================="
  echo "Log Files:"
  echo "  Full log         : $RUN_LOG"
  echo "  Error log        : $ERROR_LOG"
  echo ""
  echo "MySQL Credentials:"
  echo "  Username         : $SOURCE_MYSQL_USER"
  echo "  (Use credentials from source server)"
  echo "===================================================="
} | tee -a "$RUN_LOG"

# Remove trap since we succeeded
trap - ERR INT TERM

exit 0