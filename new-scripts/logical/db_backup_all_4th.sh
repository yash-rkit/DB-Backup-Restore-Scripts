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
# Parameterization (per DB BRD Script Authoring Guide):
#   - Positional args ($1, $2)   -> runtime data
#   - {{CMC27:key-name}} tokens  -> secrets/config, resolved by the API before
#                                   SSH delivery. Never visible in `ps aux`.
#
# Usage (delivered by the API via heredoc over SSH, no files written remotely):
#   the API passes positional args $1-$8; this script uses $1, $5, $7 and $8.
#
# $1  RESULT_ID  - BJR01.CentralResultId this run belongs to; stored in
#                  BLS01.S01F02 on every status row this script inserts.
# $5  BASE_DIR   - STORAGE_ROOT; storage mount root (see note below).
# $7  STATUS_DB  - database holding BLS01 (and BJR01).
# $8  CONFIG_ID  - BJC03.ConfigId; the job definition this run belongs to.
#                  Still accepted (and required) to keep the API's arg contract
#                  unchanged, but no longer part of the output filename — output
#                  is named {db}_{timestamp} so a file identifies its database
#                  by eye. Restore never parses the filename: it reads the
#                  target database from the dump's own USE statement.
#                  (Was $9 before the 2026-07-21 TIMEOUT_MIN-arg removal.)
#
# BASE_DIR is the root storage mount only. The actual backup folder
# (BACKUP_FOLDER below, e.g. DBBackup/Cloud-Live-DB-Sandbox) is appended
# at script level, so the same base dir can be reused across scripts
# while each script still writes to its own subfolder.
#
set -euo pipefail
 
# =============================================================================
# REGION 1: CONFIGURATION
# =============================================================================
 
# --- Positional args — passed by the API at run time ---
RESULT_ID="$1"
STATUS_DB="$7"
CONFIG_ID="$8"

# --- DB credentials — injected from CMC27 before SSH delivery -------------
# The API replaces these tokens with plaintext values before the script is
# sent to the server. They are never visible in `ps aux` because they live
# in the script body, not as CLI args.
MYSQL_HOST="{{CMC27:db-host}}"
MYSQL_PORT="{{CMC27:db-port}}"
MYSQL_USER="{{CMC27:db-user}}"
MYSQL_PASSWORD="{{CMC27:db-password}}"
 
# --- Storage root — positional arg $5 (STORAGE_ROOT, per the guide) -------
BASE_DIR="$5"
 
# --- Script-internal settings (edit here, not passed via CLI) ---
BACKUP_FOLDER="YK/Cloud-Live-DB-4th-Server"   # appended to BASE_DIR to form the actual backup path
BACKUP_MODE="ALL"       # ALL or SELECTED
PARALLEL=3
DUMP_OPTS="--single-transaction --quick --routines --events --triggers --set-gtid-purged=OFF --net-buffer-length=1M"
 
# --- Buffer pool sizes (bytes) ---
BP_SHRINK_SIZE=19327352832    # 18 GB
BP_NORMAL_SIZE=38654705664   # 36 GB
 
# --- Resize limits ---
BP_RESIZE_TIMEOUT=120        # max seconds to wait for one resize
 
# --- Validate required positional arguments ---
missing=()
[ -n "${RESULT_ID:-}" ] || missing+=("RESULT_ID (\$1)")
[ -n "${BASE_DIR:-}" ]  || missing+=("BASE_DIR (\$5)")
[ -n "${STATUS_DB:-}" ] || missing+=("STATUS_DB (\$7)")
[ -n "${CONFIG_ID:-}" ] || missing+=("CONFIG_ID (\$8)")
if [ "${#missing[@]}" -gt 0 ]; then
  echo "ERROR: missing required argument(s): ${missing[*]}" >&2
  echo "Usage: $0 expects positional args \$1=RESULT_ID \$5=BASE_DIR \$7=STATUS_DB \$8=CONFIG_ID" >&2
  exit 1
fi
 
# --- Base path (all archives and logs live under this) ---
BACKUP_DIR="$BASE_DIR/$BACKUP_FOLDER"
LOG_DIR="$BACKUP_DIR/logs"
LOCKFILE="/var/run/dbbackup.lock"
DB_LIST_DIR="$BACKUP_DIR/CompanyList"   # folder containing DB list files (latest file picked automatically)
 
