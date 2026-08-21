#!/usr/bin/env bash
#
# server/physical/restore_full.sh — restore a full XtraBackup archive
#
# Usage: ./restore_full.sh <backup_id>          e.g. 20260810 or 20260810_143005
# Docs:  instructions/server/physical/README.md
#
# ERASES MYSQL_DATADIR. Does NOT apply binlogs — run apply_binlog.sh after.
#
set -euo pipefail

############################
# CONFIGURATION
############################

# MySQL credentials
MYSQL_USER="Admin"
MYSQL_PASSWORD=""

# MUST match SECONDARY_STORAGE_DIR in backup.sh.
SECONDARY_STORAGE_DIR="/livestorage/YK/Restore-VM"

# The CIFS MOUNT POINT itself — MUST match SMB_MOUNT_POINT in backup.sh.
SMB_MOUNT_POINT="/livestorage"

ARCHIVE_DIR="$SECONDARY_STORAGE_DIR"

# LOCAL, and used ONLY for this run's logs. The archive is NOT staged here —
# it is read directly from the share.
LOCAL_STAGE="/Data/dbvault-stage"

# ERASED by this script.
MYSQL_DATADIR="/Data/mysql"

# 1 = restore normally (erases MYSQL_DATADIR).  0 = refuse to run at all.
# This is an OFF switch, not a safe mode: a restore that cannot wipe cannot
# restore. Leave it at 0 on servers where nobody should be able to trigger one.
CONFIRM_WIPE=1

MYSQL_SERVICE="mysql"
MYSQL_BIN="/usr/bin/mysql"

# Locks — LOCAL. /var/lock is tmpfs, so a reboot clears a stale lock.
LOCK_DIR="/var/lock/dbvault"

# Restore state — LOCAL and PERSISTENT, deliberately NOT on the share: the
# marker records what THIS server did. /var/lib, not /var/lock, so it survives
# a reboot. apply_binlog.sh's double-apply guard reads it.
STATE_DIR="/var/lib/dbvault"

############################
# EARLY INITIALIZATION
############################

RUN_LOG=""
ERROR_LOG=""
BACKUP_ID=""
MYSQL_WAS_RUNNING=false
PUBLISHED_LOGS=0

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

# A dropped CIFS mount reverts to an empty LOCAL directory that passes every
# [[ -d ]] test — here that reads as "backup not found" on a backup that exists.
require_smb() {
  if ! mountpoint -q "$SMB_MOUNT_POINT"; then
    log_error "SMB share is NOT mounted at: $SMB_MOUNT_POINT"
    log_error "The path may still exist as an empty local directory."
    return 1
  fi
  if [[ ! -d "$ARCHIVE_DIR" ]]; then
    log_error "Archive directory not found on the share: $ARCHIVE_DIR"
    return 1
  fi
  if ! ls "$ARCHIVE_DIR" >/dev/null 2>&1; then
    log_error "Archive directory not readable (stale handle?): $ARCHIVE_DIR"
    return 1
  fi
  return 0
}

mysql_cmd() {
  "$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$@"
}

test_mysql_connection() {
  mysql_cmd -e "SELECT 1" >/dev/null 2>&1
}

