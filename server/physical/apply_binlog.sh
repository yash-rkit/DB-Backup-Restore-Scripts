#!/usr/bin/env bash
#
# server/physical/apply_binlog.sh — replay collected binlogs after restore_full.sh
#
# Usage: ./apply_binlog.sh <backup_id> [--from <binlog>] [--dry-run]
# Docs:  instructions/server/physical/README.md
#
# GTID is OFF here, so recovery is by binlog file+position only: there is no
# duplicate detection and the apply is ONE-SHOT. Every safety decision in this
# script follows from that — halt on the first error, hard-refuse a second
# apply. Read the README before changing any of it.
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
BINLOG_ARCHIVE_BASE="${ARCHIVE_DIR}/binlog"

# LOCAL staging — MUST match BACKUP_BASE in backup.sh.
LOCAL_STAGE="/Data/dbvault-stage"

# As configured in MySQL (binlog.000001 -> "binlog").
BINLOG_PREFIX="binlog"

# EXACTLY six digits, never "${BINLOG_PREFIX}.*" — that also matches
# binlog.sha256, whose "sequence number" parses as the string "sha256", which
# bash evaluates as a variable name inside $(( )) and aborts under `set -u`.
BINLOG_GLOB="${BINLOG_PREFIX}.[0-9][0-9][0-9][0-9][0-9][0-9]"

MYSQL_BIN="/usr/bin/mysql"
MYSQLBINLOG_BIN="/usr/bin/mysqlbinlog"
MYSQL_SERVICE="mysql"

# Locks — LOCAL to this VM.
LOCK_DIR="/var/lock/dbvault"

# Restore state — LOCAL and persistent. MUST match STATE_DIR in restore_full.sh.
STATE_DIR="/var/lib/dbvault"

# The first real event in a binlog, past the 4-byte magic header.
BINLOG_FILE_START_POS=4

############################
# EARLY INITIALIZATION
############################

RUN_LOG=""
ERROR_LOG=""
BACKUP_ID=""
OVERRIDE_START_BINLOG=""
START_BINLOG=""
START_POS=""
APPLIED_COUNT=0
LAST_APPLIED=""
DRY_RUN=0
LOCAL_BINLOG_DIR=""

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

