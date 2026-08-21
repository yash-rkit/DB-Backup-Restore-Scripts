#!/usr/bin/env bash
set -euo pipefail

############################
# CONFIGURATION
############################

# MySQL credentials
MYSQL_USER="Admin"
MYSQL_PASSWORD=""

# Root directory where all full backups will be stored
BACKUP_BASE="/Data/percona_backup"

# Percona XtraBackup binary path
XTRABACKUP_BIN="/usr/bin/xtrabackup"

# MySQL data directory
MYSQL_DATADIR="/Data/mysql"

# Number of parallel threads for xtrabackup
PARALLEL_THREADS=4

# Remote / secondary storage directory
ARCHIVE_DIR="/livestorage/Backup/Cloud-Live-DB-Default/percona"

# MySQL client binary for connection testing
MYSQL_BIN="/usr/bin/mysql"

# Binlog collection script
BINLOG_SCRIPT="/Data/script/binlog_collect.sh"

# Retention cleanup script
DELETE_SCRIPT="/Data/script/percona_delete.sh"

############################
# EARLY INITIALIZATION
############################

# Initialize variables that might be used in cleanup before they're set
TARGET_DIR=""
COMPRESSED_FILE=""
CHECKSUM_FILE=""
BINLOG_INFO_FILE=""
RUN_LOG=""
ERROR_LOG=""
UNCOMPRESSED_SIZE="N/A"
COMPRESSION_RATIO="N/A"

# Today's date
TODAY="$(date +%Y%m%d)"

# Lock file — date-prefixed so yesterday's lock never affects today
# Removed by cleanup_on_error on failure AND at end of script on success
LOCK_FILE="${ARCHIVE_DIR}/${TODAY}_lock"

############################
# HELPER FUNCTIONS
############################

# Timestamped log function
log_msg() {
  if [[ -n "$RUN_LOG" && -w "$(dirname "$RUN_LOG")" ]]; then
    echo "[$(date '+%F %T')] [INFO] $1" | tee -a "$RUN_LOG"
  else
    echo "[$(date '+%F %T')] [INFO] $1"
  fi
}

# Log error function
log_error() {
  if [[ -n "$RUN_LOG" && -w "$(dirname "$RUN_LOG")" ]]; then
    echo "[$(date '+%F %T')] [ERROR] $1" | tee -a "$RUN_LOG" >&2
  else
    echo "[$(date '+%F %T')] [ERROR] $1" >&2
  fi
}

# Log warning function
log_warn() {
  if [[ -n "$RUN_LOG" && -w "$(dirname "$RUN_LOG")" ]]; then
    echo "[$(date '+%F %T')] [WARN] $1" | tee -a "$RUN_LOG"
  else
    echo "[$(date '+%F %T')] [WARN] $1"
  fi
}

# Cleanup function on error
# Lock file is ALWAYS deleted — on failure via trap, on success at end of script
cleanup_on_error() {
  log_error "Backup failed. Cleaning up..."

  # Remove incomplete backup directory
  if [[ -f "$LOCK_FILE" ]]; then
    log_msg "Removing lock file on failure: $LOCK_FILE"
    rm -f "$LOCK_FILE" 2>/dev/null || true
  fi

  if [[ -n "${TARGET_DIR:-}" && -d "$TARGET_DIR" ]]; then
    log_msg "Removing incomplete backup directory: $TARGET_DIR"
    rm -rf "$TARGET_DIR" 2>/dev/null || true
  fi

  # Remove incomplete compressed file
  if [[ -n "${COMPRESSED_FILE:-}" && -f "$COMPRESSED_FILE" ]]; then
    log_msg "Removing incomplete compressed file: $COMPRESSED_FILE"
    rm -f "$COMPRESSED_FILE" 2>/dev/null || true
  fi

  # Remove incomplete checksum file
  if [[ -n "${CHECKSUM_FILE:-}" && -f "$CHECKSUM_FILE" ]]; then
    log_msg "Removing incomplete checksum file: $CHECKSUM_FILE"
    rm -f "$CHECKSUM_FILE" 2>/dev/null || true
  fi

  # Remove incomplete binlog info
  if [[ -n "${BINLOG_INFO_FILE:-}" && -f "$BINLOG_INFO_FILE" ]]; then
    log_msg "Removing incomplete binlog info: $BINLOG_INFO_FILE"
    rm -f "$BINLOG_INFO_FILE" 2>/dev/null || true
  fi

  log_error "Backup aborted. Check logs: ${RUN_LOG:-'(not initialized)'}"
    
  # Remove trap before exiting
  trap - ERR INT TERM
  exit 1
}

