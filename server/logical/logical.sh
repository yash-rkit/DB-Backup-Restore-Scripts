#!/bin/bash
#
# server/logical/logical.sh — per-database logical backup (mysqldump)
#
# Docs: instructions/server/logical/README.md
#
set -euo pipefail

# =============================================================================
# REGION 1: CONFIGURATION
# =============================================================================

# --- MySQL connection ---
MYSQL_USER="Admin"
MYSQL_PASSWORD=""
MYSQL_HOST="20.20.15.4"

# --- Identity and destination ---
SERVER_NAME="Cloud-Live-DB-Restore"
BASE_DIR="/livestorage/YK/Logical/$SERVER_NAME"

# --- Backup mode ---
BACKUP_MODE="ALL"       # ALL or SELECTED
DB_LIST_DIR=""          # SELECTED only: folder of .txt/.csv/.lst list files

# --- Dump behaviour ---
PARALLEL=3

# --hex-blob is deliberately NOT set: no binary columns in these schemas.
# Add it back if any are introduced.
DUMP_OPTS="--single-transaction --quick --routines --events --triggers \
--set-gtid-purged=OFF --default-character-set=utf8mb4 \
--net-buffer-length=1M"

# Percentage of the live data size that must be free before starting.
SPACE_REQUIRED_PCT=60

# --- Buffer pool sizes (bytes) ---
BP_SHRINK_SIZE=17179869184   # 16 GB (temporary floor to flush polluted pages)
BP_NORMAL_SIZE=38654705664   # 36 GB (normal operating size)
BP_RESIZE_TIMEOUT=120        # max seconds to wait for one resize

# --- Derived (do not edit) ---
# Date alone; a time is appended by the collision check in REGION 7.
TS="$(date +'%Y-%m-%d')"
RUN_STARTED_AT="$(date +'%Y-%m-%d %H:%M:%S')"

BACKUP_DIR="$BASE_DIR"
LOG_DIR="$BASE_DIR/logs"
LOG_FILE="$LOG_DIR/backup_$(date +'%Y%m%d').log"
MANIFEST_DIR="$BASE_DIR/manifests"

# Per-destination, not global: two BASE_DIR targets on one host must not block
# each other.
LOCKFILE="/var/run/dbbackup_$(basename "$BASE_DIR").lock"

DB_COUNT=0
OK_COUNT=0
FAILED_COUNT=0
FAILED_LIST=""
SOURCE_DATA_OPT=""

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

bytes_to_gb() { awk -v b="$1" 'BEGIN{ printf "%.0f", b/1073741824 }'; }

# =============================================================================
# REGION 3: MYSQL HELPERS
# =============================================================================

# stderr goes to the log, not /dev/null: an empty result must be
# distinguishable from a failed connection.
mysql_val() { mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -N -B -e "$1" 2>>"$LOG_FILE"; }
mysql_run() { mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -e "$1" 2>>"$LOG_FILE"; }

# =============================================================================
# REGION 4: BUFFER POOL FUNCTIONS
# =============================================================================

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

bp_save_pages() {
  log_info "Saving InnoDB buffer pool page list..."
  mysql_run "SET GLOBAL innodb_buffer_pool_dump_now = ON;"
  sleep 5
  local st
  st=$(mysql_val "SHOW STATUS LIKE 'Innodb_buffer_pool_dump_status';")
  log_info "Buffer pool dump status: $st"
}

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
# REGION 5: MANIFEST
# =============================================================================

