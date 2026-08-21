#!/usr/bin/env bash
#
# server/physical/backup.sh — standalone XtraBackup full backup, SMB/CIFS storage
#
# Docs: instructions/server/physical/README.md
#
set -euo pipefail

############################
# CONFIGURATION
############################

# MySQL credentials
MYSQL_USER="Admin"
MYSQL_PASSWORD=""

# LOCAL staging — must be local disk, never a CIFS path. Needs ~1.5x the MySQL
# data size. Emptied at the end of every run, success or failure.
BACKUP_BASE="/Data/dbvault-stage"

# Staging space required, as a percentage of the MySQL data size (150 = 1.5x).
# Raise it if the data compresses poorly.
LOCAL_SPACE_PCT=150

XTRABACKUP_BIN="/usr/bin/xtrabackup"

MYSQL_DATADIR="/Data/mysql"

PARALLEL_THREADS=2

# SMB/CIFS share — REQUIRED, the permanent home for every artifact.
SECONDARY_STORAGE_DIR="/livestorage/YK/Restore-VM"

# The CIFS MOUNT POINT itself, usually a PARENT of the directory above.
# `mountpoint -q` only returns true for the exact mount point, never a
# subdirectory of it. Set both the same if the share is mounted directly.
SMB_MOUNT_POINT="/livestorage"

# Backup lock — LOCAL to this VM, polled by binlog_collect.sh. Never put it on
# a network mount: a mount hiccup would read as "no backup running".
LOCK_DIR="/var/lock/dbvault"

MYSQL_BIN="/usr/bin/mysql"

# Run inline after the backup so PITR coverage starts immediately.
BINLOG_SCRIPT="/Data/script/binlog_collect.sh"

############################
# EARLY INITIALIZATION
############################

TARGET_DIR=""
COMPRESSED_FILE=""
CHECKSUM_FILE=""
BINLOG_INFO_FILE=""
MANIFEST_FILE=""
RUN_LOG=""
ERROR_LOG=""
UNCOMPRESSED_SIZE="N/A"
COMPRESSION_RATIO="N/A"
SECONDARY_FILE=""
TRANSFER_OK="no"

TODAY="$(date +%Y%m%d)"

# Secondary storage is REQUIRED in this model — it is the only permanent home.
if [[ -z "$SECONDARY_STORAGE_DIR" ]]; then
  echo "[$(date '+%F %T')] [ERROR] SECONDARY_STORAGE_DIR is empty — the backup has nowhere to go." >&2
  exit 1
fi

# Secondary inside scratch would make "publish then empty scratch" delete the
# only copy.
if [[ "$SECONDARY_STORAGE_DIR" == "$BACKUP_BASE"* ]]; then
  echo "[$(date '+%F %T')] [ERROR] SECONDARY_STORAGE_DIR is inside BACKUP_BASE — scratch is wiped after each run." >&2
  exit 1
fi

# Mount check, BEFORE anything reads or writes under the share — earlier than
# the numbered pre-flight checks, and duplicated by Check 8. See the README:
# on a dropped mount the collision test and `mkdir -p` both misbehave silently.
# Plain echo, not log_error: the run log does not exist yet.
#
# `mountpoint` is checked here rather than in Check 2's sweep, or its absence
# would surface below as a confusing "share is not mounted" (exit 127).
if ! command -v mountpoint >/dev/null 2>&1; then
  echo "[$(date '+%F %T')] [ERROR] Required command not found: mountpoint" >&2
  echo "[$(date '+%F %T')] [ERROR] It is part of util-linux and is required to verify the SMB share." >&2
  exit 1
fi

if ! mountpoint -q "$SMB_MOUNT_POINT"; then
  echo "[$(date '+%F %T')] [ERROR] SMB share is NOT mounted at: $SMB_MOUNT_POINT" >&2
  echo "[$(date '+%F %T')] [ERROR] Refusing to run. Backing up to the unmounted path would" >&2
  echo "[$(date '+%F %T')] [ERROR] write to the local root filesystem and eventually fill it." >&2
  exit 1
fi