# --- Derived (do not edit) ---
TS="$(date +'%Y-%m-%d_%H-%M-%S')"
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
 
mysql_val() { mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" -N -B -e "$1" 2>/dev/null; }
mysql_run() { mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" -e "$1" 2>/dev/null; }
 
# Create the per-database status table if it doesn't already exist yet.
# Piped in via heredoc (not -e) so the DDL doesn't need any quote escaping.
ensure_status_table() {
  mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" 2>/dev/null <<SQL
CREATE TABLE IF NOT EXISTS ${STATUS_DB}.BLS01 (
    S01F01 INT NOT NULL AUTO_INCREMENT
        COMMENT 'StatusId PK',
    S01F02 BIGINT NULL
        COMMENT 'CentralResultId FK→BJR01',
    S01F05 VARCHAR(255) NOT NULL
        COMMENT 'DatabaseName',
    S01F07 ENUM('RUNNING','SUCCESS','FAILED') NOT NULL
        COMMENT 'Status',
    S01F08 INT NULL
        COMMENT 'Pid',
    S01C06 DATETIME NOT NULL
        COMMENT 'StartedAt',
    S01C07 DATETIME NULL
        COMMENT 'CompletedAt',
    S01F09 VARCHAR(500) NULL
        COMMENT 'CurrentFilePath',
    S01F10 BIGINT NULL
        COMMENT 'CurrentFileSize',
    S01F11 BIGINT NULL
        COMMENT 'FinalFileSize',
    S01F12 VARCHAR(64) NULL
        COMMENT 'Sha256Checksum',
    S01F13 INT NULL
        COMMENT 'ExitCode',
    S01F14 TEXT NULL
        COMMENT 'ErrorMessage',
    S01C04 DATETIME NOT NULL
        DEFAULT CURRENT_TIMESTAMP
        ON UPDATE CURRENT_TIMESTAMP
        COMMENT 'UpdatedAt',
    PRIMARY KEY (S01F01),
    INDEX idx_bls01_result (S01F02),
    INDEX idx_bls01_status (S01F07)
) ENGINE=InnoDB
DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;
SQL
}
 
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
# REGION 5: FILE-STABILITY HELPER
# =============================================================================
#
# On blobfuse2-mounted storage, a file can still be getting touched by the
# mount's background upload/commit process even after `sync` returns. tar can
# start reading before that settles and abort with "file changed as we read
# it". This helper polls the file's mtime+size until they stop changing
# across two consecutive checks, then returns. It always returns 0 (best
# effort) so a slow/stuck mount never blocks the backup indefinitely.
#
wait_for_stable_file() {
  local f="$1"
  local max_wait=30
  local interval=2
  local waited=0
  local prev="" cur=""

  while [ "$waited" -lt "$max_wait" ]; do
    cur=$(stat --format='%Y:%s' "$f" 2>/dev/null) || return 0
    if [ "$cur" = "$prev" ] && [ -n "$prev" ]; then
      return 0
    fi
    prev="$cur"
    sleep "$interval"
    waited=$((waited + interval))
  done
  return 0
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
  local TAR_ERR="$DB_DIR/.tar_err_$$"

  mkdir -p "$DB_DIR"
  log_info "[$DB] start -> ${DB}/${DB}_${TS}.tar.gz"
 
  # Record status row for this database
  mysql_run "INSERT INTO ${STATUS_DB}.BLS01 (S01F02, S01F05, S01F07, S01F08, S01C06) VALUES ($RESULT_ID, '$DB', 'RUNNING', $$, NOW());"
 
  # Dump database; capture stderr so we can log the real error (not the password warning).
  # set +e/-e around this so we can capture the real mysqldump exit code (not the
  # negated 0/1 that "if ! cmd" would give us) while still surviving under set -e.
  set +e
  mysqldump -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" \
       $DUMP_OPTS --databases "$DB" > "$SQL_FILE" 2>"$DUMP_ERR"
  local dump_exit=$?
  set -e
 
  if [ "$dump_exit" -ne 0 ]; then
    local reason reason_sql
    reason=$(grep -v '\[Warning\].*password' "$DUMP_ERR" | head -1)
    reason="${reason:-unknown error}"
    log_error "[$DB] mysqldump FAILED: $reason"
    reason_sql="${reason//\'/\'\'}"
    mysql_run "UPDATE ${STATUS_DB}.BLS01 SET S01F07='FAILED', S01C07=NOW(), S01F13=$dump_exit, S01F14='$reason_sql' WHERE S01F02=$RESULT_ID AND S01F05='$DB' AND S01F07='RUNNING';"
    rm -f "$DUMP_ERR" "$SQL_FILE"
    echo "$DB" >> "$FAIL_FLAG"
    return 0
  fi
  rm -f "$DUMP_ERR"
 
  # Guard against empty dumps
  if [ ! -s "$SQL_FILE" ]; then
    log_error "[$DB] dump is empty, skipping archive"
    mysql_run "UPDATE ${STATUS_DB}.BLS01 SET S01F07='FAILED', S01C07=NOW(), S01F13=$dump_exit, S01F14='dump produced an empty file' WHERE S01F02=$RESULT_ID AND S01F05='$DB' AND S01F07='RUNNING';"
    echo "$DB" >> "$FAIL_FLAG"
    return 0
  fi
 
  # Flush writes toward storage. Becomes fully effective once the blobfuse2
  # mount config has sync-to-flush: true set (pending config change) --
  # until then this still just evicts local cache, which is why the
  # stability wait + retry + verify steps below exist as a safety net.
  sync "$SQL_FILE"

  # Wait until the file's mtime+size stop changing before we trust it enough
  # to read. Guards against blobfuse2's background upload still touching the
  # file after sync returns.
  wait_for_stable_file "$SQL_FILE"

  # --- Archive with retry -----------------------------------------------
  # "file changed as we read it" is a timing race against blobfuse2's
  # background commit. A short pause + retry frequently clears it on the
  # next attempt without needing a full re-dump.
  local tar_attempt=0
  local tar_ok=false
  local tar_err_msg=""
  while [ "$tar_attempt" -lt 3 ]; do
    if tar -czf "$ARCHIVE_FILE" -C "$DB_DIR" "${DB}_${TS}.sql" 2>"$TAR_ERR"; then
      tar_ok=true
      break
    fi
    tar_attempt=$((tar_attempt + 1))
    tar_err_msg=$(head -1 "$TAR_ERR" 2>/dev/null)
    log_warn "[$DB] tar attempt $tar_attempt failed: ${tar_err_msg:-unknown error}, retrying in 5s..."
    rm -f "$ARCHIVE_FILE"
    sleep 5
    wait_for_stable_file "$SQL_FILE"
  done

  if [ "$tar_ok" != true ]; then
    local tar_reason_sql
    tar_reason_sql="${tar_err_msg:-tar failed after 3 attempts}"
    tar_reason_sql="${tar_reason_sql//\'/\'\'}"
    log_error "[$DB] tar FAILED after 3 attempts: ${tar_err_msg:-unknown error}"
    mysql_run "UPDATE ${STATUS_DB}.BLS01 SET S01F07='FAILED', S01C07=NOW(), S01F13=1, S01F14='$tar_reason_sql' WHERE S01F02=$RESULT_ID AND S01F05='$DB' AND S01F07='RUNNING';"
    rm -f "$ARCHIVE_FILE" "$TAR_ERR"
    echo "$DB" >> "$FAIL_FLAG"
    return 0
    # Note: $SQL_FILE is intentionally NOT deleted here. Nothing is lost;
    # investigate the raw .sql manually or let the next run overwrite it.
  fi
  rm -f "$TAR_ERR"

  # --- Verify BEFORE deleting the source SQL -----------------------------
  # This is the safety net that closes the silent-corruption gap: an archive
  # that "completed" but is actually truncated will fail one of these checks,
  # and we still have the original .sql sitting untouched if so.
  if ! gzip -t "$ARCHIVE_FILE" 2>>"$LOG_FILE"; then
    log_error "[$DB] archive FAILED integrity check (gzip -t) after creation"
    mysql_run "UPDATE ${STATUS_DB}.BLS01 SET S01F07='FAILED', S01C07=NOW(), S01F13=1, S01F14='archive failed gzip -t integrity check' WHERE S01F02=$RESULT_ID AND S01F05='$DB' AND S01F07='RUNNING';"
    rm -f "$ARCHIVE_FILE"
    echo "$DB" >> "$FAIL_FLAG"
    return 0
  fi

  if ! tar -tzf "$ARCHIVE_FILE" >/dev/null 2>>"$LOG_FILE"; then
    log_error "[$DB] archive FAILED structural check (tar -tzf) after creation"
    mysql_run "UPDATE ${STATUS_DB}.BLS01 SET S01F07='FAILED', S01C07=NOW(), S01F13=1, S01F14='archive failed tar -tzf structural check' WHERE S01F02=$RESULT_ID AND S01F05='$DB' AND S01F07='RUNNING';"
    rm -f "$ARCHIVE_FILE"
    echo "$DB" >> "$FAIL_FLAG"
    return 0
  fi

  # Capture the raw dump size before deleting it -- S01F10 (CurrentFileSize)
  # records the uncompressed .sql size, S01F11 (FinalFileSize) the archive size.
  local raw_bytes
  raw_bytes=$(stat --format=%s "$SQL_FILE")

  # Archive verified good -- now safe to remove the raw SQL file
   rm -f "$SQL_FILE"

  sha256sum "$ARCHIVE_FILE" > "$ARCHIVE_FILE.sha256"
  local checksum
  checksum=$(cut -d' ' -f1 "$ARCHIVE_FILE.sha256")

  local size size_bytes
  size=$(du -h "$ARCHIVE_FILE" | cut -f1)
  size_bytes=$(stat --format=%s "$ARCHIVE_FILE")

  mysql_run "UPDATE ${STATUS_DB}.BLS01 SET S01F07='SUCCESS', S01C07=NOW(), S01F09='$ARCHIVE_FILE', S01F10=$raw_bytes, S01F11=$size_bytes, S01F12='$checksum', S01F13=0 WHERE S01F02=$RESULT_ID AND S01F05='$DB' AND S01F07='RUNNING';"
 
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
  ensure_status_table
  mysql_run "INSERT INTO ${STATUS_DB}.BLS01 (S01F02, S01F05, S01F07, S01C06, S01C07, S01F13, S01F14) VALUES ($RESULT_ID, 'LOCK_CONTENTION', 'FAILED', NOW(), NOW(), 1, 'Skipped: another backup was already running on this server (lock held).');"
  exit 0
fi
 
log_step "BACKUP RUN START (parallel=$PARALLEL, mode=$BACKUP_MODE)"
log_info "Base path: $BACKUP_DIR"
 
# --- Sanity checks ---
command -v mysqldump >/dev/null || { log_error "mysqldump not found"; exit 1; }
command -v tar       >/dev/null || { log_error "tar not found"; exit 1; }
 
# --- Ensure status table exists ---
log_step "ENSURE STATUS TABLE"
ensure_status_table
log_info "BLS01 status table verified/created."
 
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

# Pre-Backup Buffer Pool Cleanup — DISABLED (calls commented out; the bp_*
# function definitions in REGION 4 are left intact so this can be re-enabled
# by uncommenting the lines below).
# log_step "BUFFER POOL CLEANUP (pre-backup)"
# bp_stats
#
# bp_shrink
#
# sleep 7
#
# bp_expand
#
# bp_load_pages
#
# bp_stats

# --- Save warm page list before dumps --- DISABLED
# log_step "SAVE BUFFER POOL STATE"
# bp_save_pages

# --- Run backups in parallel ---
log_step "DUMP DATABASES"
FAIL_FLAG="$(mktemp /tmp/.dbbackup_fail.XXXXXX)"
export -f dump_one wait_for_stable_file _log log_info log_warn log_error mysql_run
export BACKUP_DIR LOG_FILE TS DUMP_OPTS MYSQL_USER MYSQL_PASSWORD MYSQL_HOST MYSQL_PORT RESULT_ID STATUS_DB CONFIG_ID FAIL_FLAG
 
echo "$DATABASES" | xargs -r -n1 -P "$PARALLEL" bash -c 'dump_one "$@"' _ || true
 
if [ -s "$FAIL_FLAG" ]; then
  log_error "Failed databases: $(tr '\n' ' ' < "$FAIL_FLAG")"
else
  log_info "All databases dumped successfully."
fi
rm -f "$FAIL_FLAG"
 
# =============================================================================
# REGION 8: BUFFER POOL CLEANUP (shrink to release polluted pages, then expand)
# =============================================================================
#
# DISABLED — calls commented out; the bp_* function definitions in REGION 4 are
# left intact so this can be re-enabled by uncommenting the lines below.

# log_step "BUFFER POOL CLEANUP"
#
# bp_stats
#
# bp_shrink
# sleep 7
# bp_expand
#
# bp_load_pages
#
# bp_stats

log_step "BACKUP RUN FINISHED"