# Written on both the success and failure paths.
write_manifest() {
  mkdir -p "$MANIFEST_DIR" 2>/dev/null || {
    log_warn "Cannot create manifest directory: $MANIFEST_DIR"
    return 0
  }

  local mfile="${MANIFEST_DIR}/${TS}.manifest"
  cat > "$mfile" <<EOF
run_id=${TS}
server_name=${SERVER_NAME}
started_at=${RUN_STARTED_AT}
finished_at=$(date +'%Y-%m-%d %H:%M:%S')
backup_mode=${BACKUP_MODE}
mysql_host=${MYSQL_HOST}
mysql_version=$(mysql_val "SELECT VERSION()" 2>/dev/null || echo unknown)
character_set=$(mysql_val "SELECT @@character_set_server" 2>/dev/null || echo unknown)
db_count=${DB_COUNT}
ok_count=${OK_COUNT}
failed_count=${FAILED_COUNT}
failed_list=${FAILED_LIST}
dump_opts=${DUMP_OPTS} ${SOURCE_DATA_OPT}
recovery_method=logical_per_database
consistency=per_database_only
EOF
  log_info "Manifest written: $mfile"
}

# =============================================================================
# REGION 6: BACKUP FUNCTION (runs in parallel via xargs)
# =============================================================================

dump_one() {
  local DB="$1"
  local DB_DIR="$BACKUP_DIR/$DB"
  local SQL_FILE="$DB_DIR/${DB}_${TS}.sql"
  local ARCHIVE_FILE="$DB_DIR/${DB}_${TS}.tar.gz"
  local DUMP_ERR="$DB_DIR/.dump_err_$$"

  mkdir -p "$DB_DIR"
  log_info "[$DB] start -> ${DB}/${DB}_${TS}.tar.gz"

  # shellcheck disable=SC2086  # DUMP_OPTS is a deliberate word-split option list
  if ! nice -n 19 ionice -c2 -n7 \
       mysqldump -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" \
       $DUMP_OPTS $SOURCE_DATA_OPT --databases "$DB" > "$SQL_FILE" 2>"$DUMP_ERR"; then
    local reason
    reason=$(grep -v '\[Warning\].*password' "$DUMP_ERR" | head -1)
    log_error "[$DB] mysqldump FAILED: ${reason:-unknown error}"
    rm -f "$DUMP_ERR" "$SQL_FILE"
    echo "$DB" >> "$FAIL_FLAG"
    return 0
  fi
  rm -f "$DUMP_ERR"

  if [ ! -s "$SQL_FILE" ]; then
    log_error "[$DB] dump is empty, skipping archive"
    rm -f "$SQL_FILE"
    echo "$DB" >> "$FAIL_FLAG"
    return 0
  fi

  # Prevents "file changed as we read it" on network storage.
  sync "$SQL_FILE"

  if ! tar -czf "$ARCHIVE_FILE" -C "$DB_DIR" "${DB}_${TS}.sql" 2>>"$LOG_FILE"; then
    log_error "[$DB] tar failed"
    rm -f "$SQL_FILE" "$ARCHIVE_FILE"
    echo "$DB" >> "$FAIL_FLAG"
    return 0
  fi

  # Read the archive back before deleting the raw SQL it was built from.
  if ! tar -tzf "$ARCHIVE_FILE" >/dev/null 2>>"$LOG_FILE"; then
    log_error "[$DB] archive failed its integrity test, keeping raw SQL: $SQL_FILE"
    rm -f "$ARCHIVE_FILE"
    echo "$DB" >> "$FAIL_FLAG"
    return 0
  fi

  rm -f "$SQL_FILE"

  # Bare filename, not sha256sum's default absolute path, so `sha256sum -c`
  # survives the tree being moved or mounted elsewhere.
  sha256sum "$ARCHIVE_FILE" | awk -v f="${DB}_${TS}.tar.gz" '{print $1"  "f}' \
    > "$ARCHIVE_FILE.sha256"

  local size
  size=$(du -h "$ARCHIVE_FILE" | cut -f1)
  log_info "[$DB] done (size=$size)"
}

# =============================================================================
# REGION 7: MAIN
# =============================================================================

mkdir -p "$BACKUP_DIR" "$LOG_DIR"

# --- Single-instance lock ---
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  log_warn "Another backup is already running for $BASE_DIR, exiting."
  exit 0
fi

