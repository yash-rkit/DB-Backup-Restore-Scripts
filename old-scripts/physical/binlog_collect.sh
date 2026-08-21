#!/usr/bin/env bash
set -euo pipefail

############################
# CONFIGURATION
############################

# MySQL credentials
MYSQL_USER="Admin"
MYSQL_PASSWORD=""

# NFS-mounted backup root — must match BACKUP_BASE in backup.sh.
# The lock file and the *_binlog_info anchor both live here, and binlogs are
# collected here too. Nothing in this script reads from secondary storage:
# backup.sh only transfers the .tar.gz there, never the binlog info or binlogs.
BACKUP_BASE="/dbbackup/test_cloud_db"

# Directory to store collected binlogs
BINLOG_ARCHIVE_BASE="${BACKUP_BASE}/binlog"

# MySQL binlog location (base name without extension)
BINLOG_BASE="/Data/mysql/binlog"

# MySQL client binary
MYSQL_BIN="/usr/bin/mysql"

# Stale lock threshold in seconds (6 hours)
# If lock is older than this, backup.sh likely crashed — proceed anyway
LOCK_STALE_SECONDS=21600

############################
# NFS REACHABILITY CHECK
# Must run BEFORE the lock check. A `[[ -f "$LOCK_FILE" ]]` test on an
# unreachable NFS mount returns false, which would look identical to
# "no backup running" and let us collect binlogs during a live backup.
# It would also make the *_binlog_info lookup find nothing and exit 0,
# silently collecting no binlogs at all. Fail loudly instead.
############################

if [[ ! -d "$BACKUP_BASE" ]]; then
  echo "[$(date '+%F %T')] [ERROR] Backup base not accessible: $BACKUP_BASE" >&2
  echo "[$(date '+%F %T')] [ERROR] NFS mount may be down. Refusing to run — cannot verify backup lock." >&2
  exit 1
fi

if ! ls "$BACKUP_BASE" >/dev/null 2>&1; then
  echo "[$(date '+%F %T')] [ERROR] Backup base not readable (stale NFS handle?): $BACKUP_BASE" >&2
  echo "[$(date '+%F %T')] [ERROR] Refusing to run — cannot verify backup lock." >&2
  exit 1
fi

############################
# LOCK FILE CHECK
# If backup is running, skip this run entirely.
# If lock is stale (> 6 hours), backup.sh likely crashed — warn and proceed.
############################

TODAY_LOCK="$(date +%Y%m%d)"
LOCK_FILE="${BACKUP_BASE}/${TODAY_LOCK}_lock"

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

# Initialize variables that might be used in cleanup before they're set
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

# Timestamped log function
log_msg() {
  if [[ -n "$RUN_LOG" && -d "$(dirname "$RUN_LOG")" ]]; then
    echo "[$(date '+%F %T')] [INFO] $1" | tee -a "$RUN_LOG"
  else
    echo "[$(date '+%F %T')] [INFO] $1"
  fi
}

# Log error function
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

# Log warning function
log_warn() {
  if [[ -n "$RUN_LOG" && -d "$(dirname "$RUN_LOG")" ]]; then
    echo "[$(date '+%F %T')] [WARN] $1" | tee -a "$RUN_LOG"
  else
    echo "[$(date '+%F %T')] [WARN] $1"
  fi
}

# Cleanup function on error
cleanup_on_error() {
  log_error "Binlog collection failed. Cleaning up..."

  # Only remove state file if WE created it this run (it did not exist before)
  if [[ "$STATE_FILE_PRE_EXISTED" == false && -n "${STATE_FILE:-}" && -f "$STATE_FILE" ]]; then
    log_msg "Removing newly created state file: $STATE_FILE"
    rm -f "$STATE_FILE" 2>/dev/null || true
  else
    log_msg "Preserving pre-existing state file: $STATE_FILE"
  fi

  # Remove any partially copied binlog file
  if [[ -n "${CURRENT_COPYING_FILE:-}" && -f "$TARGET_BINLOG_DIR/$CURRENT_COPYING_FILE" ]]; then
    log_msg "Removing partially copied file: $CURRENT_COPYING_FILE"
    rm -f "$TARGET_BINLOG_DIR/$CURRENT_COPYING_FILE" 2>/dev/null || true
  fi

  log_error "Binlog collection aborted. Check logs: ${RUN_LOG:-'(not initialized)'}"
    
  # Remove trap before exiting
  trap - ERR INT TERM
  exit 1
}