is_mysql_running() {
  if systemctl is-active --quiet "$MYSQL_SERVICE" 2>/dev/null || \
     systemctl is-active --quiet mysqld 2>/dev/null; then
    return 0
  fi
  if pgrep -x mysqld >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

get_free_space_gb() {
  df -BG "$1" | awk 'NR==2 {print $4}' | sed 's/G//'
}

# Empty if the key or the file is absent.
manifest_get() {
  [[ -f "$MANIFEST_FILE" ]] || return 0
  awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$MANIFEST_FILE"
}

# Best-effort — never fails the restore.
publish_logs() {
  [[ "$PUBLISHED_LOGS" == "1" ]] && return 0
  PUBLISHED_LOGS=1
  [[ -n "${SECONDARY_LOG_DIR:-}" ]] || return 0
  mountpoint -q "$SMB_MOUNT_POINT" 2>/dev/null || return 0

  mkdir -p "$SECONDARY_LOG_DIR" 2>/dev/null || {
    echo "[$(date '+%F %T')] [WARN] Cannot create log dir: $SECONDARY_LOG_DIR (logs remain local)" >&2
    return 0
  }
  for pair in "${RUN_LOG}:restore.log" "${ERROR_LOG}:restore_errors.log"; do
    src="${pair%:*}"; dst="${pair##*:}"
    [[ -n "$src" && -f "$src" ]] || continue
    cp "$src" "${SECONDARY_LOG_DIR}/${dst}" 2>/dev/null || true
  done
  echo "[$(date '+%F %T')] [INFO] Logs published to: $SECONDARY_LOG_DIR"
}

cleanup_on_error() {
  log_error "Full restore failed."

  # Deliberately not auto-started: mysqld on a partial datadir writes recovery
  # state that makes a clean retry harder.
  if [[ "$MYSQL_WAS_RUNNING" == true ]] && ! is_mysql_running; then
    log_error "MySQL is STOPPED and was running before this script started."
    log_error "It is NOT being auto-started: the datadir may be partially extracted,"
    log_error "and starting mysqld on it could make a clean retry harder."
  fi

  log_error "Retry with:  $0 $BACKUP_ID"
  log_error "Restore aborted. Check logs: ${RUN_LOG:-'(not initialized)'}"
  publish_logs
  trap - ERR INT TERM
  exit 1
}

trap cleanup_on_error ERR INT TERM

show_usage() {
  echo "Usage: $0 <backup_id>"
  echo ""
  echo "  Restores the full XtraBackup archive for <backup_id>."
  echo "  This ERASES $MYSQL_DATADIR."
  echo "  Does NOT apply binlogs — run apply_binlog.sh afterwards."
  echo ""
  echo "Arguments:"
  echo "  backup_id   :  As published by backup.sh — 20260810 or 20260810_143005"
  echo ""
  echo "Examples:"
  echo "  $0 20260810"
  echo "  $0 20260810_143005"
  echo ""
  echo "Available backups on the share:"
  if [[ -d "$ARCHIVE_DIR" ]]; then
    find "$ARCHIVE_DIR" -maxdepth 1 -type f -name "*.tar.gz" 2>/dev/null \
      | sort | while read -r f; do
        echo "  $(basename "$f" .tar.gz)"
      done
  else
    echo "  (share not reachable)"
  fi
  trap - ERR INT TERM
  exit 1
}

############################
# INPUT VALIDATION
############################

if [[ $# -ne 1 ]]; then
  show_usage
fi

BACKUP_ID="$1"

# Anchored, because this value is interpolated into every path below.
if ! [[ "$BACKUP_ID" =~ ^[0-9]{8}(_[0-9]{6})?$ ]]; then
  echo "[$(date '+%F %T')] [ERROR] Invalid backup ID: $BACKUP_ID" >&2
  echo "[$(date '+%F %T')] [ERROR] Expected YYYYMMDD or YYYYMMDD_HHMMSS" >&2
  trap - ERR INT TERM
  exit 1
fi

############################
# SINGLE-INSTANCE LOCK — two restores would race on the same datadir
############################

mkdir -p "$LOCK_DIR" "$STATE_DIR" 2>/dev/null || true
exec 200>"${LOCK_DIR}/restore.lock"
if ! flock -n 200; then
  echo "[$(date '+%F %T')] [ERROR] Another restore or apply is already running." >&2
  trap - ERR INT TERM
  exit 1
fi

############################
# DERIVED PATHS
############################

SMB_ARCHIVE="${ARCHIVE_DIR}/${BACKUP_ID}.tar.gz"
CHECKSUM_FILE="${ARCHIVE_DIR}/${BACKUP_ID}.sha256"
MANIFEST_FILE="${ARCHIVE_DIR}/${BACKUP_ID}.manifest"
BINLOG_INFO_FILE="${ARCHIVE_DIR}/${BACKUP_ID}_binlog_info"

RESTORE_MARKER="${STATE_DIR}/${BACKUP_ID}_restore_state"

RUN_LOG="${LOCAL_STAGE}/${BACKUP_ID}_restore.log"
ERROR_LOG="${LOCAL_STAGE}/${BACKUP_ID}_restore_errors.log"
SECONDARY_LOG_DIR="${ARCHIVE_DIR}/logs/${BACKUP_ID}/restore"

START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
START_EPOCH="$(date +%s)"

############################
# INITIALIZE LOGS
############################

if ! mkdir -p "$LOCAL_STAGE" 2>/dev/null; then
  echo "[$(date '+%F %T')] [ERROR] Failed to create local log directory: $LOCAL_STAGE" >&2
  trap - ERR INT TERM
  exit 1
fi

cat > "$RUN_LOG" << EOF
========================================
MYSQL FULL RESTORE LOG
========================================
Backup ID : $BACKUP_ID
Started   : $(date '+%F %T')
========================================

EOF

cat > "$ERROR_LOG" << EOF
========================================
MYSQL FULL RESTORE ERROR LOG
========================================
Backup ID : $BACKUP_ID
Started   : $(date '+%F %T')
========================================

EOF

############################
# PRE-FLIGHT CHECKS
############################

log_msg "===================================================="
log_msg "Starting pre-flight checks..."
log_msg "===================================================="

log_msg "Check 1/11: Verifying user privileges..."
if [[ $EUID -ne 0 ]]; then
  log_error "This script must be run as root"
  trap - ERR INT TERM
  exit 1
fi
log_msg "Running as root"

log_msg "Check 2/11: Verifying required binaries..."
REQUIRED_COMMANDS=(tar gzip awk du df stat chown rm sleep basename sha256sum mountpoint flock systemctl)
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
log_msg "All required binaries found"

# Deliberately before any long-running work: no point spending an hour reading
# an archive only to refuse at the wipe step.
log_msg "Check 3/11: Verifying the wipe switch is enabled..."
if [[ "${CONFIRM_WIPE:-0}" != "1" ]]; then
  log_error "===================================================="
  log_error "RESTORE IS DISABLED ON THIS SERVER (CONFIRM_WIPE=0)"
  log_error "===================================================="
  log_error "This script PERMANENTLY ERASES: $MYSQL_DATADIR"
  log_error "Restoring is not possible without that, so it stops here."
  log_error ""
  log_error "To enable it, edit this script and set:"
  log_error "  CONFIRM_WIPE=1"
  log_error ""
  log_error "Before you do, confirm you have EITHER:"
  log_error "  - a VM snapshot of this host, or"
  log_error "  - a forensic copy of the current datadir"
  log_error ""
  log_error "If the current data is damaged, it is still evidence. Once this"
  log_error "script runs, it is gone and cannot be examined."
  log_error "===================================================="
  trap - ERR INT TERM
  exit 1
fi
log_msg "Wipe switch enabled — $MYSQL_DATADIR will be erased"

log_msg "Check 4/11: Verifying SMB share..."
if ! require_smb; then
  trap - ERR INT TERM
  exit 1
fi
log_msg "SMB share is mounted and readable: $ARCHIVE_DIR"

log_msg "Check 5/11: Verifying archive exists on the share..."
if [[ ! -f "$SMB_ARCHIVE" ]]; then
  log_error "Backup archive not found: $SMB_ARCHIVE"
  log_error "Available backups:"
  find "$ARCHIVE_DIR" -maxdepth 1 -type f -name "*.tar.gz" 2>/dev/null | sort | while read -r f; do
    log_error "  $(basename "$f" .tar.gz)"
  done
  trap - ERR INT TERM
  exit 1
fi
ARCHIVE_SIZE=$(du -sh "$SMB_ARCHIVE" | awk '{print $1}')
log_msg "Archive found: $SMB_ARCHIVE ($ARCHIVE_SIZE)"

# Manifest first, .sha256 as the fallback for backups that predate manifests.
# Neither present is a hard refusal — see the README.
log_msg "Check 6/11: Resolving expected SHA-256..."
EXPECTED_SHA=""
CHECKSUM_SOURCE=""

if [[ -f "$MANIFEST_FILE" ]]; then
  EXPECTED_SHA="$(manifest_get archive_sha256)"
  [[ -n "$EXPECTED_SHA" ]] && CHECKSUM_SOURCE="manifest"
fi

if [[ -z "$EXPECTED_SHA" && -s "$CHECKSUM_FILE" ]]; then
  EXPECTED_SHA=$(awk '{print $1}' "$CHECKSUM_FILE")
  [[ -n "$EXPECTED_SHA" ]] && CHECKSUM_SOURCE="${BACKUP_ID}.sha256 (legacy, no manifest)"
fi

if [[ -z "$EXPECTED_SHA" ]]; then
  log_error "No checksum available for $BACKUP_ID"
  log_error "Looked for archive_sha256 in : $MANIFEST_FILE"
  log_error "and for a checksum file at   : $CHECKSUM_FILE"
  log_error "Refusing to restore an unverified archive over a wiped datadir."
  trap - ERR INT TERM
  exit 1
fi
log_msg "Expected SHA-256: $EXPECTED_SHA (source: $CHECKSUM_SOURCE)"

log_msg "Check 7/11: Verifying manifest..."
if [[ -f "$MANIFEST_FILE" ]]; then
  PREPARED="$(manifest_get prepared)"
  MANIFEST_TYPE="$(manifest_get backup_type)"
  RECOVERY_METHOD="$(manifest_get recovery_method)"
  SRC_VERSION="$(manifest_get mysql_version)"

  if [[ "$PREPARED" != "yes" ]]; then
    log_error "Manifest says prepared='$PREPARED' (expected 'yes')."
    log_error "An unprepared backup cannot be started — refusing."
    trap - ERR INT TERM
    exit 1
  fi
  log_msg "Manifest: prepared=$PREPARED, backup_type=$MANIFEST_TYPE, recovery_method=${RECOVERY_METHOD:-unknown}"
else
  log_warn "No manifest found: $MANIFEST_FILE"
  log_warn "This backup predates manifests. The prepared state cannot be confirmed"
  log_warn "in advance — it WILL still be verified after extraction (Step 4)."
  SRC_VERSION=""
fi

# INFORMATIONAL ONLY, deliberately: the comparison is a crude string match, and
# a false positive that blocked the restore would leave you unable to recover
# at all. See the README for why the mismatch matters.
log_msg "Check 8/11: Comparing MySQL versions..."
LOCAL_VERSION=$("$MYSQL_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
if [[ -n "$SRC_VERSION" && "$SRC_VERSION" != "unknown" && -n "$LOCAL_VERSION" ]]; then
  if [[ "${SRC_VERSION%%-*}" != "$LOCAL_VERSION" ]]; then
    log_warn "===================================================="
    log_warn "MySQL VERSION MISMATCH — continuing anyway"
    log_warn "===================================================="
    log_warn "Backup was taken from : $SRC_VERSION"
    log_warn "This server runs      : $LOCAL_VERSION"
    log_warn ""
    log_warn "Restoring a NEWER datadir onto an OLDER server usually fails."
    log_warn "If MySQL will not start at the end of this restore, this is the"
    log_warn "first thing to check."
    log_warn "===================================================="
  else
    log_msg "Versions match: $LOCAL_VERSION"
  fi
else
  log_warn "Version comparison skipped (backup version: ${SRC_VERSION:-unrecorded}, local: ${LOCAL_VERSION:-unknown})"
fi

# The archive is never staged locally, so only the datadir needs room. Estimated
# at 4x the compressed size — the conservative end for gzip on InnoDB pages.
log_msg "Check 9/11: Checking datadir space..."
ARCHIVE_BYTES=$(stat -c%s "$SMB_ARCHIVE" 2>/dev/null || echo "0")
ARCHIVE_GB=$((ARCHIVE_BYTES / 1024 / 1024 / 1024 + 1))
if [[ ! -d "$MYSQL_DATADIR" ]]; then
  log_error "MySQL data directory not found: $MYSQL_DATADIR"
  trap - ERR INT TERM
  exit 1
fi
if [[ -z "$MYSQL_DATADIR" || "$MYSQL_DATADIR" == "/" ]]; then
  log_error "Refusing to operate on an unsafe datadir path: '$MYSQL_DATADIR'"
  trap - ERR INT TERM
  exit 1
fi
DATADIR_FREE=$(get_free_space_gb "$MYSQL_DATADIR")
REQUIRED_DATADIR=$((ARCHIVE_GB * 4))
log_msg "Free in $MYSQL_DATADIR: ${DATADIR_FREE}GB, required (est. 4x archive): ${REQUIRED_DATADIR}GB"
if [[ $DATADIR_FREE -lt $REQUIRED_DATADIR ]]; then
  log_error "Insufficient space in $MYSQL_DATADIR"
  log_error "Required (est.): ${REQUIRED_DATADIR}GB, Available: ${DATADIR_FREE}GB"
  trap - ERR INT TERM
  exit 1
fi

log_msg "Check 10/11: Verifying MySQL status..."
if is_mysql_running; then
  MYSQL_WAS_RUNNING=true
  log_msg "MySQL is running (will be stopped during restore)"
else
  log_msg "MySQL is not currently running"
fi

log_msg "Check 11/11: Checking for existing restore state..."
if [[ -f "$RESTORE_MARKER" ]]; then
  PREV_AT=$(awk -F= '/^restored_at=/{print $2}' "$RESTORE_MARKER")
  PREV_APPLIED=$(awk -F= '/^binlogs_applied=/{print $2}' "$RESTORE_MARKER")
  log_warn "A restore of $BACKUP_ID was already performed on this server."
  log_warn "  restored_at     : ${PREV_AT:-unknown}"
  log_warn "  binlogs_applied : ${PREV_APPLIED:-unknown}"
  log_warn "Re-running is the correct ROLLBACK action after a failed binlog apply."
  log_warn "The marker will be reset, so binlogs can be applied once more."
else
  log_msg "No previous restore state — clean restore"
fi

log_msg "===================================================="
log_msg "All pre-flight checks passed"
log_msg "===================================================="

{
  echo ""
  echo "===================================================="
  echo "FULL RESTORE STARTED"
  echo "===================================================="
  echo "Start time      : $START_TIME"
  echo "Backup ID       : $BACKUP_ID"
  echo "SMB archive     : $SMB_ARCHIVE ($ARCHIVE_SIZE)"
  echo "Read directly from the share — not staged locally."
  echo "Expected SHA256 : $EXPECTED_SHA"
  echo "MySQL datadir   : $MYSQL_DATADIR  (WILL BE ERASED)"
  echo "Restore marker  : $RESTORE_MARKER"
  echo "===================================================="
  echo ""
} | tee -a "$RUN_LOG"

############################
# STEP 1: VERIFY THE ARCHIVE ON THE SHARE
# BEFORE MySQL is stopped and BEFORE anything is erased, so failing here is
# free — the database is still running on its existing data. This reads the
# whole archive over the network, and extraction reads it again; that second
# read is the price of not staging locally, and is not worth skipping this.
############################

log_msg "[Step 1/4] Verifying the archive on the share ($ARCHIVE_SIZE)..."
log_msg "Reading the full archive over the network — this may take a while."

ACTUAL_SHA=$(sha256sum "$SMB_ARCHIVE" 2>>"$ERROR_LOG" | awk '{print $1}')

if [[ -z "$ACTUAL_SHA" ]]; then
  log_error "Could not read the archive from the share to checksum it."
  log_error "The share may have dropped. The datadir has NOT been touched."
  exit 1
fi

if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
  log_error "===================================================="
  log_error "SHA-256 MISMATCH — the archive is corrupt or truncated"
  log_error "===================================================="
  log_error "Expected: $EXPECTED_SHA"
  log_error "Actual  : $ACTUAL_SHA"
  log_error ""
  log_error "The datadir has NOT been touched. Nothing is lost."
  log_error "Restore from a different backup ID."
  log_error "===================================================="
  exit 1
fi

log_msg "Archive VERIFIED on the share: $SMB_ARCHIVE"

############################
# STEP 2: STOP MYSQL — everything from here on is destructive
############################

log_msg "[Step 2/4] Stopping MySQL..."

if is_mysql_running; then
  if ! systemctl stop "$MYSQL_SERVICE" 2>>"$ERROR_LOG"; then
    log_error "Failed to stop MySQL service: $MYSQL_SERVICE"
    exit 1
  fi
  sleep 3
  if is_mysql_running; then
    log_error "MySQL is still running after the stop command"
    log_error "Refusing to wipe a datadir with a live server attached to it."
    exit 1
  fi
  log_msg "MySQL stopped"
else
  log_msg "MySQL was already stopped"
fi

############################
# STEP 3: WIPE AND EXTRACT
############################

log_msg "[Step 3/4] Wiping datadir and extracting..."

# Re-asserted immediately before rm -rf: cheap, and the one place where a
# mistake is unrecoverable.
if [[ -z "$MYSQL_DATADIR" || "$MYSQL_DATADIR" == "/" ]]; then
  log_error "Safety check failed: unsafe MYSQL_DATADIR '$MYSQL_DATADIR'"
  exit 1
fi

log_msg "Erasing: $MYSQL_DATADIR"
if ! rm -rf "${MYSQL_DATADIR:?}/"* 2>>"$ERROR_LOG"; then
  log_error "Failed to clear the data directory"
  exit 1
fi
if [[ -n "$(ls -A "$MYSQL_DATADIR" 2>/dev/null)" ]]; then
  log_error "Data directory is not empty after the wipe"
  exit 1
fi
log_msg "Data directory cleared"

# The one window where a network problem is genuinely costly: the datadir is
# already wiped, so a stall here leaves it partially populated. The archive is
# verified and intact, so the fix is to wait for the share and re-run.
log_msg "Extracting directly from the share (network in the critical path)..."
if ! tar -xzf "$SMB_ARCHIVE" -C "$MYSQL_DATADIR" --strip-components=1 2>>"$ERROR_LOG"; then
  log_error "Failed to extract the archive from the share"
  log_error "The datadir is now PARTIALLY POPULATED and MySQL is stopped."
  log_error "If the share dropped, restore it and re-run:"
  log_error "  $0 $BACKUP_ID"
  exit 1
fi
log_msg "Extraction complete"

log_msg "Setting ownership on the restored files..."
if ! chown -R mysql:mysql "$MYSQL_DATADIR" 2>>"$ERROR_LOG"; then
  log_error "Failed to set ownership on $MYSQL_DATADIR"
  exit 1
fi
log_msg "Ownership set"

############################
# STEP 4: VALIDATE THE EXTRACTED DATADIR
# Validates the RESULT of the extraction, not the source archive. Re-hashing the
# tarball here would prove only that the file we just read is the file we just
# read — it cannot fail, and says nothing about what landed on disk.
############################

log_msg "[Step 4/4] Validating the extracted datadir..."

for artifact in ibdata1 mysql xtrabackup_checkpoints; do
  if [[ ! -e "$MYSQL_DATADIR/$artifact" ]]; then
    log_error "Missing after extraction: $artifact"
    log_error "The archive is not a complete XtraBackup datadir."
    exit 1
  fi
done
log_msg "Core artifacts present (ibdata1, mysql, xtrabackup_checkpoints)"

# The check that matters: mysqld started on a backup that was never
# --prepare'd finds an inconsistent redo state and rewrites pages on top of it.
# backup.sh asserts this at publish time; this re-asserts it against the disk.
EXTRACTED_TYPE=$(awk '/backup_type/ {print $3}' "$MYSQL_DATADIR/xtrabackup_checkpoints")
if [[ "$EXTRACTED_TYPE" != "full-prepared" ]]; then
  log_error "===================================================="
  log_error "EXTRACTED BACKUP IS NOT PREPARED"
  log_error "===================================================="
  log_error "backup_type is '${EXTRACTED_TYPE:-(empty)}', expected 'full-prepared'."
  log_error "Starting MySQL on an unprepared backup WILL corrupt it."
  log_error "MySQL has been left STOPPED deliberately."
  log_error "===================================================="
  exit 1
fi
log_msg "Extracted backup verified: backup_type=$EXTRACTED_TYPE"

############################
# START MYSQL
############################

log_msg "Starting MySQL..."

if ! systemctl start "$MYSQL_SERVICE" 2>>"$ERROR_LOG"; then
  log_error "MySQL failed to start after the restore"
  log_error "Check the MySQL error log for details."
  exit 1
fi

log_msg "Waiting for MySQL to accept connections..."
MYSQL_READY=false
for i in {1..60}; do
  if mysql_cmd -e "SELECT 1" >/dev/null 2>&1; then
    MYSQL_READY=true
    log_msg "MySQL is ready"
    break
  fi
  if [[ $((i % 10)) -eq 0 ]]; then
    log_msg "Still waiting for MySQL... (${i}/60)"
  fi
  sleep 2
done

if [[ "$MYSQL_READY" != true ]]; then
  log_error "MySQL did not become ready within 120 seconds"
  log_error "Check the MySQL error log."
  exit 1
fi

############################
# WRITE RESTORE MARKER
# A safety mechanism, not bookkeeping: apply_binlog.sh reads binlogs_applied
# from here to hard-refuse a second apply. Written once the restore is complete.
############################

BINLOG_FILE_REF=""
BINLOG_POS_REF=""
if [[ -f "$MANIFEST_FILE" ]]; then
  BINLOG_FILE_REF="$(manifest_get binlog_file)"
  BINLOG_POS_REF="$(manifest_get binlog_pos)"
fi
# The standalone anchor covers backups taken before manifests existed.
if [[ -z "$BINLOG_FILE_REF" && -s "$BINLOG_INFO_FILE" ]]; then
  BINLOG_FILE_REF=$(awk '{print $1}' "$BINLOG_INFO_FILE")
  BINLOG_POS_REF=$(awk '{print $2}' "$BINLOG_INFO_FILE")
fi

cat > "$RESTORE_MARKER" <<EOF
restored_at=$(date '+%F %T')
backup_id=${BACKUP_ID}
binlog_file=${BINLOG_FILE_REF}
binlog_pos=${BINLOG_POS_REF}
recovery_method=file_position
binlogs_applied=no
EOF

log_msg "Restore marker written: $RESTORE_MARKER"

############################
# FINAL VALIDATION
############################

log_msg "Performing final validation..."

if ! is_mysql_running; then
  log_error "MySQL is not running after the restore"
  exit 1
fi
if ! test_mysql_connection; then
  log_error "Cannot connect to MySQL after the restore"
  exit 1
fi

DB_COUNT=$(mysql_cmd -NBe "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema','mysql','performance_schema','sys')" 2>>"$ERROR_LOG" || echo "0")
log_msg "Final validation passed. User databases: $DB_COUNT"

############################
# COMPLETE
############################

END_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
END_EPOCH="$(date +%s)"
DURATION=$((END_EPOCH - START_EPOCH))

{
  echo ""
  echo "===================================================="
  echo "FULL RESTORE COMPLETED"
  echo "===================================================="
  echo "Start time      : $START_TIME"
  echo "End time        : $END_TIME"
  echo "Duration        : $((DURATION / 60))m $((DURATION % 60))s"
  echo "Backup ID       : $BACKUP_ID"
  echo "SHA-256         : $EXPECTED_SHA"
  echo "User databases  : $DB_COUNT"
  echo "Binlog anchor   : ${BINLOG_FILE_REF:-unknown}:${BINLOG_POS_REF:-unknown}"
  echo "Restore marker  : $RESTORE_MARKER"
  echo "===================================================="
  echo "THE DATABASE IS NOT YET CURRENT"
  echo "===================================================="
  echo "It holds data as of the backup. Binlogs have NOT been applied."
  echo "MySQL is running and reachable."
  echo ""
  echo "Next steps:"
  echo "  1. Inspect first (never skip this — apply is one-shot):"
  echo "       ./apply_binlog.sh $BACKUP_ID --dry-run"
  echo "  2. Apply:"
  echo "       ./apply_binlog.sh $BACKUP_ID"
  echo "===================================================="
  echo "IF THE BINLOG APPLY FAILS"
  echo "===================================================="
  echo "GTID is off, so a failed apply CANNOT be resumed. The only correct"
  echo "recovery is to run this script again and retry the apply:"
  echo ""
  echo "  $0 $BACKUP_ID"
  echo ""
  echo "The archive is not staged locally, so that re-reads it in full from"
  echo "the share. Budget for the same transfer time as this run took."
  echo "===================================================="
  echo "Log files:"
  echo "  Main log      : $RUN_LOG"
  echo "  Error log     : $ERROR_LOG"
  echo "===================================================="
} | tee -a "$RUN_LOG"

publish_logs

trap - ERR INT TERM
exit 0