# --- Same-day collision check ---
# Must stay AFTER the lock, or two runs starting together both decide they are
# the first and `tar -czf` overwrites the earlier set.
if find "$BACKUP_DIR" -mindepth 2 -maxdepth 2 -type f -name "*_${TS}.tar.gz" -print -quit 2>/dev/null | grep -q .; then
  TS="${TS}_$(date +'%H-%M-%S')"
  log_warn "Archives for today already exist. Using timestamped run ID: $TS"
  log_warn "The earlier run's archives are left untouched."
fi

log_step "BACKUP RUN START (server=$SERVER_NAME, parallel=$PARALLEL, mode=$BACKUP_MODE)"
log_info "Base path: $BASE_DIR"
log_info "Run ID   : $TS"

# --- Sanity checks ---
command -v mysqldump >/dev/null || { log_error "mysqldump not found"; exit 1; }
command -v mysql     >/dev/null || { log_error "mysql client not found"; exit 1; }
command -v tar       >/dev/null || { log_error "tar not found"; exit 1; }
command -v sha256sum >/dev/null || { log_error "sha256sum not found"; exit 1; }

mysql_val "SELECT 1" >/dev/null || { log_error "Cannot connect to MySQL at $MYSQL_HOST"; exit 1; }

# --- Resolve the binlog-coordinate option ---
# MySQL renamed --master-data to --source-data in 8.0.26.
if mysqldump --help 2>/dev/null | grep -q -- '--source-data'; then
  SOURCE_DATA_OPT="--source-data=2"
elif mysqldump --help 2>/dev/null | grep -q -- '--master-data'; then
  SOURCE_DATA_OPT="--master-data=2"
  log_info "mysqldump predates --source-data, using --master-data=2"
else
  SOURCE_DATA_OPT=""
  log_warn "mysqldump supports neither --source-data nor --master-data."
  log_warn "Dumps will carry NO binlog coordinate and cannot anchor a PITR."
fi

# The option needs REPLICATION CLIENT (or BINLOG MONITOR). Test it once here,
# rather than discovering it as a per-database failure deep into the run.
if [[ -n "$SOURCE_DATA_OPT" ]]; then
  if mysql_val "SHOW BINARY LOG STATUS" >/dev/null 2>>"$LOG_FILE" \
     || mysql_val "SHOW MASTER STATUS" >/dev/null 2>>"$LOG_FILE"; then
    log_info "Binlog coordinate enabled: $SOURCE_DATA_OPT"
  else
    log_error "'$SOURCE_DATA_OPT' requires REPLICATION CLIENT (or BINLOG MONITOR)"
    log_error "on user '$MYSQL_USER', which it does not appear to have."
    log_error "Every dump would fail. Grant it, or clear SOURCE_DATA_OPT and accept"
    log_error "that the dumps carry no recovery coordinate."
    exit 1
  fi
fi

# --- Build database list ---
if [ "$BACKUP_MODE" = "ALL" ]; then
  DATABASES=$(mysql_val "SHOW DATABASES" | grep -Ev "^(information_schema|performance_schema|mysql|sys)$" || true)
elif [ "$BACKUP_MODE" = "SELECTED" ]; then
  [ -n "$DB_LIST_DIR" ] || { log_error "BACKUP_MODE=SELECTED but DB_LIST_DIR is empty"; exit 1; }
  [ -d "$DB_LIST_DIR" ] || { log_error "DB_LIST_DIR not a directory: $DB_LIST_DIR"; exit 1; }

  DB_LIST_FILE=$(find "$DB_LIST_DIR" -maxdepth 1 -type f \( -name '*.txt' -o -name '*.csv' -o -name '*.lst' \) -printf '%T@ %p\n' 2>/dev/null \
                 | sort -rn | head -1 | cut -d' ' -f2-)

  [ -n "$DB_LIST_FILE" ] || { log_error "No list files (.txt/.csv/.lst) found in $DB_LIST_DIR"; exit 1; }
  [ -r "$DB_LIST_FILE" ] || { log_error "Latest file not readable: $DB_LIST_FILE"; exit 1; }

  log_info "Using DB list file: $DB_LIST_FILE"
  DATABASES=$(grep -vE '^\s*$|^\s*#' "$DB_LIST_FILE" || true)