# Date-prefixed so yesterday's lock never affects today. binlog_collect.sh
# polls this exact path. Always removed: on failure via the trap, on success
# at the end of the script.
mkdir -p "$LOCK_DIR" 2>/dev/null || true
LOCK_FILE="${LOCK_DIR}/$(basename "$BACKUP_BASE")_${TODAY}_lock"

############################
# HELPER FUNCTIONS
############################

log_msg() {
  if [[ -n "$RUN_LOG" && -w "$(dirname "$RUN_LOG")" ]]; then
    echo "[$(date '+%F %T')] [INFO] $1" | tee -a "$RUN_LOG"
  else
    echo "[$(date '+%F %T')] [INFO] $1"
  fi
}

log_error() {
  if [[ -n "$RUN_LOG" && -w "$(dirname "$RUN_LOG")" ]]; then
    echo "[$(date '+%F %T')] [ERROR] $1" | tee -a "$RUN_LOG" >&2
  else
    echo "[$(date '+%F %T')] [ERROR] $1" >&2
  fi
}

log_warn() {
  if [[ -n "$RUN_LOG" && -w "$(dirname "$RUN_LOG")" ]]; then
    echo "[$(date '+%F %T')] [WARN] $1" | tee -a "$RUN_LOG"
  else
    echo "[$(date '+%F %T')] [WARN] $1"
  fi
}

# Move this run's logs from scratch to SECONDARY/logs/<NAME>/. Called on both
# the success and failure paths. Best-effort: never fails the run. Uses plain
# echo, because afterwards RUN_LOG no longer exists on scratch.
PUBLISHED_LOGS=0
publish_logs() {
  [[ "$PUBLISHED_LOGS" == "1" ]] && return 0     # idempotent; only ever once
  PUBLISHED_LOGS=1
  [[ -n "${SECONDARY_LOG_DIR:-}" ]] || return 0

  mkdir -p "$SECONDARY_LOG_DIR" 2>/dev/null || {
    echo "[$(date '+%F %T')] [WARN] Cannot create log dir: $SECONDARY_LOG_DIR (logs remain on scratch)" >&2
    return 0
  }

  local src dst
  for pair in "${RUN_LOG}:backup.log" \
              "${XTRABACKUP_LOG}:xtrabackup.log" \
              "${ERROR_LOG}:errors.log"; do
    src="${pair%:*}"; dst="${pair##*:}"
    [[ -n "$src" && -f "$src" ]] || continue
    if ! mv "$src" "${SECONDARY_LOG_DIR}/${dst}" 2>/dev/null; then
      # mv can fail across filesystems; fall back to copy+remove.
      cp "$src" "${SECONDARY_LOG_DIR}/${dst}" 2>/dev/null && rm -f "$src" 2>/dev/null || true
    fi
  done

  echo "[$(date '+%F %T')] [INFO] Logs published to: $SECONDARY_LOG_DIR"
}

cleanup_on_error() {
  log_error "Backup failed. Cleaning up..."

  if [[ -f "$LOCK_FILE" ]]; then
    log_msg "Removing lock file on failure: $LOCK_FILE"
    rm -f "$LOCK_FILE" 2>/dev/null || true
  fi

  if [[ -n "${TARGET_DIR:-}" && -d "$TARGET_DIR" ]]; then
    log_msg "Removing incomplete backup directory: $TARGET_DIR"
    rm -rf "$TARGET_DIR" 2>/dev/null || true
  fi

  # Never delete an archive already copied to secondary and verified there.
  if [[ "${TRANSFER_OK:-no}" == "yes" ]]; then
    log_warn "Archive was already transferred and verified — keeping it: ${SECONDARY_FILE:-?}"
  elif [[ -n "${COMPRESSED_FILE:-}" && -f "$COMPRESSED_FILE" ]]; then
    log_msg "Removing incomplete compressed file: $COMPRESSED_FILE"
    rm -f "$COMPRESSED_FILE" 2>/dev/null || true
  fi

  if [[ -n "${SECONDARY_FILE:-}" && -f "${SECONDARY_FILE}.part" ]]; then
    log_msg "Removing partial transfer: ${SECONDARY_FILE}.part"
    rm -f "${SECONDARY_FILE}.part" 2>/dev/null || true
  fi

  if [[ -n "${CHECKSUM_FILE:-}" && -f "$CHECKSUM_FILE" ]]; then
    log_msg "Removing incomplete checksum file: $CHECKSUM_FILE"
    rm -f "$CHECKSUM_FILE" 2>/dev/null || true
  fi

  if [[ -n "${BINLOG_INFO_FILE:-}" && -f "$BINLOG_INFO_FILE" ]]; then
    log_msg "Removing incomplete binlog info: $BINLOG_INFO_FILE"
    rm -f "$BINLOG_INFO_FILE" 2>/dev/null || true
  fi

  # restore_full.sh trusts the manifest to decide whether the archive is
  # restorable, so a truncated one is worse than none.
  if [[ -n "${MANIFEST_FILE:-}" && -f "$MANIFEST_FILE" ]]; then
    log_msg "Removing incomplete manifest: $MANIFEST_FILE"
    rm -f "$MANIFEST_FILE" 2>/dev/null || true
  fi

  log_error "Backup aborted. Check logs: ${SECONDARY_LOG_DIR:-${RUN_LOG:-'(not initialized)'}}"

  # Last, so it captures the cleanup above.
  publish_logs

  trap - ERR INT TERM
  exit 1
}

