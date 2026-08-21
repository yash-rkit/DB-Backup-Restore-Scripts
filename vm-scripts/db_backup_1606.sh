#!/bin/bash
#
# db_backup.sh
#
# Takes per-database mysqldump backups and manages InnoDB buffer pool cleanup.
# This script does NOT delete anything. Retention is handled by db_cleanup.sh.
#
# Backup mode:
#   BACKUP_MODE=ALL       -> backs up every non-system database
#   BACKUP_MODE=SELECTED  -> backs up only databases listed in the latest file
#                            found inside DB_LIST_DIR
#
set -euo pipefail

# =============================================================================
# REGION 1: CONFIGURATION
# =============================================================================

# --- MySQL connection ---
MYSQL_USER="Admin"
MYSQL_PASSWORD=""
MYSQL_HOST="20.20.15.4"

# --- Set via --server_name / --base_dir (see REGION 1B) ---
SERVER_NAME=""
BASE_DIR=""

# --- Lock file (single global lock; prevents any two runs overlapping) ---
LOCKFILE="/var/run/dbbackup.lock"

# --- Backup mode ---
BACKUP_MODE="ALL"       # ALL or SELECTED
DB_LIST_DIR=""   # folder containing DB list files (latest file picked automatically)

# --- Dump behaviour ---
PARALLEL=3
DUMP_OPTS="--single-transaction --quick --routines --events --triggers --set-gtid-purged=OFF --net-buffer-length=1M"

# --- Buffer pool sizes (bytes) ---
BP_SHRINK_SIZE=17179869184   # 16 GB (temporary floor to flush polluted pages)
BP_NORMAL_SIZE=38654705664   # 36 GB (normal operating size)

# --- Resize limits ---
BP_RESIZE_TIMEOUT=120        # max seconds to wait for one resize

# --- Derived (do not edit) ---
TS="$(date +'%Y-%m-%d_%H-%M-%S')"

# =============================================================================
# REGION 1B: ARGUMENT PARSING
# =============================================================================

show_usage() {
  echo "Usage: $0 --base_dir=PATH [--server_name=NAME]"
  echo ""
  echo "  --base_dir=PATH     :  Root path where per-database archives and logs are written"
  echo "  --server_name=NAME  :  Identifier for the source server (used in logs)"
  exit 1
}

for arg in "$@"; do
  case "$arg" in
    --base_dir=*)     BASE_DIR="${arg#*=}" ;;
    --server_name=*)  SERVER_NAME="${arg#*=}" ;;
    -h|--help)        show_usage ;;
    *)
      echo "Unknown argument: $arg" >&2
      show_usage
      ;;
  esac
done

[[ -n "$BASE_DIR" ]] || { echo "--base_dir is required" >&2; exit 1; }

BACKUP_DIR="$BASE_DIR"
LOG_DIR="$BASE_DIR/logs"
LOG_FILE="$LOG_DIR/backup_$(date +'%Y%m%d').log"

# =============================================================================
# REGION 2: LOGGING
# =============================================================================

_log() {
  local level="$1"; shift
  printf '%s [%-5s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$level" "$*" | tee -a "$LOG_FILE"
}
log_info()  { _log "INFO"  "$@"; }
log_warn()  { _log "WARN"  "$@"; }
log_error() { _log "ERROR" "$@"; }
log_step()  { printf '\n' | tee -a "$LOG_FILE"; _log "STEP"  "==== $* ===="; }

# Convert bytes to human-readable GB
bytes_to_gb() { awk -v b="$1" 'BEGIN{ printf "%.0f", b/1073741824 }'; }

# =============================================================================
# REGION 3: MYSQL HELPERS
# =============================================================================

# All helpers suppress stderr to avoid "Using a password on the command line" noise.
# Exit codes still propagate; set -e catches real failures.

mysql_val() { mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -N -B -e "$1" 2>/dev/null; }
mysql_run() { mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -e "$1" 2>/dev/null; }

# =============================================================================
# REGION 4: BUFFER POOL FUNCTIONS
# =============================================================================

