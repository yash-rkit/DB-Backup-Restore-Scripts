#!/usr/bin/env bash
set -euo pipefail

############################
# CONFIGURATION
############################

RETENTION_DAYS=3

BACKUP_BASE="/Data/percona_backup"
ARCHIVE_DIR="/livestorage/Backup/Cloud-Live-DB-Default/percona"
BINLOG_DIR="${ARCHIVE_DIR}/binlog"

############################
# INITIALIZATION
############################

TODAY="$(date +%Y%m%d)"
DELETE_LOG="${BACKUP_BASE}/${TODAY}_delete.log"
CUTOFF_EPOCH=$(( $(date +%s) - RETENTION_DAYS * 86400 ))
DELETED_COUNT=0
ERROR_COUNT=0
START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
START_EPOCH="$(date +%s)"

############################
# HELPER FUNCTIONS
############################

log_msg() {
  echo "[$(date '+%F %T')] [INFO] $1" | tee -a "$DELETE_LOG"
}

log_error() {
  echo "[$(date '+%F %T')] [ERROR] $1" | tee -a "$DELETE_LOG" >&2
}

log_warn() {
  echo "[$(date '+%F %T')] [WARN] $1" | tee -a "$DELETE_LOG"
}

# Returns 0 if YYYYMMDD prefix of the given path is beyond the retention cutoff
is_expired() {
  local name prefix file_epoch
  name="$(basename "$1")"
  prefix="$(echo "$name" | grep -oP '^\d{8}')" || return 1
  file_epoch="$(date -d "$prefix" +%s 2>/dev/null)" || return 1
  [[ "$file_epoch" -lt "$CUTOFF_EPOCH" ]]
}

delete_item() {
  local target="$1" type="$2"
  if [[ "$type" == "dir" ]]; then
    if rm -rf "$target" 2>>"$DELETE_LOG"; then
      log_msg "Deleted dir : $target"
      DELETED_COUNT=$((DELETED_COUNT + 1))
    else
      log_error "Failed to delete dir: $target"
      ERROR_COUNT=$((ERROR_COUNT + 1))
    fi
  else
    if rm -f "$target" 2>>"$DELETE_LOG"; then
      log_msg "Deleted file: $target"
      DELETED_COUNT=$((DELETED_COUNT + 1))
    else
      log_error "Failed to delete file: $target"
      ERROR_COUNT=$((ERROR_COUNT + 1))
    fi
  fi
}

############################
# GUARD: REQUIRED DIRS
############################

for dir in "$BACKUP_BASE" "$ARCHIVE_DIR"; do
  if [[ ! -d "$dir" ]]; then
    echo "[$(date '+%F %T')] [ERROR] Required directory not found: $dir" >&2
    exit 1
  fi
done

############################
# LOG START
############################

{
  echo ""
  echo "===================================================="
  echo "RETENTION CLEANUP STARTED"
  echo "Start time     : $START_TIME"
  echo "Retention days : $RETENTION_DAYS"
  echo "Cutoff date    : $(date -d "@$CUTOFF_EPOCH" '+%Y-%m-%d')"
  echo "===================================================="
  echo ""
} | tee -a "$DELETE_LOG"

############################
# SECTION 1: BACKUP_BASE LOGS
# *_backup.log, *_errors.log, *_xtrabackup.log
############################

log_msg "--- Scanning BACKUP_BASE logs: $BACKUP_BASE ---"

while IFS= read -r -d '' f; do
  if [[ "$(basename "$f")" =~ ^[0-9]{8} ]] && is_expired "$f"; then
    delete_item "$f" "file"
  fi
done < <(find "$BACKUP_BASE" -maxdepth 1 -type f -name "*.log" -print0 2>/dev/null)

############################
# SECTION 2: BACKUP_BASE ORPHANED DIRS
# Uncompressed YYYYMMDD/ dirs left behind by SIGKILL
############################

log_msg "--- Scanning BACKUP_BASE orphaned dirs: $BACKUP_BASE ---"

while IFS= read -r -d '' d; do
  name="$(basename "$d")"
  # Match YYYYMMDD or YYYYMMDD_HHMMSS (timestamp-suffixed collision dirs)
  if [[ "$name" =~ ^[0-9]{8}(_[0-9]{6})?$ ]] && is_expired "$d"; then
    delete_item "$d" "dir"
  fi
done < <(find "$BACKUP_BASE" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)

############################
# SECTION 3: ARCHIVE_DIR BACKUP FILES
# *.tar.gz  *.sha256  *_binlog_info
############################

log_msg "--- Scanning ARCHIVE_DIR backup files: $ARCHIVE_DIR ---"

while IFS= read -r -d '' f; do
  if [[ "$(basename "$f")" =~ ^[0-9]{8} ]] && is_expired "$f"; then
    delete_item "$f" "file"
  fi
done < <(find "$ARCHIVE_DIR" -maxdepth 1 -type f \
  \( -name "*.tar.gz" -o -name "*.sha256" -o -name "*_binlog_info" \) \
  -print0 2>/dev/null)

############################
# SECTION 4: ARCHIVE_DIR STALE LOCK FILES
# Today's lock is never touched — backup.sh may still be running
############################

log_msg "--- Scanning ARCHIVE_DIR lock files: $ARCHIVE_DIR ---"

while IFS= read -r -d '' f; do
  name="$(basename "$f")"
  [[ "$name" == "${TODAY}_lock" ]] && continue
  if is_expired "$f"; then
    delete_item "$f" "file"
  fi
done < <(find "$ARCHIVE_DIR" -maxdepth 1 -type f -name "*_lock" -print0 2>/dev/null)

############################
# SECTION 5: BINLOG ARCHIVE DIRS
# ARCHIVE_DIR/binlog/YYYYMMDD/
############################

log_msg "--- Scanning binlog archive dirs: $BINLOG_DIR ---"

if [[ -d "$BINLOG_DIR" ]]; then
  while IFS= read -r -d '' d; do
    name="$(basename "$d")"
    if [[ "$name" =~ ^[0-9]{8}$ ]] && is_expired "$d"; then
      delete_item "$d" "dir"
    fi
  done < <(find "$BINLOG_DIR" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)
else
  log_warn "Binlog archive directory not found, skipping: $BINLOG_DIR"
fi

############################
# SUMMARY
############################

END_EPOCH="$(date +%s)"
DURATION=$(( END_EPOCH - START_EPOCH ))

{
  echo ""
  echo "===================================================="
  echo "RETENTION CLEANUP COMPLETED"
  echo "===================================================="
  echo "Duration       : ${DURATION}s"
  echo "Items deleted  : $DELETED_COUNT"
  echo "Errors         : $ERROR_COUNT"
  echo "Log file       : $DELETE_LOG"
  echo "===================================================="
} | tee -a "$DELETE_LOG"

[[ $ERROR_COUNT -gt 0 ]] && exit 1

exit 0