else
  log_error "Invalid BACKUP_MODE: $BACKUP_MODE (must be ALL or SELECTED)"; exit 1
fi

# Count non-blank lines: `wc -l` on an empty string returns 1, not 0.
DB_COUNT=$(printf '%s\n' "$DATABASES" | grep -c '[^[:space:]]' || true)

if [[ "${DB_COUNT:-0}" -eq 0 ]]; then
  log_error "Database list is EMPTY. Nothing was backed up."
  log_error "Check MySQL connectivity and BACKUP_MODE."
  exit 1
fi

log_info "Databases ($DB_COUNT): $(echo "$DATABASES" | tr '\n' ' ')"

# --- Space check ---
# Measures ALL user databases even in SELECTED mode — over-estimating is the
# safe direction.
DATA_SIZE_MB=$(mysql_val "
  SELECT ROUND(SUM(data_length + index_length)/1048576)
  FROM information_schema.TABLES
  WHERE table_schema NOT IN
    ('information_schema','performance_schema','mysql','sys');" || echo 0)

FREE_MB=$(df -BM --output=avail "$BACKUP_DIR" | tail -1 | tr -dc '0-9')
REQUIRED_MB=$(( ${DATA_SIZE_MB:-0} * SPACE_REQUIRED_PCT / 100 ))

if [[ ${FREE_MB:-0} -lt $REQUIRED_MB ]]; then
  log_error "Insufficient space in $BACKUP_DIR"
  log_error "Required ~${REQUIRED_MB}MB (${SPACE_REQUIRED_PCT}% of ${DATA_SIZE_MB}MB), available ${FREE_MB}MB"
  exit 1
fi
log_info "Space OK: ${FREE_MB}MB free, ~${REQUIRED_MB}MB needed"

# --- Save warm page list before dumps ---
log_step "SAVE BUFFER POOL STATE"
#bp_save_pages

# --- Run backups in parallel ---
log_step "DUMP DATABASES"
FAIL_FLAG="$(mktemp /tmp/.dbbackup_fail.XXXXXX)"
export -f dump_one _log log_info log_warn log_error
export BACKUP_DIR LOG_FILE TS DUMP_OPTS SOURCE_DATA_OPT
export MYSQL_USER MYSQL_PASSWORD MYSQL_HOST FAIL_FLAG

echo "$DATABASES" | xargs -r -n1 -P "$PARALLEL" bash -c 'dump_one "$@"' _ || true

OK_COUNT=$DB_COUNT
FAILED_COUNT=0
FAILED_LIST=""

if [ -s "$FAIL_FLAG" ]; then
  FAILED_COUNT=$(grep -c '[^[:space:]]' "$FAIL_FLAG" || true)
  FAILED_LIST=$(tr '\n' ' ' < "$FAIL_FLAG")
  OK_COUNT=$(( DB_COUNT - FAILED_COUNT ))
  log_error "Failed databases ($FAILED_COUNT/$DB_COUNT): $FAILED_LIST"
else
  log_info "All $DB_COUNT databases dumped successfully."
fi
rm -f "$FAIL_FLAG"

write_manifest

# =============================================================================
# REGION 8: BUFFER POOL CLEANUP (shrink to release polluted pages, then expand)
# =============================================================================

log_step "BUFFER POOL CLEANUP"

#bp_stats
#bp_shrink
#sleep 7
#bp_expand
#bp_load_pages
#bp_stats

# =============================================================================
# REGION 9: EXIT STATUS
# =============================================================================

if [[ ${FAILED_COUNT:-0} -gt 0 ]]; then
  log_step "BACKUP RUN FINISHED WITH ERRORS ($FAILED_COUNT/$DB_COUNT failed)"
  exit 1
fi

log_step "BACKUP RUN FINISHED"
exit 0