# Print buffer pool page counts
bp_stats() {
  log_info "Buffer pool state:"
  mysql_run "
    SELECT
      (SELECT VARIABLE_VALUE FROM performance_schema.global_status
       WHERE VARIABLE_NAME = 'Innodb_buffer_pool_pages_total') AS 'Total_Pages',
      (SELECT VARIABLE_VALUE FROM performance_schema.global_status
       WHERE VARIABLE_NAME = 'Innodb_buffer_pool_pages_data') AS 'Data_Pages',
      (SELECT VARIABLE_VALUE FROM performance_schema.global_status
       WHERE VARIABLE_NAME = 'Innodb_buffer_pool_pages_free') AS 'Free_Pages',
      (SELECT VARIABLE_VALUE FROM performance_schema.global_status
       WHERE VARIABLE_NAME = 'Innodb_buffer_pool_pages_dirty') AS 'Dirty_Pages';
  " | tee -a "$LOG_FILE"
}

# Save hot page list to disk before backup starts
bp_save_pages() {
  log_info "Saving InnoDB buffer pool page list..."
  mysql_run "SET GLOBAL innodb_buffer_pool_dump_now = ON;"
  sleep 5
  local st
  st=$(mysql_val "SHOW STATUS LIKE 'Innodb_buffer_pool_dump_status';")
  log_info "Buffer pool dump status: $st"
}

# Shrink buffer pool to release polluted pages
bp_shrink() {
  log_info "Shrinking buffer pool to $(bytes_to_gb "$BP_SHRINK_SIZE") GB..."
  mysql_run "SET GLOBAL innodb_buffer_pool_size = $BP_SHRINK_SIZE;"

  local waited=0 cur
  while [ "$waited" -lt "$BP_RESIZE_TIMEOUT" ]; do
    sleep 5
    waited=$((waited + 5))
    cur=$(mysql_val "SELECT @@innodb_buffer_pool_size;")
    if [ "$cur" = "$BP_SHRINK_SIZE" ]; then
      log_info "Shrink complete (${waited}s)."
      return 0
    fi
    log_info "  ...shrinking (${waited}s)"
  done
  log_warn "Shrink did not complete within ${BP_RESIZE_TIMEOUT}s."
}

# Restore buffer pool to normal operating size
bp_expand() {
  log_info "Restoring buffer pool to $(bytes_to_gb "$BP_NORMAL_SIZE") GB..."
  mysql_run "SET GLOBAL innodb_buffer_pool_size = $BP_NORMAL_SIZE;"

  local waited=0 cur
  while [ "$waited" -lt "$BP_RESIZE_TIMEOUT" ]; do
    sleep 5
    waited=$((waited + 5))
    cur=$(mysql_val "SELECT @@innodb_buffer_pool_size;")
    if [ "$cur" = "$BP_NORMAL_SIZE" ]; then
      log_info "Restore complete (${waited}s)."
      return 0
    fi
    log_info "  ...restoring (${waited}s)"
  done
  log_warn "Restore did not complete within ${BP_RESIZE_TIMEOUT}s."
}

# Reload saved hot pages
bp_load_pages() {
  log_info "Reloading warm pages..."
  mysql_run "SET GLOBAL innodb_buffer_pool_load_now = ON;"

  local waited=0 st
  while [ "$waited" -lt 120 ]; do
    sleep 5
    waited=$((waited + 5))
    st=$(mysql_val "SHOW STATUS LIKE 'Innodb_buffer_pool_load_status';")
    case "$st" in
      *"load completed"*) log_info "Warm-page reload complete ($st)."; return 0 ;;
    esac
    log_info "  ...loading (${waited}s)"
  done
  log_warn "Warm-page reload still running after 120s (continues in background)."
}

# =============================================================================
# REGION 5: BACKUP FUNCTION (runs in parallel via xargs)
# =============================================================================

dump_one() {
  local DB="$1"
  local DB_DIR="$BACKUP_DIR/$DB"
  local SQL_FILE="$DB_DIR/${DB}_${TS}.sql"
  local ARCHIVE_FILE="$DB_DIR/${DB}_${TS}.tar.gz"
  local DUMP_ERR="$DB_DIR/.dump_err_$$"

  mkdir -p "$DB_DIR"
  log_info "[$DB] start -> ${DB}/${DB}_${TS}.tar.gz"

  # Dump database; capture stderr so we can log the real error (not the password warning)
  if ! nice -n 19 ionice -c2 -n7 \
       mysqldump -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" \
       $DUMP_OPTS --databases "$DB" > "$SQL_FILE" 2>"$DUMP_ERR"; then
    local reason
    reason=$(grep -v '\[Warning\].*password' "$DUMP_ERR" | head -1)
    log_error "[$DB] mysqldump FAILED: ${reason:-unknown error}"
    rm -f "$DUMP_ERR" "$SQL_FILE"
    echo "$DB" >> "$FAIL_FLAG"
    return 0
  fi
  rm -f "$DUMP_ERR"

  # Guard against empty dumps
  if [ ! -s "$SQL_FILE" ]; then
    log_error "[$DB] dump is empty, skipping archive"
    echo "$DB" >> "$FAIL_FLAG"
    return 0
  fi

  # Flush writes to disk before archiving (prevents "file changed as we read it" on network storage)
  sync "$SQL_FILE"
  tar -czf "$ARCHIVE_FILE" -C "$DB_DIR" "${DB}_${TS}.sql"
  rm -f "$SQL_FILE"

  sha256sum "$ARCHIVE_FILE" > "$ARCHIVE_FILE.sha256"

  local size
  size=$(du -h "$ARCHIVE_FILE" | cut -f1)
  log_info "[$DB] done (size=$size)"
}