# Set trap for cleanup on error
trap cleanup_on_error ERR INT TERM
# Get free space in GB
get_free_space_gb() {
  local path="$1"
  df -BG "$path" | awk 'NR==2 {print $4}' | sed 's/G//'
}

# Estimate MySQL data size in GB
get_mysql_data_size_gb() {
  du -sb "$MYSQL_DATADIR" 2>/dev/null | awk '{print int($1/1024/1024/1024)+1}'
}

# Test MySQL connection
test_mysql_connection() {
  if ! "$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "SELECT 1" >/dev/null 2>&1; then
    return 1
  fi
  return 0
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

############################
# DERIVED PATHS
############################

# Temporary directory for backup (will be removed after compression)
TARGET_DIR="${BACKUP_BASE}/${TODAY}"

# Final compressed backup file
COMPRESSED_FILE="${BACKUP_BASE}/${TODAY}.tar.gz"

# SHA-256 checksum file
CHECKSUM_FILE="${BACKUP_BASE}/${TODAY}.sha256"

# External binlog info file (for fast access without extracting archive)
BINLOG_INFO_FILE="${BACKUP_BASE}/${TODAY}_binlog_info"

# Log files
XTRABACKUP_LOG="${BACKUP_BASE}/${TODAY}_xtrabackup.log"
RUN_LOG="${BACKUP_BASE}/${TODAY}_backup.log"
ERROR_LOG="${BACKUP_BASE}/${TODAY}_errors.log"

# Timestamps for duration tracking
START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
START_EPOCH="$(date +%s)"

############################
# SETUP
############################

# Handle existing backup (append timestamp if exists)
if [[ -d "$TARGET_DIR" || -f "$COMPRESSED_FILE" ]]; then
  TIMESTAMP="$(date +%H%M%S)"
  TARGET_DIR="${BACKUP_BASE}/${TODAY}_${TIMESTAMP}"
  COMPRESSED_FILE="${BACKUP_BASE}/${TODAY}_${TIMESTAMP}.tar.gz"
  CHECKSUM_FILE="${BACKUP_BASE}/${TODAY}_${TIMESTAMP}.sha256"
  BINLOG_INFO_FILE="${BACKUP_BASE}/${TODAY}_${TIMESTAMP}_binlog_info"
  XTRABACKUP_LOG="${BACKUP_BASE}/${TODAY}_${TIMESTAMP}_xtrabackup.log"
  RUN_LOG="${BACKUP_BASE}/${TODAY}_${TIMESTAMP}_backup.log"
  ERROR_LOG="${BACKUP_BASE}/${TODAY}_${TIMESTAMP}_errors.log"
fi

# Create directories with proper error handling
for dir in "$BACKUP_BASE" "$ARCHIVE_DIR"; do
  if [[ ! -d "$dir" ]]; then
    if ! mkdir -p "$dir" 2>/dev/null; then
      echo "[$(date '+%F %T')] [ERROR] Failed to create directory: $dir" >&2
      trap - ERR INT TERM
      exit 1
    fi
  fi
done

# Create target directory
if ! mkdir -p "$TARGET_DIR" 2>/dev/null; then
  echo "[$(date '+%F %T')] [ERROR] Failed to create target directory: $TARGET_DIR" >&2
  trap - ERR INT TERM
  exit 1
fi

############################
# PRE-FLIGHT CHECKS
############################

# Initialize error log
cat > "$ERROR_LOG" << EOF
========================================
BACKUP ERROR LOG
========================================
Date: $(date '+%F %T')
========================================

EOF

log_msg "===================================================="
log_msg "Starting comprehensive pre-flight checks..."
log_msg "===================================================="

# Check 1: Verify running as root or with sufficient privileges
log_msg "Check 1/14: Verifying user privileges..."
if [[ $EUID -ne 0 ]]; then
  log_warn "Not running as root. Ensure user has sufficient privileges."
else
  log_msg "Running as root"
fi

# Check 2: Verify required commands exist
log_msg "Check 2/14: Verifying required binaries..."
REQUIRED_COMMANDS=(xtrabackup mysql tar gzip awk du df grep bc sha256sum)
for cmd in "${REQUIRED_COMMANDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "Required command not found in PATH: $cmd"
    trap - ERR INT TERM
    exit 1
  fi
done
log_msg "All required binaries found"

# Check 3: Verify xtrabackup version
log_msg "Check 3/14: Verifying xtrabackup version..."
XTRABACKUP_VERSION=$("$XTRABACKUP_BIN" --version 2>&1 | head -1)
log_msg "XtraBackup version: $XTRABACKUP_VERSION"

# Check 4: Verify MySQL is running
log_msg "Check 4/14: Verifying MySQL is running..."
if ! is_mysql_running; then
  log_error "MySQL is not running"
  trap - ERR INT TERM
  exit 1
fi
log_msg "MySQL is running"

# Check 5: Verify MySQL data directory exists and is readable
log_msg "Check 5/14: Verifying MySQL data directory..."
if [[ ! -d "$MYSQL_DATADIR" ]]; then
  log_error "MySQL datadir not found: $MYSQL_DATADIR"
  trap - ERR INT TERM
  exit 1
fi

if [[ ! -r "$MYSQL_DATADIR" ]]; then
  log_error "MySQL datadir not readable: $MYSQL_DATADIR"
  trap - ERR INT TERM
  exit 1
fi
log_msg "MySQL datadir exists and is readable: $MYSQL_DATADIR"

# Check 6: Verify MySQL connection
log_msg "Check 6/14: Testing MySQL connection..."
if ! test_mysql_connection; then
  log_error "Cannot connect to MySQL with provided credentials"
  log_error "User: $MYSQL_USER"
  trap - ERR INT TERM
  exit 1
fi
log_msg "MySQL connection successful"

# Check 7: Verify backup directory is writable
log_msg "Check 7/14: Verifying backup directory is writable..."
if ! validate_writable "$BACKUP_BASE"; then
  log_error "Backup directory is not writable: $BACKUP_BASE"
  trap - ERR INT TERM
  exit 1
fi
log_msg "Backup directory is writable"

# Check 8: Verify archive directory is writable
log_msg "Check 8/14: Verifying archive directory is writable..."
if ! validate_writable "$ARCHIVE_DIR"; then
  log_error "Archive directory is not writable: $ARCHIVE_DIR"
  trap - ERR INT TERM
  exit 1
fi
log_msg "Archive directory is writable"

# Check 9: Check available disk space
log_msg "Check 9/14: Checking available disk space..."
MYSQL_SIZE=$(get_mysql_data_size_gb)
BACKUP_FREE_SPACE=$(get_free_space_gb "$BACKUP_BASE")
ARCHIVE_FREE_SPACE=$(get_free_space_gb "$ARCHIVE_DIR")

log_msg "MySQL data size: ${MYSQL_SIZE}GB"
log_msg "Free space in $BACKUP_BASE: ${BACKUP_FREE_SPACE}GB"
log_msg "Free space in $ARCHIVE_DIR: ${ARCHIVE_FREE_SPACE}GB"

# Estimate required space (data size * 2 for temporary backup + compression)
REQUIRED_BACKUP_SPACE=$((MYSQL_SIZE * 2))
REQUIRED_ARCHIVE_SPACE=$((MYSQL_SIZE * 2))

if [[ $BACKUP_FREE_SPACE -lt $REQUIRED_BACKUP_SPACE ]]; then
  log_error "Insufficient space in $BACKUP_BASE"
  log_error "Required: ${REQUIRED_BACKUP_SPACE}GB, Available: ${BACKUP_FREE_SPACE}GB"
  trap - ERR INT TERM
  exit 1
fi

if [[ $ARCHIVE_FREE_SPACE -lt $REQUIRED_ARCHIVE_SPACE ]]; then
  log_error "Insufficient space in $ARCHIVE_DIR"
  log_error "Required: ${REQUIRED_ARCHIVE_SPACE}GB, Available: ${ARCHIVE_FREE_SPACE}GB"
  trap - ERR INT TERM
  exit 1
fi

log_msg "Sufficient disk space available"

# Check 10: Verify no other backup is running
log_msg "Check 10/14: Checking for concurrent backups..."
if pgrep -f "xtrabackup.*--backup" >/dev/null 2>&1; then
  log_error "Another xtrabackup process is already running"
  trap - ERR INT TERM
  exit 1
fi
log_msg "No concurrent backups detected"

# Check 11: Verify MySQL has binary logging enabled
log_msg "Check 11/14: Verifying binary logging is enabled..."
BINLOG_STATUS=$("$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -NBe "SELECT @@log_bin" 2>/dev/null || echo "0")
if [[ "$BINLOG_STATUS" != "1" ]]; then
  log_warn "Binary logging is not enabled. Point-in-time recovery will not be possible."
else
  log_msg "Binary logging is enabled"
fi

# Check 12: Verify target directory is empty
log_msg "Check 12/14: Verifying target directory is empty..."
if [[ -n "$(ls -A "$TARGET_DIR" 2>/dev/null)" ]]; then
  log_error "Target directory is not empty: $TARGET_DIR"
  trap - ERR INT TERM
  exit 1
fi
log_msg "Target directory is empty"

# Check 13: Test tar and gzip functionality
log_msg "Check 13/14: Testing compression utilities..."
TEST_FILE="$TARGET_DIR/.test_$$"
echo "test" > "$TEST_FILE"
if ! tar -czf "$TARGET_DIR/.test.tar.gz" -C "$TARGET_DIR" "$(basename "$TEST_FILE")" 2>/dev/null; then
  log_error "tar/gzip test failed"
  trap - ERR INT TERM
  exit 1
fi
rm -f "$TEST_FILE" "$TARGET_DIR/.test.tar.gz"
log_msg "Compression utilities working"

# Check 14: Test sha256sum functionality
log_msg "Check 14/14: Testing SHA-256 checksum utility..."
TEST_FILE="$TARGET_DIR/.sha256_test_$$"
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
  echo "FULL BACKUP STARTED"
  echo "Start time     : $START_TIME"
  echo "Backup dir     : $TARGET_DIR"
  echo "Final file     : $COMPRESSED_FILE"
  echo "Checksum file  : $CHECKSUM_FILE"
  echo "Binlog info    : $BINLOG_INFO_FILE"
  echo "Datadir        : $MYSQL_DATADIR"
  echo "MySQL user     : $MYSQL_USER"
  echo "Parallel       : $PARALLEL_THREADS threads"
  echo "Lock file      : $LOCK_FILE"
  echo "MySQL size     : ${MYSQL_SIZE}GB"
  echo "===================================================="
  echo ""
} | tee -a "$RUN_LOG"

############################
# CREATE LOCK FILE
# Created after pre-flight checks pass.
# Tells binlog_collect to skip while backup is running.
# ALWAYS removed — via cleanup_on_error on failure, explicitly on success.
############################

log_msg "Creating lock file: $LOCK_FILE"
echo "$$" > "$LOCK_FILE"
log_msg "Lock file created (PID: $$)"

############################
# STEP 1: CREATE BACKUP
############################

log_msg "[Step 1/7] Creating backup with xtrabackup..."

set +e
"$XTRABACKUP_BIN" \
  --backup \
  --user="$MYSQL_USER" \
  --password="$MYSQL_PASSWORD" \
  --datadir="$MYSQL_DATADIR" \
  --parallel="$PARALLEL_THREADS" \
  --target-dir="$TARGET_DIR" \
  2>&1 | tee -a "$XTRABACKUP_LOG"

BACKUP_STATUS=${PIPESTATUS[0]}
set -e

if [[ $BACKUP_STATUS -ne 0 ]]; then
  log_error "xtrabackup --backup failed (exit code: $BACKUP_STATUS)"
  cat "$XTRABACKUP_LOG" >> "$ERROR_LOG"
  exit 1
fi

# Verify backup files were created
if [[ ! -f "$TARGET_DIR/xtrabackup_checkpoints" ]]; then
  log_error "xtrabackup_checkpoints file not found in backup"
  exit 1
fi

log_msg "Backup created successfully"

############################
# STEP 2: VALIDATE BACKUP INTEGRITY
############################

log_msg "[Step 2/7] Validating backup integrity..."

# Check if critical files exist
CRITICAL_FILES=("xtrabackup_checkpoints" "xtrabackup_info" "backup-my.cnf")
for file in "${CRITICAL_FILES[@]}"; do
  if [[ ! -f "$TARGET_DIR/$file" ]]; then
    log_warn "Expected file not found: $file"
  fi
done

# Verify checkpoint type
CHECKPOINT_TYPE=$(grep "backup_type" "$TARGET_DIR/xtrabackup_checkpoints" | awk '{print $3}')
log_msg "Backup type: $CHECKPOINT_TYPE"

log_msg "Backup integrity validated"

############################
# STEP 3: PREPARE BACKUP
############################

log_msg "[Step 3/7] Preparing backup..."

# Ensure ownership before prepare
log_msg "Setting ownership on backup files..."
if ! chown -R mysql:mysql "$TARGET_DIR" 2>>"$ERROR_LOG"; then
  log_warn "Failed to change ownership, continuing anyway..."
fi

set +e
"$XTRABACKUP_BIN" \
  --prepare \
  --target-dir="$TARGET_DIR" \
  2>&1 | tee -a "$XTRABACKUP_LOG"

PREPARE_STATUS=${PIPESTATUS[0]}
set -e

if [[ $PREPARE_STATUS -ne 0 ]]; then
  log_error "xtrabackup --prepare failed (exit code: $PREPARE_STATUS)"
  cat "$XTRABACKUP_LOG" >> "$ERROR_LOG"
  exit 1
fi

# Verify prepare was successful
if ! grep -q "completed OK!" "$XTRABACKUP_LOG"; then
  log_error "xtrabackup prepare did not complete successfully"
  exit 1
fi

log_msg "Backup prepared successfully"

############################
# STEP 4: COPY BINLOG INFO
############################

log_msg "[Step 4/7] Extracting binlog information..."

# Check for binlog info file
if [[ -f "${TARGET_DIR}/xtrabackup_binlog_info" ]]; then
  cp "${TARGET_DIR}/xtrabackup_binlog_info" "$BINLOG_INFO_FILE"

  # Validate binlog info content
  if [[ ! -s "$BINLOG_INFO_FILE" ]]; then
    log_error "Binlog info file is empty"
    exit 1
  fi

  BINLOG_NAME=$(awk '{print $1}' "$BINLOG_INFO_FILE")
  BINLOG_POS=$(awk '{print $2}' "$BINLOG_INFO_FILE")

  if [[ -z "$BINLOG_NAME" || -z "$BINLOG_POS" ]]; then
    log_error "Invalid binlog info format"
    exit 1
  fi

  log_msg "Binlog position: $BINLOG_NAME:$BINLOG_POS"
  log_msg "Binlog info saved to: $BINLOG_INFO_FILE"
else
  log_warn "xtrabackup_binlog_info not found (binlog may not be enabled)"
    # Create empty binlog info file to prevent restore issues
  echo "unknown 0" > "$BINLOG_INFO_FILE"
  BINLOG_NAME="unknown"
  BINLOG_POS="0"
fi

############################
# STEP 5: COMPRESS BACKUP
############################

log_msg "[Step 5/7] Compressing backup..."

# Record uncompressed size
UNCOMPRESSED_SIZE=$(du -sh "$TARGET_DIR" | awk '{print $1}')
log_msg "Uncompressed size: $UNCOMPRESSED_SIZE"

# Compress with progress monitoring
if ! tar -czf "$COMPRESSED_FILE" -C "$BACKUP_BASE" "$(basename "$TARGET_DIR")" 2>>"$ERROR_LOG"; then
  log_error "Compression failed"
  exit 1
fi

# Verify compressed file was created and has size
if [[ ! -f "$COMPRESSED_FILE" ]]; then
  log_error "Compressed file was not created"
  exit 1
fi

COMPRESSED_SIZE=$(stat -c%s "$COMPRESSED_FILE" 2>/dev/null || echo "0")
if [[ "$COMPRESSED_SIZE" -eq 0 ]]; then
  log_error "Compressed file is empty"
  exit 1
fi

COMPRESSED_SIZE_HUMAN=$(du -sh "$COMPRESSED_FILE" | awk '{print $1}')
log_msg "Compressed size: $COMPRESSED_SIZE_HUMAN"

# Calculate compression ratio
UNCOMPRESSED_BYTES=$(du -sb "$TARGET_DIR" | awk '{print $1}')
if [[ "$UNCOMPRESSED_BYTES" -gt 0 ]]; then
  COMPRESSION_RATIO=$(echo "scale=1; ($COMPRESSED_SIZE * 100) / $UNCOMPRESSED_BYTES" | bc 2>/dev/null || echo "N/A")
else
  COMPRESSION_RATIO="N/A"
fi
log_msg "Compression ratio: ${COMPRESSION_RATIO}%"

############################
# STEP 6: GENERATE & VERIFY SHA-256 CHECKSUM
############################

log_msg "[Step 6/7] Generating and verifying SHA-256 checksum..."

# Generate SHA-256 checksum for the compressed backup
if ! sha256sum "$COMPRESSED_FILE" > "$CHECKSUM_FILE" 2>>"$ERROR_LOG"; then
  log_error "Failed to generate SHA-256 checksum"
  exit 1
fi

# Verify checksum file was created and is not empty
if [[ ! -s "$CHECKSUM_FILE" ]]; then
  log_error "SHA-256 checksum file is empty or was not created"
  exit 1
fi

BACKUP_SHA256=$(awk '{print $1}' "$CHECKSUM_FILE")
log_msg "SHA-256 checksum: $BACKUP_SHA256"
log_msg "Checksum file: $CHECKSUM_FILE"

# Immediately verify the checksum we just generated
log_msg "Verifying generated checksum against compressed archive..."
CURRENT_DIR="$(pwd)"
cd "$(dirname "$COMPRESSED_FILE")"
if ! sha256sum -c "$CHECKSUM_FILE" >/dev/null 2>>"$ERROR_LOG"; then
  cd "$CURRENT_DIR"
  log_error "SHA-256 checksum verification failed - compressed archive may be corrupted"
  exit 1
fi
cd "$CURRENT_DIR"
log_msg "SHA-256 checksum verified successfully - archive integrity confirmed"

############################
# STEP 7: MOVE TO ARCHIVE
############################

log_msg "[Step 7/7] Moving backup to archive directory..."

# Move compressed file
if ! mv "$COMPRESSED_FILE" "$ARCHIVE_DIR/" 2>>"$ERROR_LOG"; then
  log_error "Failed to move compressed file to $ARCHIVE_DIR"
  exit 1
fi

# Move checksum file
if ! mv "$CHECKSUM_FILE" "$ARCHIVE_DIR/" 2>>"$ERROR_LOG"; then
  log_error "Failed to move checksum file to $ARCHIVE_DIR"
  exit 1
fi

# Move binlog info
if ! mv "$BINLOG_INFO_FILE" "$ARCHIVE_DIR/" 2>>"$ERROR_LOG"; then
  log_error "Failed to move binlog info to $ARCHIVE_DIR"
  exit 1
fi

# Update paths after move
COMPRESSED_FILE="$ARCHIVE_DIR/$(basename "$COMPRESSED_FILE")"
CHECKSUM_FILE="$ARCHIVE_DIR/$(basename "$CHECKSUM_FILE")"
BINLOG_INFO_FILE="$ARCHIVE_DIR/$(basename "$BINLOG_INFO_FILE")"

# Verify files in archive
if [[ ! -f "$COMPRESSED_FILE" || ! -f "$CHECKSUM_FILE" || ! -f "$BINLOG_INFO_FILE" ]]; then
  log_error "Files not found in archive after move"
  exit 1
fi

# Re-verify SHA-256 checksum after move (update path inside checksum file)
log_msg "Updating checksum file with new path..."
BACKUP_SHA256=$(awk '{print $1}' "$CHECKSUM_FILE")
echo "$BACKUP_SHA256  $COMPRESSED_FILE" > "$CHECKSUM_FILE"

log_msg "Verifying checksum after move..."
if ! sha256sum -c "$CHECKSUM_FILE" >/dev/null 2>>"$ERROR_LOG"; then
  log_error "SHA-256 checksum verification failed after move to archive"
  exit 1
fi
log_msg "Post-move checksum verification passed"

log_msg "Backup moved to archive: $ARCHIVE_DIR"

############################
# CLEANUP
############################

log_msg "Cleaning up temporary files..."

# Remove uncompressed backup directory
if ! rm -rf "$TARGET_DIR" 2>>"$ERROR_LOG"; then
  log_warn "Failed to remove temporary backup directory: $TARGET_DIR"
else
  log_msg "Temporary files removed"
fi

############################
# FINAL VALIDATION
############################

log_msg "Performing final validation..."

# Ensure final files are readable
if [[ ! -r "$COMPRESSED_FILE" ]]; then
  log_error "Final backup file is not readable"
  exit 1
fi

if [[ ! -r "$CHECKSUM_FILE" ]]; then
  log_error "Final checksum file is not readable"
  exit 1
fi

if [[ ! -r "$BINLOG_INFO_FILE" ]]; then
  log_error "Final binlog info file is not readable"
  exit 1
fi

# Final SHA-256 integrity check
log_msg "Final SHA-256 integrity verification..."
if ! sha256sum -c "$CHECKSUM_FILE" >/dev/null 2>>"$ERROR_LOG"; then
  log_error "Final SHA-256 checksum verification failed"
  exit 1
fi
log_msg "Final SHA-256 integrity check passed"

log_msg "Final validation passed"

############################
# LOG COMPLETE
############################

END_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
END_EPOCH="$(date +%s)"
DURATION=$((END_EPOCH - START_EPOCH))
DURATION_MIN=$((DURATION / 60))
DURATION_SEC=$((DURATION % 60))

BACKUP_SIZE=$(du -sh "$COMPRESSED_FILE" 2>/dev/null | awk '{print $1}')

# Read final binlog position
BINLOG_NAME=$(awk '{print $1}' "$BINLOG_INFO_FILE")
BINLOG_POS=$(awk '{print $2}' "$BINLOG_INFO_FILE")

{
  echo ""
  echo "===================================================="
  echo "FULL BACKUP COMPLETED SUCCESSFULLY"
  echo "===================================================="
  echo "Start time       : $START_TIME"
  echo "End time         : $END_TIME"
  echo "Duration         : ${DURATION_MIN}m ${DURATION_SEC}s"
  echo "Uncompressed     : $UNCOMPRESSED_SIZE"
  echo "Compressed       : $BACKUP_SIZE"
  echo "Compression      : ${COMPRESSION_RATIO}%"
  echo "Backup file      : $COMPRESSED_FILE"
  echo "Checksum file    : $CHECKSUM_FILE"
  echo "SHA-256          : $BACKUP_SHA256"
  echo "Binlog info      : $BINLOG_INFO_FILE"
  echo "Binlog position  : $BINLOG_NAME:$BINLOG_POS"
  echo "Parallel threads : $PARALLEL_THREADS"
  echo "===================================================="
  echo "Log files:"
  echo "  Main log       : $RUN_LOG"
  echo "  XtraBackup log : $XTRABACKUP_LOG"
  echo "  Error log      : $ERROR_LOG"
  echo "===================================================="
} | tee -a "$RUN_LOG"

############################
# REMOVE LOCK FILE
# Backup fully complete. Removed here on success.
# On failure it is removed inside cleanup_on_error above.
############################

log_msg "Removing lock file: $LOCK_FILE"
rm -f "$LOCK_FILE" 2>/dev/null || true
log_msg "Lock file removed"

############################
# POST-BACKUP BINLOG COLLECTION
# Immediately collect binlogs generated during the backup window so
# we do not wait up to 30 minutes for the next cron fire.
############################

log_msg "===================================================="
log_msg "Post-backup binlog collection starting..."
log_msg "===================================================="

if [[ ! -x "$BINLOG_SCRIPT" ]]; then
  log_warn "Binlog script not found or not executable: $BINLOG_SCRIPT"
  log_warn "Binlog collection skipped — cron will collect at next 30-min interval"
else
  if "$BINLOG_SCRIPT" >> "$RUN_LOG" 2>&1; then
    log_msg "Post-backup binlog collection completed successfully"
  else
    log_warn "Post-backup binlog collection failed — cron will retry at next 30-min interval"
  fi
fi

############################
# RETENTION CLEANUP
############################

log_msg "===================================================="
log_msg "Retention cleanup starting..."
log_msg "===================================================="

if [[ ! -x "$DELETE_SCRIPT" ]]; then
  log_warn "Delete script not found or not executable: $DELETE_SCRIPT"
  log_warn "Retention cleanup skipped — run manually if needed"
else
  if "$DELETE_SCRIPT" >> "$RUN_LOG" 2>&1; then
    log_msg "Retention cleanup completed successfully"
  else
    log_warn "Retention cleanup finished with errors — check delete log for details"
  fi
fi

trap - ERR INT TERM

exit 0