# Set trap for cleanup on error
trap cleanup_on_error ERR INT TERM

# MySQL command wrapper with credentials
mysql_cmd() {
  "$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$@"
}

# Test MySQL connection
test_mysql_connection() {
  if ! mysql_cmd -e "SELECT 1" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# Get current binlog status (compatible with all MySQL versions)
get_current_binlog() {
  local result
  result=$(mysql_cmd -NBe "SHOW BINARY LOG STATUS" 2>/dev/null | awk '{print $1}') || \
  result=$(mysql_cmd -NBe "SHOW MASTER STATUS" 2>/dev/null | awk '{print $1}')
  echo "$result"
}

# Check if file is an actual binlog (not index or other files)
is_binlog_file() {
  local filename="$1"
  # Binlog files end with .NNNNNN (6 digits)
  if [[ "$filename" =~ \.[0-9]{6}$ ]]; then
    return 0
  else
    return 1
  fi
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

# Get free space in GB
get_free_space_gb() {
  local path="$1"
  df -BG "$path" | awk 'NR==2 {print $4}' | sed 's/G//'
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

# Estimate binlog directory size in GB
get_binlog_size_gb() {
  local binlog_dir="$1"
  du -sb "$binlog_dir" 2>/dev/null | awk '{print int($1/1024/1024/1024)+1}'
}

# Format file size for display
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

# How far back to search for a binlog_info file.
# Set to 7 to support weekly full-backup schedules.
MAX_LOOKBACK_DAYS=3

BINLOG_INFO_FILE=""
BINLOG_INFO_SOURCE=""

for i in $(seq 0 "$MAX_LOOKBACK_DAYS"); do
  CANDIDATE_DATE="$(date -d "-${i} days" +%Y%m%d)"
  CANDIDATE_FILE="${BACKUP_BASE}/${CANDIDATE_DATE}_binlog_info"

  if [[ -f "$CANDIDATE_FILE" ]]; then
    BINLOG_INFO_FILE="$CANDIDATE_FILE"
    BINLOG_INFO_SOURCE="$(date -d "-${i} days" '+%A, %Y-%m-%d') (${i} day(s) ago)"
    break
  fi
done

if [[ -z "$BINLOG_INFO_FILE" ]]; then
  echo "[$(date '+%F %T')] [INFO] No binlog_info file found in the last ${MAX_LOOKBACK_DAYS} days." >&2
  echo "[$(date '+%F %T')] [INFO] Backup has likely not completed yet. Nothing to collect. Exiting cleanly." >&2
  exit 0
fi

REFERENCE_DATE="$(basename "$BINLOG_INFO_FILE" | grep -oP '^\d{8}')"
TARGET_BINLOG_DIR="${BINLOG_ARCHIVE_BASE}/${REFERENCE_DATE}"
STATE_FILE="${TARGET_BINLOG_DIR}/last_copied_binlog"

# Log files
RUN_LOG="${TARGET_BINLOG_DIR}/binlog_collect.log"
ERROR_LOG="${TARGET_BINLOG_DIR}/binlog_collect_errors.log"

# Timestamps for duration tracking
START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
START_EPOCH="$(date +%s)"

# Binlog directory (derived once, used throughout)
BINLOG_DIR="$(dirname "$BINLOG_BASE")"

############################
# STATE FILE PRE-EXISTENCE CHECK
# IMPORTANT: Must be placed here — AFTER STATE_FILE is defined above.
# In the original script this was placed before DERIVED PATHS where
# STATE_FILE was still "", so it was always false. That caused
# cleanup_on_error to always delete the state file even when it
# existed from a previous successful run.
############################

STATE_FILE_PRE_EXISTED=false
if [[ -f "$STATE_FILE" ]]; then
  STATE_FILE_PRE_EXISTED=true
fi

############################
# SETUP
############################

# Create target directory with error handling
if ! mkdir -p "$TARGET_BINLOG_DIR" 2>/dev/null; then
  echo "[$(date '+%F %T')] [ERROR] Failed to create target directory: $TARGET_BINLOG_DIR" >&2
  trap - ERR INT TERM
  exit 1
fi

# Initialize error log
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

# Check 1: Verify running as root or with sufficient privileges
log_msg "Check 1/10: Verifying user privileges..."
if [[ $EUID -ne 0 ]]; then
  log_warn "Not running as root. Ensure user has sufficient privileges."
else
  log_msg "Running as root"
fi

# Check 2: Verify required commands exist
log_msg "Check 2/10: Verifying required binaries..."
REQUIRED_COMMANDS=(awk cp du df find basename dirname grep wc stat sync)
for cmd in "${REQUIRED_COMMANDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "Required command not found: $cmd"
    trap - ERR INT TERM
    exit 1
  fi
done

# Verify MySQL binary is executable
if [[ ! -x "$MYSQL_BIN" ]]; then
  log_error "MySQL binary not executable: $MYSQL_BIN"
  trap - ERR INT TERM
  exit 1
fi

log_msg "All required binaries found"

# Check 3: Verify MySQL is running
log_msg "Check 3/10: Verifying MySQL is running..."
if ! is_mysql_running; then
  log_error "MySQL is not running"
  trap - ERR INT TERM
  exit 1
fi
log_msg "MySQL is running"

# Check 4: Verify MySQL connection
log_msg "Check 4/10: Testing MySQL connection..."
if ! test_mysql_connection; then
  log_error "Cannot connect to MySQL with provided credentials"
  log_error "User: $MYSQL_USER"
  trap - ERR INT TERM
  exit 1
fi
log_msg "MySQL connection successful"

# Check 5: Verify binlog is enabled
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
BINLOG_COUNT=$(find "$BINLOG_DIR" -name "${BINLOG_PREFIX}.*" -type f 2>/dev/null | wc -l)

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

  # Validate state file content
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

# Validate start binlog format
if ! is_binlog_file "$START_BINLOG"; then
  log_error "Invalid start binlog format: $START_BINLOG"
  trap - ERR INT TERM
  exit 1
fi

log_msg "Start binlog validated: $START_BINLOG"

############################
# PURGED BINLOG FALLBACK
# If the start binlog no longer exists on disk (MySQL purged it),
# fall back to the earliest available binlog instead of aborting.
# Partial recovery is always better than no collection at all.
# To prevent this: set binlog_expire_logs_seconds in MySQL config
# to at least 3x your longest backup duration.
############################

BINLOG_PREFIX="$(basename "$BINLOG_BASE")"

if [[ ! -f "$BINLOG_DIR/$START_BINLOG" ]]; then
  log_warn "CRITICAL: Start binlog not found on disk — may have been purged by MySQL: $START_BINLOG"
  log_warn "CRITICAL: Recommendation — set binlog_expire_logs_seconds >= 3x your backup duration in MySQL config"

  EARLIEST_BINLOG=$(find "$BINLOG_DIR" -name "${BINLOG_PREFIX}.*" -type f 2>/dev/null | sort | head -1 | xargs basename 2>/dev/null || echo "")

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

# Rotate to new binlog so current one is safe to copy
if ! mysql_cmd -e "FLUSH BINARY LOGS;" 2>>"$ERROR_LOG"; then
  log_error "Failed to flush binary logs"
  trap - ERR INT TERM
  exit 1
fi

# Ensure filesystem sync
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

# Validate current binlog format
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

# Variable to track currently copying file for cleanup
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

# Process sorted binlog files
for BINLOG_FILE in "${BINLOG_FILES[@]}"; do
  BINLOG_PATH="$BINLOG_DIR/$BINLOG_FILE"

  # Skip non-binlog files
  if ! is_binlog_file "$BINLOG_FILE"; then
    continue
  fi

  # Find starting point
  if [[ "$BINLOG_FILE" == "$START_BINLOG" ]]; then
    FOUND_START=true
    log_msg "Found start binlog: $BINLOG_FILE"
  fi

  # Skip files before start point
  if [[ "$FOUND_START" != true ]]; then
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    continue
  fi

  # Skip current active binlog
  if [[ "$BINLOG_FILE" == "$CURRENT_BINLOG" ]]; then
    log_msg "Skipping active binlog: $BINLOG_FILE"
    continue
  fi

  # Check if already copied
  if [[ -f "$TARGET_BINLOG_DIR/$BINLOG_FILE" ]]; then
    log_msg "Already exists, skipping: $BINLOG_FILE"
    continue
  fi

  # Verify source file exists and is readable
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

 # Get source file size
  SOURCE_SIZE=$(stat -c%s "$BINLOG_PATH" 2>/dev/null || echo "0")

  if [[ "$SOURCE_SIZE" -eq 0 ]]; then
    log_warn "Source file is empty, skipping: $BINLOG_FILE"
    continue
  fi

  log_msg "Copying binlog: $BINLOG_FILE ($(format_size "$SOURCE_SIZE"))"

  # Track current file being copied for cleanup
  CURRENT_COPYING_FILE="$BINLOG_FILE"

  # Copy with verification
  if ! cp -p "$BINLOG_PATH" "$TARGET_BINLOG_DIR/" 2>>"$ERROR_LOG"; then
    log_error "Failed to copy $BINLOG_FILE"
    rm -f "$TARGET_BINLOG_DIR/$BINLOG_FILE" 2>/dev/null || true
    CURRENT_COPYING_FILE=""
    ERROR_COUNT=$((ERROR_COUNT + 1))
    continue
  fi

  # Verify copied file
  if [[ ! -f "$TARGET_BINLOG_DIR/$BINLOG_FILE" ]]; then
    log_error "Copied file not found after copy: $BINLOG_FILE"
    CURRENT_COPYING_FILE=""
    ERROR_COUNT=$((ERROR_COUNT + 1))
    continue
  fi

  # Verify file size matches
  DEST_SIZE=$(stat -c%s "$TARGET_BINLOG_DIR/$BINLOG_FILE" 2>/dev/null || echo "0")

  if [[ "$SOURCE_SIZE" -ne "$DEST_SIZE" ]]; then
    log_error "Size mismatch for $BINLOG_FILE (source: $SOURCE_SIZE, dest: $DEST_SIZE)"
    rm -f "$TARGET_BINLOG_DIR/$BINLOG_FILE"
    CURRENT_COPYING_FILE=""
    ERROR_COUNT=$((ERROR_COUNT + 1))
    continue
  fi

  # Clear current copying file tracker
  CURRENT_COPYING_FILE=""
  
  # Update state file after successful copy
  echo "$BINLOG_FILE" > "$STATE_FILE"
  COPIED_COUNT=$((COPIED_COUNT + 1))

  log_msg "Successfully copied: $BINLOG_FILE"
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

if [[ $ERROR_COUNT -gt 0 ]]; then
  log_warn "Encountered $ERROR_COUNT error(s) during collection"
fi

log_msg "Validation completed"

############################
# SUMMARY
############################

TOTAL_BINLOGS=$(find "$TARGET_BINLOG_DIR" -type f -name "${BINLOG_PREFIX}.*" 2>/dev/null | wc -l)
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

# Remove trap since we succeeded
trap - ERR INT TERM

exit 0