trap cleanup_on_error ERR INT TERM

get_free_space_gb() {
  local path="$1"
  df -BG "$path" | awk 'NR==2 {print $4}' | sed 's/G//'
}

get_mysql_data_size_gb() {
  du -sb "$MYSQL_DATADIR" 2>/dev/null | awk '{print int($1/1024/1024/1024)+1}'
}

test_mysql_connection() {
  if ! "$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "SELECT 1" >/dev/null 2>&1; then
    return 1
  fi
  return 0
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

# `mountpoint -q`, not [[ -d ]]: a dropped CIFS mount reverts to a plain empty
# LOCAL directory that passes every -d test. The write probe then catches a
# mount that is still listed but dead (stale handle, expired credentials).
# Called in pre-flight and again before the transfer — the share can drop
# during a backup that runs for hours.
require_smb() {
  if ! mountpoint -q "$SMB_MOUNT_POINT"; then
    log_error "SMB share is NOT mounted at: $SMB_MOUNT_POINT"
    log_error "The path may still exist as an empty local directory — writing"
    log_error "there would fill the root filesystem instead of the NAS."
    return 1
  fi

  local probe="${SECONDARY_STORAGE_DIR}/.probe_$$"
  if ! touch "$probe" 2>/dev/null; then
    log_error "SMB share is mounted but NOT writable: $SECONDARY_STORAGE_DIR"
    log_error "Likely a stale handle or an authentication failure."
    log_error "Also check the mount's uid=/gid=/file_mode=/dir_mode= options."
    return 1
  fi
  rm -f "$probe" 2>/dev/null || true

  return 0
}

############################
# DERIVED PATHS
############################

# Base name for every artifact of this run: the run date, plus a time component
# on a same-day collision (20260711_143005).
NAME="${TODAY}"

# Raw backup directory (removed after compression)
TARGET_DIR="${BACKUP_BASE}/${NAME}"

# Built on scratch, then published to secondary
COMPRESSED_FILE="${BACKUP_BASE}/${NAME}.tar.gz"
CHECKSUM_FILE="${BACKUP_BASE}/${NAME}.sha256"

# The PITR anchor: readable without extracting the archive
BINLOG_INFO_FILE="${BACKUP_BASE}/${NAME}_binlog_info"

# Logs are WRITTEN to local staging during the run — a log living on the share
# is useless when that mount is the thing failing — then MOVED to
# SECONDARY/logs/<NAME>/ at the end, on success and on failure.
SECONDARY_LOG_DIR="${SECONDARY_STORAGE_DIR}/logs/${NAME}"

XTRABACKUP_LOG="${BACKUP_BASE}/${NAME}_xtrabackup.log"
RUN_LOG="${BACKUP_BASE}/${NAME}_backup.log"
ERROR_LOG="${BACKUP_BASE}/${NAME}_errors.log"

START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
START_EPOCH="$(date +%s)"

############################
# SETUP
############################

# Same-day collision check. SECONDARY is the authoritative test: scratch is
# wiped after every run, so only the published archive proves a same-day
# backup already exists.
if [[ -d "$TARGET_DIR" || -f "$COMPRESSED_FILE" \
      || -f "${SECONDARY_STORAGE_DIR}/${NAME}.tar.gz" ]]; then
  TIMESTAMP="$(date +%H%M%S)"
  NAME="${TODAY}_${TIMESTAMP}"
  TARGET_DIR="${BACKUP_BASE}/${NAME}"
  COMPRESSED_FILE="${BACKUP_BASE}/${NAME}.tar.gz"
  CHECKSUM_FILE="${BACKUP_BASE}/${NAME}.sha256"
  BINLOG_INFO_FILE="${BACKUP_BASE}/${NAME}_binlog_info"
  XTRABACKUP_LOG="${BACKUP_BASE}/${NAME}_xtrabackup.log"
  RUN_LOG="${BACKUP_BASE}/${NAME}_backup.log"
  ERROR_LOG="${BACKUP_BASE}/${NAME}_errors.log"
  # Re-derived too, or this rerun's logs land in the earlier run's folder.
  SECONDARY_LOG_DIR="${SECONDARY_STORAGE_DIR}/logs/${NAME}"
fi

CREATE_DIRS=("$BACKUP_BASE" "$SECONDARY_STORAGE_DIR" "$SECONDARY_LOG_DIR")

for dir in "${CREATE_DIRS[@]}"; do
  if [[ ! -d "$dir" ]]; then
    if ! mkdir -p "$dir" 2>/dev/null; then
      echo "[$(date '+%F %T')] [ERROR] Failed to create directory: $dir" >&2
      trap - ERR INT TERM
      exit 1
    fi
  fi
done

if ! mkdir -p "$TARGET_DIR" 2>/dev/null; then
  echo "[$(date '+%F %T')] [ERROR] Failed to create target directory: $TARGET_DIR" >&2
  trap - ERR INT TERM
  exit 1
fi

############################
# PRE-FLIGHT CHECKS
############################

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

log_msg "Check 1/14: Verifying user privileges..."
if [[ $EUID -ne 0 ]]; then
  log_warn "Not running as root. Ensure user has sufficient privileges."
else
  log_msg "Running as root"
fi

log_msg "Check 2/14: Verifying required binaries..."
REQUIRED_COMMANDS=(xtrabackup mysql tar gzip awk du df grep bc sha256sum mountpoint)
for cmd in "${REQUIRED_COMMANDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "Required command not found in PATH: $cmd"
    trap - ERR INT TERM
    exit 1
  fi
done
log_msg "All required binaries found"

log_msg "Check 3/14: Verifying xtrabackup version..."
XTRABACKUP_VERSION=$("$XTRABACKUP_BIN" --version 2>&1 | head -1)
log_msg "XtraBackup version: $XTRABACKUP_VERSION"

log_msg "Check 4/14: Verifying MySQL is running..."
if ! is_mysql_running; then
  log_error "MySQL is not running"
  trap - ERR INT TERM
  exit 1
fi
log_msg "MySQL is running"

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

log_msg "Check 6/14: Testing MySQL connection..."
if ! test_mysql_connection; then
  log_error "Cannot connect to MySQL with provided credentials"
  log_error "User: $MYSQL_USER"
  trap - ERR INT TERM
  exit 1
fi
log_msg "MySQL connection successful"

log_msg "Check 7/14: Verifying backup directory is writable..."
if ! validate_writable "$BACKUP_BASE"; then
  log_error "Backup directory is not writable: $BACKUP_BASE"
  trap - ERR INT TERM
  exit 1
fi
log_msg "Backup directory is writable"

# Check 8: fail here rather than after a long backup that has nowhere to go.
log_msg "Check 8/14: Verifying SMB share..."
if ! require_smb; then
  trap - ERR INT TERM
  exit 1
fi
log_msg "SMB share is mounted at $SMB_MOUNT_POINT and writable: $SECONDARY_STORAGE_DIR"

log_msg "Check 9/14: Checking available disk space..."
MYSQL_SIZE=$(get_mysql_data_size_gb)
BACKUP_FREE_SPACE=$(get_free_space_gb "$BACKUP_BASE")

log_msg "MySQL data size: ${MYSQL_SIZE}GB"
log_msg "Free space in $BACKUP_BASE (local staging): ${BACKUP_FREE_SPACE}GB"

# Rounded UP: an off-by-one GB here becomes ENOSPC hours into the run.
REQUIRED_BACKUP_SPACE=$(( (MYSQL_SIZE * LOCAL_SPACE_PCT + 99) / 100 ))

if [[ $BACKUP_FREE_SPACE -lt $REQUIRED_BACKUP_SPACE ]]; then
  log_error "Insufficient space in $BACKUP_BASE"
  log_error "Required: ${REQUIRED_BACKUP_SPACE}GB (${LOCAL_SPACE_PCT}% of ${MYSQL_SIZE}GB), Available: ${BACKUP_FREE_SPACE}GB"
  log_error "If your data compresses poorly, raise LOCAL_SPACE_PCT rather than ignoring this."
  trap - ERR INT TERM
  exit 1
fi

if [[ -n "$SECONDARY_STORAGE_DIR" ]]; then
  SECONDARY_FREE_SPACE=$(get_free_space_gb "$SECONDARY_STORAGE_DIR")
  log_msg "Free space in $SECONDARY_STORAGE_DIR: ${SECONDARY_FREE_SPACE}GB"

  if [[ $SECONDARY_FREE_SPACE -lt $MYSQL_SIZE ]]; then
    log_error "Insufficient space in $SECONDARY_STORAGE_DIR"
    log_error "Required: ${MYSQL_SIZE}GB, Available: ${SECONDARY_FREE_SPACE}GB"
    trap - ERR INT TERM
    exit 1
  fi
fi

log_msg "Sufficient disk space available"

log_msg "Check 10/14: Checking for concurrent backups..."
if pgrep -f "xtrabackup.*--backup" >/dev/null 2>&1; then
  log_error "Another xtrabackup process is already running"
  trap - ERR INT TERM
  exit 1
fi
log_msg "No concurrent backups detected"

log_msg "Check 11/14: Verifying binary logging is enabled..."
BINLOG_STATUS=$("$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -NBe "SELECT @@log_bin" 2>/dev/null || echo "0")
if [[ "$BINLOG_STATUS" != "1" ]]; then
  log_warn "Binary logging is not enabled. Point-in-time recovery will not be possible."
else
  log_msg "Binary logging is enabled"
fi

log_msg "Check 12/14: Verifying target directory is empty..."
if [[ -n "$(ls -A "$TARGET_DIR" 2>/dev/null)" ]]; then
  log_error "Target directory is not empty: $TARGET_DIR"
  trap - ERR INT TERM
  exit 1
fi
log_msg "Target directory is empty"

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
  echo "Local staging  : $BACKUP_BASE"
  echo "Backup dir     : $TARGET_DIR"
  echo "Final file     : $COMPRESSED_FILE"
  echo "Checksum file  : $CHECKSUM_FILE"
  echo "Binlog info    : $BINLOG_INFO_FILE"
  echo "Secondary      : $SECONDARY_STORAGE_DIR"
  echo "Log dir        : $SECONDARY_LOG_DIR"
  echo "Datadir        : $MYSQL_DATADIR"
  echo "MySQL user     : $MYSQL_USER"
  echo "Parallel       : $PARALLEL_THREADS threads"
  echo "Lock file      : $LOCK_FILE"
  echo "MySQL size     : ${MYSQL_SIZE}GB"
  echo "===================================================="
  echo ""
} | tee -a "$RUN_LOG"

############################
# CREATE LOCK FILE — tells binlog_collect.sh to skip while the backup runs
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

if [[ ! -f "$TARGET_DIR/xtrabackup_checkpoints" ]]; then
  log_error "xtrabackup_checkpoints file not found in backup"
  exit 1
fi

log_msg "Backup created successfully"

############################
# STEP 2: VALIDATE BACKUP INTEGRITY
############################

log_msg "[Step 2/7] Validating backup integrity..."

CRITICAL_FILES=("xtrabackup_checkpoints" "xtrabackup_info" "backup-my.cnf")
for file in "${CRITICAL_FILES[@]}"; do
  if [[ ! -f "$TARGET_DIR/$file" ]]; then
    log_warn "Expected file not found: $file"
  fi
done

CHECKPOINT_TYPE=$(grep "backup_type" "$TARGET_DIR/xtrabackup_checkpoints" | awk '{print $3}')
log_msg "Backup type: $CHECKPOINT_TYPE"

log_msg "Backup integrity validated"

############################
# STEP 3: PREPARE BACKUP
############################

log_msg "[Step 3/7] Preparing backup..."

# TARGET_DIR is local disk, so this is a real POSIX chown and is expected to
# succeed — precisely why the backup is staged locally rather than on the share.
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

# Counted, not grep -q: --backup and --prepare append to the same log, so the
# BACKUP phase's line satisfies a bare grep even when PREPARE failed outright.
COMPLETED_OK_COUNT=$(grep -c "completed OK!" "$XTRABACKUP_LOG" || true)
if [[ "${COMPLETED_OK_COUNT:-0}" -lt 2 ]]; then
  log_error "xtrabackup prepare did not complete successfully"
  log_error "Expected 2 'completed OK!' lines (backup + prepare), found: ${COMPLETED_OK_COUNT:-0}"
  exit 1
fi

# The authoritative check: --prepare rewrites backup_type from 'full-backuped'
# to 'full-prepared'. Nothing downstream re-runs --prepare, so an unprepared
# backup published here cannot be restored.
PREPARED_TYPE=$(awk '/backup_type/ {print $3}' "$TARGET_DIR/xtrabackup_checkpoints")
if [[ "$PREPARED_TYPE" != "full-prepared" ]]; then
  log_error "Expected backup_type 'full-prepared' after --prepare, got: '${PREPARED_TYPE:-(empty)}'"
  log_error "Refusing to publish an unprepared backup — starting MySQL on it would corrupt data."
  exit 1
fi

log_msg "Backup prepared successfully (backup_type: $PREPARED_TYPE)"

############################
# STEP 4: COPY BINLOG INFO
############################

log_msg "[Step 4/7] Extracting binlog information..."

if [[ -f "${TARGET_DIR}/xtrabackup_binlog_info" ]]; then
  cp "${TARGET_DIR}/xtrabackup_binlog_info" "$BINLOG_INFO_FILE"

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
  # Placeholder so the restore path always finds a file to read.
  echo "unknown 0" > "$BINLOG_INFO_FILE"
  BINLOG_NAME="unknown"
  BINLOG_POS="0"
fi

############################
# STEP 5: COMPRESS BACKUP
############################

log_msg "[Step 5/7] Compressing backup..."

UNCOMPRESSED_SIZE=$(du -sh "$TARGET_DIR" | awk '{print $1}')
log_msg "Uncompressed size: $UNCOMPRESSED_SIZE"

if ! tar -czf "$COMPRESSED_FILE" -C "$BACKUP_BASE" "$(basename "$TARGET_DIR")" 2>>"$ERROR_LOG"; then
  log_error "Compression failed"
  exit 1
fi

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

if ! sha256sum "$COMPRESSED_FILE" > "$CHECKSUM_FILE" 2>>"$ERROR_LOG"; then
  log_error "Failed to generate SHA-256 checksum"
  exit 1
fi

if [[ ! -s "$CHECKSUM_FILE" ]]; then
  log_error "SHA-256 checksum file is empty or was not created"
  exit 1
fi

BACKUP_SHA256=$(awk '{print $1}' "$CHECKSUM_FILE")
log_msg "SHA-256 checksum: $BACKUP_SHA256"
log_msg "Checksum file: $CHECKSUM_FILE"

# The checksum file records an absolute path, so this resolves from anywhere.
log_msg "Verifying generated checksum against compressed archive..."
if ! sha256sum -c "$CHECKSUM_FILE" >/dev/null 2>>"$ERROR_LOG"; then
  log_error "SHA-256 checksum verification failed - compressed archive may be corrupted"
  exit 1
fi
log_msg "SHA-256 checksum verified successfully - archive integrity confirmed"

############################
# CLEANUP UNCOMPRESSED BACKUP
# Before the transfer, so staging reclaims that space while the (slow) copy runs
############################

log_msg "Removing uncompressed backup directory..."

if ! rm -rf "$TARGET_DIR" 2>>"$ERROR_LOG"; then
  log_warn "Failed to remove uncompressed backup directory: $TARGET_DIR"
else
  TARGET_DIR=""
  log_msg "Uncompressed backup directory removed"
fi

############################
# STEP 7: PUBLISH TO SECONDARY STORAGE
# Copy, verify at the destination, then drop the local copy — never a bare move
############################

log_msg "[Step 7/7] Publishing archive and metadata to secondary storage..."

# Re-assert the mount: pre-flight may have passed hours ago, and a share that
# dropped since would look like an empty local directory. The copy would
# "succeed" onto the root filesystem and pass its own checksum re-read.
if ! require_smb; then
  log_error "SMB share became unavailable during the backup — cannot publish."
  exit 1
fi

SECONDARY_FILE="${SECONDARY_STORAGE_DIR}/$(basename "$COMPRESSED_FILE")"

if [[ -e "$SECONDARY_FILE" ]]; then
  log_error "Destination file already exists: $SECONDARY_FILE"
  exit 1
fi

# .part first, so an interrupted copy never matches a *.tar.gz glob.
if ! cp "$COMPRESSED_FILE" "${SECONDARY_FILE}.part" 2>>"$ERROR_LOG"; then
  log_error "Failed to copy archive to $SECONDARY_STORAGE_DIR"
  rm -f "${SECONDARY_FILE}.part" 2>/dev/null || true
  exit 1
fi

# Flush before trusting the checksum we are about to read.
sync "${SECONDARY_FILE}.part" 2>/dev/null || sync || true

log_msg "Verifying transferred archive against SHA-256..."
TRANSFERRED_SHA256=$(sha256sum "${SECONDARY_FILE}.part" 2>>"$ERROR_LOG" | awk '{print $1}')

if [[ "$TRANSFERRED_SHA256" != "$BACKUP_SHA256" ]]; then
  log_error "Checksum mismatch after transfer to secondary storage"
  log_error "Expected: $BACKUP_SHA256"
  log_error "Got     : ${TRANSFERRED_SHA256:-(none)}"
  rm -f "${SECONDARY_FILE}.part" 2>/dev/null || true
  exit 1
fi

if ! mv "${SECONDARY_FILE}.part" "$SECONDARY_FILE" 2>>"$ERROR_LOG"; then
  log_error "Failed to finalize archive name on secondary storage"
  rm -f "${SECONDARY_FILE}.part" 2>/dev/null || true
  exit 1
fi

TRANSFER_OK="yes"
log_msg "Transfer verified: $SECONDARY_FILE"

log_msg "Removing scratch copy of archive: $COMPRESSED_FILE"
rm -f "$COMPRESSED_FILE" 2>>"$ERROR_LOG" || log_warn "Failed to remove scratch archive: $COMPRESSED_FILE"
COMPRESSED_FILE="$SECONDARY_FILE"

# Repointed at the archive's permanent location, so `sha256sum -c` resolves
# from anywhere. The restore scripts rely on this.
SECONDARY_CHECKSUM="${SECONDARY_STORAGE_DIR}/$(basename "$CHECKSUM_FILE")"
if ! echo "$BACKUP_SHA256  $SECONDARY_FILE" > "$SECONDARY_CHECKSUM" 2>>"$ERROR_LOG"; then
  log_error "Failed to write checksum file to secondary storage"
  exit 1
fi
rm -f "$CHECKSUM_FILE" 2>/dev/null || true
CHECKSUM_FILE="$SECONDARY_CHECKSUM"
log_msg "Checksum published: $CHECKSUM_FILE"

# binlog_collect.sh anchors on this file and reads only the share, so it MUST
# land on secondary — staging is wiped.
SECONDARY_BINLOG_INFO="${SECONDARY_STORAGE_DIR}/$(basename "$BINLOG_INFO_FILE")"
if ! cp "$BINLOG_INFO_FILE" "$SECONDARY_BINLOG_INFO" 2>>"$ERROR_LOG"; then
  log_error "Failed to copy binlog info to secondary storage"
  exit 1
fi
if [[ ! -s "$SECONDARY_BINLOG_INFO" ]]; then
  log_error "Binlog info on secondary is empty: $SECONDARY_BINLOG_INFO"
  exit 1
fi
rm -f "$BINLOG_INFO_FILE" 2>/dev/null || true
BINLOG_INFO_FILE="$SECONDARY_BINLOG_INFO"
log_msg "Binlog info published: $BINLOG_INFO_FILE"

############################
# PUBLISH MANIFEST
# Sidecar, OUTSIDE the tarball: restore_full.sh needs the checksum, source
# version and prepared flag BEFORE committing to extract hundreds of GB.
############################

log_msg "Writing backup manifest..."

MYSQL_VERSION=$("$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -NBe "SELECT VERSION()" 2>/dev/null || echo "unknown")
BINLOG_FORMAT=$("$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -NBe "SELECT @@binlog_format" 2>/dev/null || echo "unknown")
GTID_MODE=$("$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -NBe "SELECT @@gtid_mode" 2>/dev/null || echo "unknown")

MANIFEST_FILE="${SECONDARY_STORAGE_DIR}/${NAME}.manifest"

# .part + mv, so a restore never reads a half-written manifest.
if ! cat > "${MANIFEST_FILE}.part" <<EOF
backup_id=${NAME}
created_at=$(date '+%F %T')
archive_path=${SECONDARY_FILE}
archive_sha256=${BACKUP_SHA256}
prepared=yes
backup_type=${PREPARED_TYPE}
mysql_version=${MYSQL_VERSION}
xtrabackup_version=${XTRABACKUP_VERSION}
binlog_format=${BINLOG_FORMAT}
gtid_mode=${GTID_MODE}
binlog_file=${BINLOG_NAME}
binlog_pos=${BINLOG_POS}
recovery_method=file_position
datadir=${MYSQL_DATADIR}
EOF
then
  log_error "Failed to write manifest: ${MANIFEST_FILE}.part"
  rm -f "${MANIFEST_FILE}.part" 2>/dev/null || true
  exit 1
fi

if ! mv "${MANIFEST_FILE}.part" "$MANIFEST_FILE" 2>>"$ERROR_LOG"; then
  log_error "Failed to finalize manifest: $MANIFEST_FILE"
  rm -f "${MANIFEST_FILE}.part" 2>/dev/null || true
  exit 1
fi
log_msg "Manifest published: $MANIFEST_FILE"

log_msg "All artifacts published to the SMB share; local staging is clear."

############################
# FINAL VALIDATION
############################

log_msg "Performing final validation..."

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
  echo "Manifest         : $MANIFEST_FILE"
  echo "Parallel threads : $PARALLEL_THREADS"
  echo "Archive (verified): $SECONDARY_FILE"
  echo "===================================================="
  echo "To restore this backup:"
  echo "  ./restore.sh $NAME"
  echo "===================================================="
  echo "Logs (published to secondary):"
  echo "  $SECONDARY_LOG_DIR/backup.log"
  echo "  $SECONDARY_LOG_DIR/xtrabackup.log"
  echo "  $SECONDARY_LOG_DIR/errors.log"
  echo "===================================================="
} | tee -a "$RUN_LOG"

############################
# REMOVE LOCK FILE (success path; failures go through cleanup_on_error)
############################

log_msg "Removing lock file: $LOCK_FILE"
rm -f "$LOCK_FILE" 2>/dev/null || true
log_msg "Lock file removed"

############################
# POST-BACKUP BINLOG COLLECTION
# Best-effort: the archive is already complete, so a binlog problem here must
# not fail the run. Runs inline only to avoid waiting for the next cron fire.
############################

log_msg "===================================================="
log_msg "Post-backup binlog collection starting..."
log_msg "===================================================="

if [[ ! -x "$BINLOG_SCRIPT" ]]; then
  log_warn "Binlog script not found or not executable: $BINLOG_SCRIPT"
  log_warn "Binlog collection skipped — cron will collect at the next 15-min interval"
else
  if "$BINLOG_SCRIPT" >> "$RUN_LOG" 2>&1; then
    log_msg "Post-backup binlog collection completed successfully"
  else
    log_warn "Post-backup binlog collection failed — cron will retry at the next 15-min interval"
  fi
fi

############################
# PUBLISH LOGS
# Must stay last: nothing may call log_msg after this — RUN_LOG is gone.
############################

publish_logs

trap - ERR INT TERM

exit 0