# =============================================================================
# REGION 6: MAIN
# =============================================================================

mkdir -p "$BACKUP_DIR" "$LOG_DIR"

# --- Single-instance lock ---
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  log_warn "Another backup is already running, exiting."
  exit 0
fi

log_step "BACKUP RUN START (server=$SERVER_NAME, parallel=$PARALLEL, mode=$BACKUP_MODE)"
log_info "Base path: $BASE_DIR"

# --- Sanity checks ---
command -v mysqldump >/dev/null || { log_error "mysqldump not found"; exit 1; }
command -v tar       >/dev/null || { log_error "tar not found"; exit 1; }

# --- Build database list ---
if [ "$BACKUP_MODE" = "ALL" ]; then
  DATABASES=$(mysql_val "SHOW DATABASES" | grep -Ev "^(information_schema|performance_schema|mysql|sys)$")
elif [ "$BACKUP_MODE" = "SELECTED" ]; then
  [ -n "$DB_LIST_DIR" ] || { log_error "BACKUP_MODE=SELECTED but DB_LIST_DIR is empty"; exit 1; }
  [ -d "$DB_LIST_DIR" ] || { log_error "DB_LIST_DIR not a directory: $DB_LIST_DIR"; exit 1; }

  # Pick the latest file in the folder (by modification time)
  DB_LIST_FILE=$(find "$DB_LIST_DIR" -maxdepth 1 -type f \( -name '*.txt' -o -name '*.csv' -o -name '*.lst' \) -printf '%T@ %p\n' 2>/dev/null \
                 | sort -rn | head -1 | cut -d' ' -f2-)

  [ -n "$DB_LIST_FILE" ] || { log_error "No list files (.txt/.csv/.lst) found in $DB_LIST_DIR"; exit 1; }
  [ -r "$DB_LIST_FILE" ] || { log_error "Latest file not readable: $DB_LIST_FILE"; exit 1; }

  log_info "Using DB list file: $DB_LIST_FILE"

  # Read file, skip blank lines and comments
  DATABASES=$(grep -vE '^\s*$|^\s*#' "$DB_LIST_FILE")
else
  log_error "Invalid BACKUP_MODE: $BACKUP_MODE (must be ALL or SELECTED)"; exit 1
fi

DB_COUNT=$(echo "$DATABASES" | wc -l)
log_info "Databases ($DB_COUNT): $(echo "$DATABASES" | tr '\n' ' ')"

# --- Save warm page list before dumps ---
log_step "SAVE BUFFER POOL STATE"
#bp_save_pages

# --- Run backups in parallel ---
log_step "DUMP DATABASES"
FAIL_FLAG="$(mktemp /tmp/.dbbackup_fail.XXXXXX)"
export -f dump_one _log log_info log_warn log_error
export BACKUP_DIR LOG_FILE TS DUMP_OPTS MYSQL_USER MYSQL_PASSWORD MYSQL_HOST FAIL_FLAG

echo "$DATABASES" | xargs -r -n1 -P "$PARALLEL" bash -c 'dump_one "$@"' _ || true

if [ -s "$FAIL_FLAG" ]; then
  log_error "Failed databases: $(tr '\n' ' ' < "$FAIL_FLAG")"
else
  log_info "All databases dumped successfully."
fi
rm -f "$FAIL_FLAG"

# =============================================================================
# REGION 7: BUFFER POOL CLEANUP (shrink to release polluted pages, then expand)
# =============================================================================

log_step "BUFFER POOL CLEANUP"

#bp_stats

#bp_shrink
#sleep 7
#bp_expand

#bp_load_pages

#bp_stats

log_step "BACKUP RUN FINISHED"