require_smb() {
  if ! mountpoint -q "$SMB_MOUNT_POINT"; then
    log_error "SMB share is NOT mounted at: $SMB_MOUNT_POINT"
    log_error "The path may still exist as an empty local directory."
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

is_valid_binlog_name() {
  [[ "$1" =~ ^${BINLOG_PREFIX}\.[0-9]{6}$ ]]
}

marker_get() {
  [[ -f "$RESTORE_MARKER" ]] || return 0
  awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$RESTORE_MARKER"
}

cleanup_on_error() {
  log_error "Binlog apply failed before any binlog was applied."
  log_error "The datadir is unchanged by this script. Check: ${RUN_LOG:-'(not initialized)'}"
  trap - ERR INT TERM
  exit 1
}

trap cleanup_on_error ERR INT TERM

show_usage() {
  echo "Usage: $0 <backup_id> [--from <binlog_filename>] [--dry-run]"
  echo ""
  echo "  Applies collected binlogs for <backup_id>."
  echo "  restore_full.sh must have been run for this backup ID first."
  echo ""
  echo "Arguments:"
  echo "  backup_id          :  20260810 or 20260810_143005 (required)"
  echo "  --from <filename>  :  start from this binlog instead of the backup position"
  echo "  --dry-run          :  decode the binlogs to a file and report. Applies NOTHING."
  echo ""
  echo "Examples:"
  echo "  $0 20260810 --dry-run       # ALWAYS do this first"
  echo "  $0 20260810"
  echo "  $0 20260810 --from ${BINLOG_PREFIX}.000123"
  echo ""
  echo "Notes:"
  echo "  - Without --from: uses the exact file + position recorded by the backup."
  echo "  - With --from on a DIFFERENT file: starts at position 4 (whole file)."
  echo "  - With --from on the SAME file as the backup anchor: uses the anchor"
  echo "    position, NOT 4, so transactions already inside the full backup are"
  echo "    not applied a second time."
  trap - ERR INT TERM
  exit 1
}

############################
# INPUT PARSING
############################

if [[ $# -lt 1 ]]; then
  show_usage
fi

BACKUP_ID="$1"
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)
      if [[ $# -lt 2 ]]; then
        echo "[$(date '+%F %T')] [ERROR] --from requires a binlog filename" >&2
        trap - ERR INT TERM
        exit 1
      fi
      OVERRIDE_START_BINLOG="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    *)
      echo "[$(date '+%F %T')] [ERROR] Unknown argument: $1" >&2
      show_usage
      ;;
  esac
done

if ! [[ "$BACKUP_ID" =~ ^[0-9]{8}(_[0-9]{6})?$ ]]; then
  echo "[$(date '+%F %T')] [ERROR] Invalid backup ID: $BACKUP_ID" >&2
  echo "[$(date '+%F %T')] [ERROR] Expected YYYYMMDD or YYYYMMDD_HHMMSS" >&2
  trap - ERR INT TERM
  exit 1
fi

if [[ -n "$OVERRIDE_START_BINLOG" ]] && ! is_valid_binlog_name "$OVERRIDE_START_BINLOG"; then
  echo "[$(date '+%F %T')] [ERROR] Invalid binlog filename: $OVERRIDE_START_BINLOG" >&2
  echo "[$(date '+%F %T')] [ERROR] Expected ${BINLOG_PREFIX}.NNNNNN" >&2
  trap - ERR INT TERM
  exit 1
fi

############################
# SINGLE-INSTANCE LOCK
# Same lock file as restore_full.sh: a concurrent restore would be wiping the
# datadir out from under this apply.
############################

mkdir -p "$LOCK_DIR" "$STATE_DIR" "$LOCAL_STAGE" 2>/dev/null || true
exec 200>"${LOCK_DIR}/restore.lock"
if ! flock -n 200; then
  echo "[$(date '+%F %T')] [ERROR] Another restore or apply is already running." >&2
  trap - ERR INT TERM
  exit 1
fi

############################
# DERIVED PATHS
############################

RESTORE_MARKER="${STATE_DIR}/${BACKUP_ID}_restore_state"
SMB_BINLOG_DIR="${BINLOG_ARCHIVE_BASE}/${BACKUP_ID}"
BINLOG_INFO_FILE="${ARCHIVE_DIR}/${BACKUP_ID}_binlog_info"
LOCAL_BINLOG_DIR="${LOCAL_STAGE}/binlog_${BACKUP_ID}"

RUN_LOG="${LOCAL_STAGE}/${BACKUP_ID}_binlog_apply.log"
ERROR_LOG="${LOCAL_STAGE}/${BACKUP_ID}_binlog_apply_errors.log"
SECONDARY_LOG_DIR="${ARCHIVE_DIR}/logs/${BACKUP_ID}/apply"

START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
START_EPOCH="$(date +%s)"

cat > "$RUN_LOG" << EOF
========================================
BINLOG APPLY LOG
========================================
Backup ID     : $BACKUP_ID
Override From : ${OVERRIDE_START_BINLOG:-(none, using backup anchor)}
Dry run       : $([[ $DRY_RUN -eq 1 ]] && echo yes || echo no)
Started       : $(date '+%F %T')
========================================

EOF

cat > "$ERROR_LOG" << EOF
========================================
BINLOG APPLY ERROR LOG
========================================
Backup ID     : $BACKUP_ID
Started       : $(date '+%F %T')
========================================

EOF

############################
# PRE-FLIGHT CHECKS
############################

log_msg "===================================================="
log_msg "Starting pre-flight checks..."
log_msg "===================================================="

log_msg "Check 1/10: Verifying user privileges..."
if [[ $EUID -ne 0 ]]; then
  log_error "This script must be run as root"
  trap - ERR INT TERM
  exit 1
fi
log_msg "Running as root"

log_msg "Check 2/10: Verifying required binaries..."
# rsync is deliberately absent: preferred for staging, but optional.
REQUIRED_COMMANDS=(awk find sort wc basename sha256sum mountpoint flock du grep cp)
for cmd in "${REQUIRED_COMMANDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "Required command not found: $cmd"
    trap - ERR INT TERM
    exit 1
  fi
done
for bin in "$MYSQL_BIN" "$MYSQLBINLOG_BIN"; do
  if [[ ! -x "$bin" ]]; then
    log_error "Binary not found or not executable: $bin"
    trap - ERR INT TERM
    exit 1
  fi
done
log_msg "All required binaries found"

log_msg "Check 3/10: Verifying a full restore was performed..."
if [[ ! -f "$RESTORE_MARKER" ]]; then
  log_error "===================================================="
  log_error "NO RESTORE MARKER FOR $BACKUP_ID"
  log_error "===================================================="
  log_error "Expected: $RESTORE_MARKER"
  log_error ""
  log_error "restore_full.sh has not been run for this backup ID on this server."
  log_error "Applying binlogs to a database that was NOT restored from this exact"
  log_error "backup applies transactions against the wrong starting state. The"
  log_error "result is silent, unrecoverable divergence — not an error message."
  log_error ""
  log_error "Run first:  ./restore_full.sh $BACKUP_ID"
  log_error "===================================================="
  trap - ERR INT TERM
  exit 1
fi
log_msg "Restore marker found (restored at: $(marker_get restored_at))"

# The most important guard in the script, and a hard stop rather than a warning
# you can walk past: without GTID there is no duplicate detection at all.
log_msg "Check 4/10: Verifying binlogs have not already been applied..."
ALREADY_APPLIED="$(marker_get binlogs_applied)"
if [[ "$ALREADY_APPLIED" == "yes" ]]; then
  log_error "===================================================="
  log_error "BINLOGS HAVE ALREADY BEEN APPLIED FOR $BACKUP_ID"
  log_error "===================================================="
  log_error "Applied at          : $(marker_get applied_at)"
  log_error "Last applied binlog : $(marker_get last_applied_binlog)"
  log_error "Files applied       : $(marker_get files_applied)"
  log_error ""
  log_error "Re-running would re-apply EVERY transaction on top of a database"
  log_error "that already contains them. Recovery here is file+position only —"
  log_error "there is no duplicate detection. This WILL corrupt data."
  log_error ""
  log_error "To genuinely redo the apply, restore the full backup first:"
  log_error "  ./restore_full.sh $BACKUP_ID"
  log_error "  ./apply_binlog.sh $BACKUP_ID"
  log_error "===================================================="
  trap - ERR INT TERM
  exit 1
fi
log_msg "No previous apply recorded — safe to proceed"

log_msg "Check 5/10: Verifying SMB share..."
if ! require_smb; then
  trap - ERR INT TERM
  exit 1
fi
log_msg "SMB share is mounted and readable"

log_msg "Check 6/10: Verifying collected binlogs exist on the share..."
if [[ ! -d "$SMB_BINLOG_DIR" ]]; then
  log_error "Binlog directory not found on the share: $SMB_BINLOG_DIR"
  log_error "binlog_collect.sh has not collected anything for this backup."
  trap - ERR INT TERM
  exit 1
fi
SMB_BINLOG_COUNT=$(find "$SMB_BINLOG_DIR" -maxdepth 1 -type f -name "$BINLOG_GLOB" 2>/dev/null | wc -l)
if [[ $SMB_BINLOG_COUNT -eq 0 ]]; then
  log_error "No binlog files in: $SMB_BINLOG_DIR"
  trap - ERR INT TERM
  exit 1
fi
log_msg "Found $SMB_BINLOG_COUNT binlog file(s) on the share"

log_msg "Check 7/10: Resolving the backup anchor position..."
INFO_BINLOG="$(marker_get binlog_file)"
INFO_POS="$(marker_get binlog_pos)"

# The marker is authoritative: it records what was actually restored. The
# anchor file is only a fallback for markers written before this field existed.
if [[ -z "$INFO_BINLOG" || -z "$INFO_POS" ]]; then
  if [[ -s "$BINLOG_INFO_FILE" ]]; then
    INFO_BINLOG=$(awk '{print $1}' "$BINLOG_INFO_FILE")
    INFO_POS=$(awk '{print $2}' "$BINLOG_INFO_FILE")
    log_warn "Marker had no binlog anchor — fell back to $BINLOG_INFO_FILE"
  fi
fi

if [[ -z "$INFO_BINLOG" || -z "$INFO_POS" ]]; then
  log_error "Cannot determine the backup's binlog position."
  log_error "Checked the restore marker and $BINLOG_INFO_FILE"
  trap - ERR INT TERM
  exit 1
fi
if ! is_valid_binlog_name "$INFO_BINLOG"; then
  log_error "Backup anchor has an invalid binlog name: $INFO_BINLOG"
  trap - ERR INT TERM
  exit 1
fi
log_msg "Backup anchor: $INFO_BINLOG at position $INFO_POS"

log_msg "Check 8/10: Verifying MySQL is running..."
if ! is_mysql_running; then
  log_error "MySQL is not running. Run restore_full.sh $BACKUP_ID first."
  trap - ERR INT TERM
  exit 1
fi
if ! test_mysql_connection; then
  log_error "Cannot connect to MySQL. Check the credentials in this script."
  trap - ERR INT TERM
  exit 1
fi
log_msg "MySQL is running and reachable"

log_msg "Check 9/10: Checking local staging space..."
SMB_BINLOG_BYTES=$(du -sb "$SMB_BINLOG_DIR" 2>/dev/null | awk '{print $1}')
SMB_BINLOG_GB=$((SMB_BINLOG_BYTES / 1024 / 1024 / 1024 + 1))
STAGE_FREE=$(df -BG "$LOCAL_STAGE" | awk 'NR==2 {print $4}' | sed 's/G//')
log_msg "Binlogs: ~${SMB_BINLOG_GB}GB, free in $LOCAL_STAGE: ${STAGE_FREE}GB"
if [[ $STAGE_FREE -lt $SMB_BINLOG_GB ]]; then
  log_error "Insufficient local space to stage the binlogs"
  log_error "Required: ${SMB_BINLOG_GB}GB, Available: ${STAGE_FREE}GB"
  trap - ERR INT TERM
  exit 1
fi

if [[ -n "$OVERRIDE_START_BINLOG" ]]; then
  log_msg "Check 10/10: Verifying the --from file exists..."
  if [[ ! -f "$SMB_BINLOG_DIR/$OVERRIDE_START_BINLOG" ]]; then
    log_error "--from file not found: $SMB_BINLOG_DIR/$OVERRIDE_START_BINLOG"
    log_error "Available:"
    find "$SMB_BINLOG_DIR" -maxdepth 1 -type f -name "$BINLOG_GLOB" | sort | while read -r f; do
      log_error "  $(basename "$f")"
    done
    trap - ERR INT TERM
    exit 1
  fi
  log_msg "--from file verified: $OVERRIDE_START_BINLOG"
else
  log_msg "Check 10/10: No --from override (skipped)"
fi

log_msg "===================================================="
log_msg "All pre-flight checks passed"
log_msg "===================================================="

############################
# STAGE BINLOGS TO LOCAL DISK
# `mysqlbinlog <path> | mysql` is a live pipe held open for the whole file. On
# CIFS a stall breaks it mid-transaction-stream — the exact failure a one-shot
# apply cannot recover from. Copying first takes the network off that path.
############################

log_msg "Staging binlogs from the share to local disk..."

rm -rf "$LOCAL_BINLOG_DIR" 2>/dev/null || true
if ! mkdir -p "$LOCAL_BINLOG_DIR" 2>/dev/null; then
  log_error "Failed to create local binlog staging directory: $LOCAL_BINLOG_DIR"
  trap - ERR INT TERM
  exit 1
fi

# Only the binlogs and their checksum file; last_copied_binlog and any stray
# files stay behind. rsync is preferred but optional — a missing convenience
# tool must not block recovery, and the verification below runs either way.
STAGE_OK=false
if command -v rsync >/dev/null 2>&1; then
  log_msg "Staging method: rsync"
  if rsync -a \
        --include="${BINLOG_PREFIX}.[0-9][0-9][0-9][0-9][0-9][0-9]" \
        --include="binlog.sha256" \
        --exclude='*' \
        "${SMB_BINLOG_DIR}/" "${LOCAL_BINLOG_DIR}/" 2>>"$ERROR_LOG"; then
    STAGE_OK=true
  fi
else
  log_warn "rsync not installed — falling back to cp"
  if find "$SMB_BINLOG_DIR" -maxdepth 1 -type f -name "$BINLOG_GLOB" \
       -exec cp {} "${LOCAL_BINLOG_DIR}/" \; 2>>"$ERROR_LOG"; then
    # The checksum file is optional; older collections predate it.
    cp "${SMB_BINLOG_DIR}/binlog.sha256" "${LOCAL_BINLOG_DIR}/" 2>/dev/null || true
    STAGE_OK=true
  fi
fi

if [[ "$STAGE_OK" != true ]]; then
  log_error "Failed to stage binlogs from the share"
  trap - ERR INT TERM
  exit 1
fi
sync
log_msg "Binlogs staged to: $LOCAL_BINLOG_DIR"

# Against the checksums recorded at collection time — the only check that
# catches a binlog which rotted on the share since it was collected.
if [[ -f "${LOCAL_BINLOG_DIR}/binlog.sha256" ]]; then
  log_msg "Verifying staged binlogs against collection-time checksums..."
  if ! (cd "$LOCAL_BINLOG_DIR" && sha256sum -c --quiet binlog.sha256) 2>>"$ERROR_LOG"; then
    log_error "===================================================="
    log_error "BINLOG CHECKSUM VERIFICATION FAILED"
    log_error "===================================================="
    log_error "At least one binlog does not match what was recorded when it was"
    log_error "collected. It has been corrupted on the share or in transit."
    log_error "Applying it would inject corrupt data. Refusing."
    log_error "See: $ERROR_LOG"
    log_error "===================================================="
    trap - ERR INT TERM
    exit 1
  fi
  log_msg "All staged binlogs verified against their recorded checksums"
else
  log_warn "No binlog.sha256 on the share — these binlogs predate checksum"
  log_warn "recording. Integrity cannot be verified. Proceeding."
fi

############################
# SEQUENCE CONTINUITY PRECHECK
# A gap does NOT error during replay: the database comes up looking healthy
# while every transaction in the hole is missing. Caught before anything is
# applied, because nothing downstream can detect it.
############################

log_msg "Verifying binlog sequence continuity..."

GAP_FOUND=false
PREV_SEQ=""
while read -r f; do
  # Strip leading zeros: bash arithmetic treats 000042 as OCTAL, and 000008 is
  # an invalid octal literal outright.
  SEQ="$(basename "$f" | awk -F. '{print $NF}' | sed 's/^0*//')"
  SEQ="${SEQ:-0}"
  if [[ -n "$PREV_SEQ" && $((PREV_SEQ + 1)) -ne $SEQ ]]; then
    log_error "SEQUENCE GAP: binlog $PREV_SEQ is followed by $SEQ (missing $((PREV_SEQ + 1)))"
    GAP_FOUND=true
  fi
  PREV_SEQ="$SEQ"
done < <(find "$LOCAL_BINLOG_DIR" -maxdepth 1 -type f -name "$BINLOG_GLOB" 2>/dev/null | sort)

if [[ "$GAP_FOUND" == true ]]; then
  log_warn "===================================================="
  log_warn "GAP IN THE BINLOG SEQUENCE — CONTINUING ANYWAY"
  log_warn "===================================================="
  log_warn "One or more binlogs listed above are missing from the archive."
  log_warn ""
  log_warn "Replay does NOT error on a gap. Every transaction in the missing"
  log_warn "range will simply be absent, and the database will come up looking"
  log_warn "perfectly healthy. THAT DATA IS LOST."
  log_warn ""
  log_warn "The usual cause is MySQL purging a binlog before the collector"
  log_warn "copied it. Prevent it by raising binlog_expire_logs_seconds to at"
  log_warn "least 3x your backup duration."
  log_warn ""
  log_warn "If losing that range is NOT acceptable, press Ctrl+C NOW and check"
  log_warn "whether the missing binlogs still exist on the source server."
  log_warn "===================================================="
else
  log_msg "Binlog sequence is continuous — no gaps"
fi

############################
# RESOLVE START BINLOG AND POSITION
#   no --from            -> anchor file at the anchor position (no gap, no dup)
#   --from, other file   -> that file at position 4 (whole file)
#   --from, SAME file    -> that file at the ANCHOR position, not 4, or the
#                           transactions already inside the full backup replay
############################

log_msg "===================================================="
log_msg "Resolving start position..."
log_msg "===================================================="

if [[ -z "$OVERRIDE_START_BINLOG" ]]; then
  START_BINLOG="$INFO_BINLOG"
  START_POS="$INFO_POS"
  log_msg "Mode           : Default (backup anchor)"
  log_msg "Start binlog   : $START_BINLOG"
  log_msg "Start position : $START_POS"

elif [[ "$OVERRIDE_START_BINLOG" != "$INFO_BINLOG" ]]; then
  START_BINLOG="$OVERRIDE_START_BINLOG"
  START_POS="$BINLOG_FILE_START_POS"
  log_msg "Mode           : Override (--from, different file)"
  log_msg "Start binlog   : $START_BINLOG"
  log_msg "Start position : $START_POS (position 4 = whole file)"
  log_msg "Backup anchor  : $INFO_BINLOG at $INFO_POS"

else
  START_BINLOG="$OVERRIDE_START_BINLOG"
  START_POS="$INFO_POS"
  log_warn "===================================================="
  log_warn "EDGE CASE DETECTED"
  log_warn "===================================================="
  log_warn "--from ($OVERRIDE_START_BINLOG) is the SAME file as the backup anchor."
  log_warn "The full backup already contains this file up to position $INFO_POS."
  log_warn "Applying from position 4 would re-apply those transactions."
  log_warn "Using position $INFO_POS instead to prevent duplicates."
  log_warn "===================================================="
  log_msg "Mode           : Override (--from, same file — edge case handled)"
  log_msg "Start binlog   : $START_BINLOG"
  log_msg "Start position : $START_POS (anchor position, not 4)"
fi

############################
# BUILD THE APPLY LIST
############################

mapfile -t BINLOG_FILES < <(
  find "$LOCAL_BINLOG_DIR" -maxdepth 1 -type f -name "$BINLOG_GLOB" 2>/dev/null \
    -printf '%f\n' | sort
)

if [[ ${#BINLOG_FILES[@]} -eq 0 ]]; then
  log_error "No binlog files staged locally"
  trap - ERR INT TERM
  exit 1
fi

# Checked before anything is applied, not discovered after a partial apply.
START_PRESENT=false
for f in "${BINLOG_FILES[@]}"; do
  [[ "$f" == "$START_BINLOG" ]] && START_PRESENT=true && break
done
if [[ "$START_PRESENT" != true ]]; then
  log_error "Start binlog '$START_BINLOG' is not among the collected binlogs."
  log_error "Available:"
  for f in "${BINLOG_FILES[@]}"; do log_error "  $f"; done
  trap - ERR INT TERM
  exit 1
fi

APPLY_LIST=()
FOUND=false
for f in "${BINLOG_FILES[@]}"; do
  is_valid_binlog_name "$f" || continue
  [[ "$f" == "$START_BINLOG" ]] && FOUND=true
  [[ "$FOUND" == true ]] && APPLY_LIST+=("$f")
done

log_msg "${#APPLY_LIST[@]} binlog file(s) will be applied, starting at $START_BINLOG"

############################
# DRY RUN
# Decodes exactly what WOULD be applied without touching the database — the
# only chance to notice a DROP or TRUNCATE before it executes.
############################

if [[ $DRY_RUN -eq 1 ]]; then
  DRY_OUT="${LOCAL_STAGE}/${BACKUP_ID}_binlog_preview.sql"
  log_msg "===================================================="
  log_msg "DRY RUN — decoding, applying NOTHING"
  log_msg "===================================================="

  APPLY_PATHS=()
  for f in "${APPLY_LIST[@]}"; do
    APPLY_PATHS+=("$LOCAL_BINLOG_DIR/$f")
  done

  if ! "$MYSQLBINLOG_BIN" --start-position="$START_POS" "${APPLY_PATHS[@]}" > "$DRY_OUT" 2>>"$ERROR_LOG"; then
    log_error "Failed to decode the binlogs for preview. See: $ERROR_LOG"
    trap - ERR INT TERM
    exit 1
  fi

  PREVIEW_SIZE=$(du -sh "$DRY_OUT" | awk '{print $1}')
  ROW_EVENTS=$(grep -c '^### ' "$DRY_OUT" 2>/dev/null || echo 0)

  {
    echo ""
    echo "===================================================="
    echo "DRY RUN COMPLETE — NOTHING WAS APPLIED"
    echo "===================================================="
    echo "Backup ID      : $BACKUP_ID"
    echo "Start binlog   : $START_BINLOG at position $START_POS"
    echo "Files in scope : ${#APPLY_LIST[@]}"
    echo "Preview file   : $DRY_OUT ($PREVIEW_SIZE)"
    echo "Row events     : $ROW_EVENTS"
    echo "===================================================="
    echo "Destructive statements found (first 20):"
  } | tee -a "$RUN_LOG"

  # || true: grep exits 1 when it finds nothing, which is the good outcome here.
  DESTRUCTIVE=$(grep -inE '^[[:space:]]*(DROP|TRUNCATE|ALTER)[[:space:]]' "$DRY_OUT" | head -20 || true)
  if [[ -n "$DESTRUCTIVE" ]]; then
    echo "$DESTRUCTIVE" | tee -a "$RUN_LOG"
    echo "" | tee -a "$RUN_LOG"
    log_warn "Destructive statements are present in these binlogs."
    log_warn "If the incident you are recovering from WAS one of these, applying"
    log_warn "everything will re-execute it. Consider --from / a narrower range."
  else
    echo "  (none)" | tee -a "$RUN_LOG"
  fi

  {
    echo "===================================================="
    echo "To apply for real:"
    echo "  $0 $BACKUP_ID${OVERRIDE_START_BINLOG:+ --from $OVERRIDE_START_BINLOG}"
    echo "===================================================="
  } | tee -a "$RUN_LOG"

  rm -rf "$LOCAL_BINLOG_DIR" 2>/dev/null || true
  trap - ERR INT TERM
  exit 0
fi

############################
# APPLY
############################

{
  echo ""
  echo "===================================================="
  echo "BINLOG APPLY STARTED"
  echo "===================================================="
  echo "Start time     : $START_TIME"
  echo "Backup ID      : $BACKUP_ID"
  echo "Binlog source  : $LOCAL_BINLOG_DIR (staged from the share)"
  echo "Start binlog   : $START_BINLOG at position $START_POS"
  echo "Files to apply : ${#APPLY_LIST[@]}"
  echo "===================================================="
  echo ""
} | tee -a "$RUN_LOG"

# Everything after the failed file is deliberately NOT applied.
halt_on_apply_failure() {
  local failed_file="$1" failed_pos="$2"
  log_error "===================================================="
  log_error "FAILED APPLYING $failed_file${failed_pos:+ from position $failed_pos}"
  log_error "HALTING. Later binlogs were NOT applied."
  log_error "===================================================="
  log_error "This instance is in a PARTIALLY APPLIED state."
  log_error "Applied $APPLIED_COUNT of ${#APPLY_LIST[@]} file(s); last good: ${LAST_APPLIED:-none}"
  log_error ""
  log_error "Recovery here is file+position only (GTID is off), so this apply"
  log_error "CANNOT be resumed. Continuing from the failed file would duplicate"
  log_error "data; skipping it would lose data. Neither is acceptable."
  log_error ""
  log_error "Correct action:"
  log_error "  1. Do NOT let applications use this server — the data is incomplete"
  log_error "  2. Inspect the cause: $ERROR_LOG"
  log_error "  3. Roll back:  ./restore_full.sh $BACKUP_ID"
  log_error "     (re-reads the full archive from the share — allow for the transfer time)"
  log_error "  4. Fix the cause, then run this script again"
  log_error "===================================================="
  trap - ERR INT TERM
  exit 1
}

for BINLOG_FILE in "${APPLY_LIST[@]}"; do
  BINLOG_PATH="$LOCAL_BINLOG_DIR/$BINLOG_FILE"

  if [[ "$BINLOG_FILE" == "$START_BINLOG" ]]; then
    log_msg "----------------------------------------------------"
    log_msg "Applying: $BINLOG_FILE (from position $START_POS)"
    log_msg "----------------------------------------------------"

    # --disable-log-bin: replayed events must not be written back into this
    # server's own binlog, or the next backup's chain contains them twice.
    # --skip-gtids is deliberately NOT passed — gtid_mode is OFF, so it would
    # be a no-op that implies duplicate protection this setup does not have.
    if ! "$MYSQLBINLOG_BIN" \
        --disable-log-bin \
        --start-position="$START_POS" \
        "$BINLOG_PATH" 2>>"$ERROR_LOG" \
        | mysql_cmd 2>>"$ERROR_LOG"; then
      halt_on_apply_failure "$BINLOG_FILE" "$START_POS"
    fi
  else
    log_msg "----------------------------------------------------"
    log_msg "Applying: $BINLOG_FILE (whole file)"
    log_msg "----------------------------------------------------"

    if ! "$MYSQLBINLOG_BIN" \
        --disable-log-bin \
        "$BINLOG_PATH" 2>>"$ERROR_LOG" \
        | mysql_cmd 2>>"$ERROR_LOG"; then
      halt_on_apply_failure "$BINLOG_FILE" ""
    fi
  fi

  APPLIED_COUNT=$((APPLIED_COUNT + 1))
  LAST_APPLIED="$BINLOG_FILE"
  log_msg "Applied: $BINLOG_FILE"
done

############################
# POST-APPLY VALIDATION
############################

log_msg "Verifying MySQL is still healthy after the apply..."
if ! is_mysql_running; then
  log_error "MySQL is not running after the binlog apply"
  trap - ERR INT TERM
  exit 1
fi
if ! test_mysql_connection; then
  log_error "Cannot connect to MySQL after the binlog apply"
  trap - ERR INT TERM
  exit 1
fi

DB_COUNT=$(mysql_cmd -NBe "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema','mysql','performance_schema','sys')" 2>>"$ERROR_LOG" || echo "0")

############################
# RECORD THE APPLY
# This is what makes Check 4 refuse a second run, so it must land immediately
# after success, before anything else can be attempted.
############################

if ! sed -i "s/^binlogs_applied=.*/binlogs_applied=yes/" "$RESTORE_MARKER" 2>>"$ERROR_LOG"; then
  log_error "CRITICAL: could not update the restore marker: $RESTORE_MARKER"
  log_error "The apply SUCCEEDED, but a second run would no longer be refused."
  log_error "Fix this by hand NOW: set binlogs_applied=yes in that file."
  trap - ERR INT TERM
  exit 1
fi

{
  echo "applied_at=$(date '+%F %T')"
  echo "last_applied_binlog=${LAST_APPLIED}"
  echo "files_applied=${APPLIED_COUNT}"
} >> "$RESTORE_MARKER"

log_msg "Restore marker updated: binlogs_applied=yes"

# Staged copies are disposable — the originals remain on the share.
rm -rf "$LOCAL_BINLOG_DIR" 2>/dev/null || true

############################
# COMPLETE
############################

END_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
END_EPOCH="$(date +%s)"
DURATION=$((END_EPOCH - START_EPOCH))

{
  echo ""
  echo "===================================================="
  echo "BINLOG APPLY COMPLETED"
  echo "===================================================="
  echo "Start time      : $START_TIME"
  echo "End time        : $END_TIME"
  echo "Duration        : $((DURATION / 60))m $((DURATION % 60))s"
  echo "Backup ID       : $BACKUP_ID"
  echo "Start binlog    : $START_BINLOG at position $START_POS"
  echo "Files applied   : $APPLIED_COUNT"
  echo "Last applied    : $LAST_APPLIED"
  echo "User databases  : $DB_COUNT"
  echo "===================================================="
  echo "REMAINING STEPS — DO THESE IN ORDER"
  echo "===================================================="
  echo "1. VERIFY the data:"
  echo "     row counts on your busiest tables, application smoke tests"
  echo ""
  echo "2. TAKE A FRESH FULL BACKUP IMMEDIATELY:"
  echo "     ./backup.sh"
  echo "   The binlog chain restarts at this recovery point. Until a new full"
  echo "   backup exists, this server has no usable recovery baseline."
  echo "===================================================="
  echo "Log files:"
  echo "  Main log      : $RUN_LOG"
  echo "  Error log     : $ERROR_LOG"
  echo "===================================================="
} | tee -a "$RUN_LOG"

# Best-effort log publish to the share.
if mountpoint -q "$SMB_MOUNT_POINT" 2>/dev/null && mkdir -p "$SECONDARY_LOG_DIR" 2>/dev/null; then
  cp "$RUN_LOG" "${SECONDARY_LOG_DIR}/apply.log" 2>/dev/null || true
  cp "$ERROR_LOG" "${SECONDARY_LOG_DIR}/apply_errors.log" 2>/dev/null || true
  log_msg "Logs published to: $SECONDARY_LOG_DIR"
fi

trap - ERR INT TERM
exit 0
