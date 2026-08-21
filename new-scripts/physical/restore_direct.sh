#!/usr/bin/env bash
#
# restore_direct.sh
#
# DIRECT physical restore: stops MySQL, wipes the datadir, extracts a prepared
# XtraBackup archive back into it, restarts MySQL, then applies the binlogs
# collected since that backup (point-in-time recovery).
#
# DESTRUCTIVE: it clears MYSQL_DATADIR. Selection + all verification happen
# BEFORE anything is stopped or deleted.
#
# Parameterization (per DB BRD Script Authoring Guide):
#   - Positional args ($1, $3, $4, $5, $6, $7)  -> runtime data
#   - {{CMC27:key-name}} tokens                 -> secrets
#
# > CHANGED 2026-07-21: the TIMEOUT_MIN argument (was $4) was removed (per-job
# > restore timeout dropped). Every arg after it shifted down by one:
# > STATUS_DB $5->$4, BASE_DIR $6->$5, BACKUP_CONFIG_ID $7->$6, BACKUP_DATE $8->$7.
#
# Positional args (full 7-slot restore contract, per RestoreArgsBuilder):
#   $1 RESULT_ID    - this restore run's CentralResultId (stored in RLS03).
#   $2 (ignored)    - BACKUP_FILE_PATHS; logical-restore only, unused here.
#   $3 SERVER_NAME  - VALIDATION_SERVER; target server name (logs + RLS03.S03F04).
#   $4 STATUS_DB    - database name (on the SEPARATE status host) holding RLS03/RLS04.
#   $5 BASE_DIR     - STORAGE_ROOT; shared storage mount root.
#   $6 CONFIG_ID    - RJC04.BackupConfigId; backup job definition to restore
#                     (selects job<CONFIG_ID>_*). Same ConfigId physical_backup.sh
#                     used to name archives.
#   $7 BACKUP_DATE  - OPTIONAL, reserved. Format undecided; treated as always empty.
#                     Empty -> latest backup for the job (newest by mtime).
#
# Two connections:
#   TARGET  MySQL ({{CMC27:db-*}})        - the instance being restored (local);
#                                           used for binlog apply + validation.
#   STATUS  MySQL ({{CMC27:status-db-*}}) - a SEPARATE dashboard DB that stays up
#                                           while the target is wiped, so RLS03/
#                                           RLS04 live status keeps updating.
# Same target creds are used before AND after restore (source server shares them).
#
set -euo pipefail

############################
# CONFIGURATION
############################

# --- Positional args (required ones use ${N:-} so a short invocation gives the
#     friendly "missing argument" error below rather than a set -u abort) ---
RESULT_ID="${1:-}"
# $2 BACKUP_FILE_PATHS — logical-restore only; ignored here.
SERVER_NAME="${3:-}"
# TIMEOUT_MIN (was $4) removed 2026-07-21; remaining args shifted down by one.
STATUS_DB="${4:-}"
BASE_DIR="${5:-}"
CONFIG_ID="${6:-}"
BACKUP_DATE="${7:-}"

# --- TARGET MySQL creds (used before AND after restore) — from CMC27 ---
MYSQL_HOST="{{CMC27:db-host}}"
MYSQL_PORT="{{CMC27:db-port}}"
MYSQL_USER="{{CMC27:db-user}}"
MYSQL_PASSWORD="{{CMC27:db-password}}"

# --- STATUS/dashboard DB creds (SEPARATE host) — from CMC27 ---
STATUS_HOST="{{CMC27:status-db-host}}"
STATUS_PORT="{{CMC27:status-db-port}}"
STATUS_USER="{{CMC27:status-db-user}}"
STATUS_PASSWORD="{{CMC27:status-db-password}}"

# --- Archive folder — appended to BASE_DIR ($5). MUST match the backup. ---
ARCHIVE_FOLDER="Archive/Cloud-Live-DB-Tirupati"

# --- Server-local settings (edit here) ---
MYSQL_DATADIR="/Data/mysql"
MYSQLBINLOG_BIN="/usr/bin/mysqlbinlog"
MYSQL_BIN="/usr/bin/mysql"
HEARTBEAT_INTERVAL=30

# --- Validate required positional arguments ---
missing=()
[[ -n "${RESULT_ID:-}" ]] || missing+=("RESULT_ID (\$1)")
[[ -n "${STATUS_DB:-}" ]] || missing+=("STATUS_DB (\$4)")
[[ -n "${BASE_DIR:-}" ]]  || missing+=("BASE_DIR (\$5)")
if [[ "${#missing[@]}" -gt 0 ]]; then
  echo "ERROR: missing required argument(s): ${missing[*]}" >&2
  echo "Usage: $0 \$1=RESULT_ID \$4=STATUS_DB \$5=BASE_DIR (\$3 server, \$6 config, \$7 date)" >&2
  exit 1
fi

if [[ -n "$BACKUP_DATE" && ! "$BACKUP_DATE" =~ ^[0-9]{8}$ ]]; then
  echo "ERROR: BACKUP_DATE must be YYYYMMDD (got: $BACKUP_DATE)" >&2
  exit 1
fi

# --- Derived paths ---
ARCHIVE_DIR="${BASE_DIR}/${ARCHIVE_FOLDER}"
BINLOG_ARCHIVE_BASE="${ARCHIVE_DIR}/binlog"
LOG_DIR="${ARCHIVE_DIR}/restore"

############################
# EARLY INITIALIZATION
############################

RUN_LOG=""
ERROR_LOG=""
COMPRESSED_BACKUP=""
NAME=""
CHECKSUM_FILE=""
BINLOG_INFO_FILE=""
BINLOG_DIR=""
BACKUP_SIZE="N/A"
BACKUP_SHA256="N/A"
START_BINLOG=""
START_POS=""
BINLOGS_AVAILABLE=false
APPLIED_COUNT=0
BINLOG_ERRORS=0
DB_COUNT=0
MYSQL_WAS_RUNNING=false
LAST_ERROR=""
STATUS_ROW_CREATED=0
HEARTBEAT_PID=""
CURRENT_STAGE=0
CURRENT_STAGE_TEXT="Pre-flight checks"

TOTAL_STAGES=5     # 1 stop, 2 restore, 3 verify, 4 start, 5 apply (0 = pre-flight)
START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
START_EPOCH="$(date +%s)"

RUN_LOG="${LOG_DIR}/restore_${RESULT_ID}.log"
ERROR_LOG="${LOG_DIR}/restore_${RESULT_ID}_errors.log"

############################
# LOGGING
############################

log_msg() {
  if [[ -n "$RUN_LOG" && -d "$(dirname "$RUN_LOG")" ]]; then
    echo "[$(date '+%F %T')] [INFO] $1" | tee -a "$RUN_LOG"
  else
    echo "[$(date '+%F %T')] [INFO] $1"
  fi
}
log_error() {
  LAST_ERROR="$1"
  if [[ -n "$RUN_LOG" && -d "$(dirname "$RUN_LOG")" ]]; then
    echo "[$(date '+%F %T')] [ERROR] $1" | tee -a "$RUN_LOG" >&2
  else
    echo "[$(date '+%F %T')] [ERROR] $1" >&2
  fi
}
log_warn() {
  if [[ -n "$RUN_LOG" && -d "$(dirname "$RUN_LOG")" ]]; then
    echo "[$(date '+%F %T')] [WARN] $1" | tee -a "$RUN_LOG"
  else
    echo "[$(date '+%F %T')] [WARN] $1"
  fi
}

############################
# STATUS HELPERS (RLS03 summary + RLS04 stage timeline, on the STATUS host)
############################

# Fire-and-forget write to the SEPARATE status DB — always guarded.
record() {
  "$MYSQL_BIN" -u"$STATUS_USER" -p"$STATUS_PASSWORD" -h"$STATUS_HOST" -P"$STATUS_PORT" \
    -e "$1" 2>/dev/null || true
}

# Escape single quotes for SQL by doubling them (''). Quote variable used so no
# backslashes end up in the value.
sql_escape() { local q="'"; printf '%s' "${1//$q/$q$q}"; }

# Create the restore status tables. Output captured so a real error surfaces.
# No positional args ($1..$9) may appear in the heredoc body (unquoted for
# ${STATUS_DB}; set -u would abort on an unbound arg).
ensure_status_tables() {
  local out rc
  out="$("$MYSQL_BIN" -u"$STATUS_USER" -p"$STATUS_PASSWORD" -h"$STATUS_HOST" -P"$STATUS_PORT" 2>&1 <<SQL
CREATE TABLE IF NOT EXISTS ${STATUS_DB}.RLS03 (
    S03F01 INT NOT NULL AUTO_INCREMENT COMMENT 'StatusId PK',
    S03F02 BIGINT NOT NULL COMMENT 'CentralResultId FK->RJR03',
    S03F03 INT NULL COMMENT 'ConfigId (RJC04.BackupConfigId)',
    S03F04 VARCHAR(255) NOT NULL COMMENT 'ServerName',
    S03F05 ENUM('RUNNING','SUCCESS','FAILED') NOT NULL COMMENT 'Status',
    S03F06 VARCHAR(120) NULL COMMENT 'CurrentStage (live text)',
    S03F07 TINYINT NULL COMMENT 'StageNumber (1..5)',
    S03F08 TINYINT NULL COMMENT 'TotalStages (=5)',
    S03F09 INT NULL COMMENT 'Pid',
    S03C06 DATETIME NOT NULL COMMENT 'StartedAt',
    S03C07 DATETIME NULL COMMENT 'CompletedAt',
    S03F10 VARCHAR(255) NULL COMMENT 'BackupRestored (archive basename)',
    S03F11 VARCHAR(64) NULL COMMENT 'BackupSha256',
    S03F12 VARCHAR(255) NULL COMMENT 'StartBinlog',
    S03F13 VARCHAR(32) NULL COMMENT 'StartPos',
    S03F14 INT NULL COMMENT 'DatabasesRestored',
    S03F15 INT NULL COMMENT 'BinlogsApplied',
    S03F16 INT NULL COMMENT 'BinlogErrors',
    S03F17 INT NULL COMMENT 'ExitCode',
    S03F18 TEXT NULL COMMENT 'ErrorMessage',
    S03F19 VARCHAR(255) NULL COMMENT 'CurrentBinlog (live during apply)',
    S03C04 DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
        COMMENT 'UpdatedAt (heartbeat)',
    PRIMARY KEY (S03F01),
    INDEX idx_rls03_result (S03F02),
    INDEX idx_rls03_config (S03F03),
    INDEX idx_rls03_status (S03F05)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS ${STATUS_DB}.RLS04 (
    S04F01 INT NOT NULL AUTO_INCREMENT COMMENT 'StageId PK',
    S04F02 BIGINT NOT NULL COMMENT 'CentralResultId FK->RJR03',
    S04F03 TINYINT NOT NULL COMMENT 'StageNumber (0=pre-flight, 1..5)',
    S04F04 VARCHAR(120) NOT NULL COMMENT 'StageText',
    S04F05 ENUM('RUNNING','SUCCESS','FAILED') NOT NULL COMMENT 'StageStatus',
    S04F06 TEXT NULL COMMENT 'Message',
    S04C06 DATETIME NOT NULL COMMENT 'StartedAt',
    S04C07 DATETIME NULL COMMENT 'CompletedAt',
    PRIMARY KEY (S04F01),
    INDEX idx_rls04_result (S04F02),
    INDEX idx_rls04_result_stage (S04F02, S04F01)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
SQL
)"
  rc=$?
  [[ $rc -eq 0 ]] || log_warn "Status table setup failed (rc=$rc): ${out//$'\n'/ | }"
  return $rc
}

# Close the open RLS04 stage row (if any) with a terminal status + end time.
close_stage() {
  [[ "$STATUS_ROW_CREATED" == "1" ]] || return 0
  local status="$1" msg="${2:-}" set_msg=""
  if [[ -n "$msg" ]]; then set_msg=", S04F06='$(sql_escape "$msg")'"; fi
  record "UPDATE ${STATUS_DB}.RLS04
            SET S04F05='${status}', S04C07=NOW()${set_msg}
          WHERE S04F02=${RESULT_ID} AND S04F05='RUNNING';"
}

# Advance to a new stage: update RLS03 (progress + heartbeat), close previous
# RLS04 stage as SUCCESS, open this one as RUNNING.
set_stage() {
  local n="$1" text="$2"
  CURRENT_STAGE="$n"; CURRENT_STAGE_TEXT="$text"
  [[ "$STATUS_ROW_CREATED" == "1" ]] || return 0
  record "UPDATE ${STATUS_DB}.RLS03
            SET S03F06='$(sql_escape "$text")', S03F07=${n}, S03F08=${TOTAL_STAGES}
          WHERE S03F02=${RESULT_ID} AND S03F05='RUNNING';"
  close_stage "SUCCESS"
  record "INSERT INTO ${STATUS_DB}.RLS04
            (S04F02, S04F03, S04F04, S04F05, S04C06)
          VALUES (${RESULT_ID}, ${n}, '$(sql_escape "$text")', 'RUNNING', NOW());"
}

# Live update during binlog apply (applied count + current binlog).
rls03_apply_progress() {
  [[ "$STATUS_ROW_CREATED" == "1" ]] || return 0
  record "UPDATE ${STATUS_DB}.RLS03
            SET S03F15=${APPLIED_COUNT}, S03F16=${BINLOG_ERRORS}, S03F19='$(sql_escape "${1:-}")'
          WHERE S03F02=${RESULT_ID} AND S03F05='RUNNING';"
}

############################
# HEARTBEAT (writes to the STATUS host — survives the target being down)
############################

heartbeat_start() {
  [[ "$STATUS_ROW_CREATED" == "1" ]] || return 0
  heartbeat_stop
  (
    while true; do
      sleep "$HEARTBEAT_INTERVAL"
      "$MYSQL_BIN" -u"$STATUS_USER" -p"$STATUS_PASSWORD" -h"$STATUS_HOST" -P"$STATUS_PORT" \
        -e "UPDATE ${STATUS_DB}.RLS03 SET S03C04=NOW() WHERE S03F02=${RESULT_ID} AND S03F05='RUNNING';" \
        2>/dev/null || true
    done
  ) &
  HEARTBEAT_PID=$!
}
heartbeat_stop() {
  if [[ -n "${HEARTBEAT_PID:-}" ]]; then
    kill "$HEARTBEAT_PID" 2>/dev/null || true
    wait "$HEARTBEAT_PID" 2>/dev/null || true
    HEARTBEAT_PID=""
  fi
}

############################
# TARGET MySQL helpers
############################

mysql_cmd() { "$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" "$@"; }
test_mysql_connection() { mysql_cmd -e "SELECT 1" >/dev/null 2>&1; }
is_mysql_running() {
  systemctl is-active --quiet mysql 2>/dev/null && return 0
  systemctl is-active --quiet mysqld 2>/dev/null && return 0
  pgrep -x mysqld >/dev/null 2>&1 && return 0
  return 1
}
get_free_space_gb() { df -BG "$1" | awk 'NR==2 {print $4}' | sed 's/G//'; }
validate_writable() {
  local d="$1" t="$1/.write_test_$$"
  touch "$t" 2>/dev/null || return 1
  rm -f "$t"; return 0
}

############################
# FAILURE HANDLING
############################

# Central failure path: try to bring MySQL back up, mark RLS03/RLS04 FAILED, exit.
fail_restore() {
  local ec="${1:-1}"
  local reason="${2:-${LAST_ERROR:-Restore failed; see logs}}"
  trap - ERR INT TERM
  heartbeat_stop
  log_error "Restore failed (exit code: $ec)."

  # Best effort: if we stopped MySQL and it's down, try to start it back up.
  if [[ "$MYSQL_WAS_RUNNING" == true ]] && ! is_mysql_running; then
    log_warn "Attempting to restart MySQL after failure..."
    systemctl start mysql 2>/dev/null || true
  fi

  if [[ "$STATUS_ROW_CREATED" == "1" && -n "${RESULT_ID:-}" ]]; then
    close_stage "FAILED" "$reason"
    record "UPDATE ${STATUS_DB}.RLS03
              SET S03F05='FAILED', S03C07=NOW(), S03F17=${ec}, S03F18='$(sql_escape "$reason")',
                  S03F15=${APPLIED_COUNT}, S03F16=${BINLOG_ERRORS}
            WHERE S03F02=${RESULT_ID} AND S03F05='RUNNING';"
  fi

  log_error "Restore aborted. Check logs: ${RUN_LOG:-'(not initialized)'}"
  exit 1
}
on_trap() { local ec=$?; fail_restore "$ec"; }
trap on_trap ERR INT TERM
trap heartbeat_stop EXIT

############################
# SETUP + STATUS ROW (before pre-flight, so failures are recorded)
############################

mkdir -p "$LOG_DIR" 2>/dev/null || { echo "[ERROR] cannot create $LOG_DIR" >&2; exit 1; }
: > "$RUN_LOG" 2>/dev/null || true
: > "$ERROR_LOG" 2>/dev/null || true

CONFIG_ID_SQL="NULL"
if [[ "$CONFIG_ID" =~ ^[0-9]+$ ]]; then CONFIG_ID_SQL="$CONFIG_ID"; fi

log_msg "Ensuring status tables (RLS03/RLS04) on status host..."
if ensure_status_tables; then
  record "INSERT INTO ${STATUS_DB}.RLS03
            (S03F02, S03F03, S03F04, S03F05, S03F06, S03F07, S03F08, S03F09, S03C06)
          VALUES
            (${RESULT_ID}, ${CONFIG_ID_SQL}, '$(sql_escape "$SERVER_NAME")',
             'RUNNING', 'Pre-flight checks', 0, ${TOTAL_STAGES}, $$, NOW());"
  STATUS_ROW_CREATED=1
  set_stage 0 "Pre-flight checks"
  heartbeat_start
  log_msg "RLS03 RUNNING row created for RESULT_ID=${RESULT_ID}."
else
  log_warn "Could not create RLS03/RLS04; continuing without DB status."
fi

############################
# PRE-FLIGHT CHECKS
############################

log_msg "===================================================="
log_msg "Restore pre-flight checks..."
log_msg "===================================================="

[[ $EUID -eq 0 ]] || { log_error "This script must be run as root"; fail_restore 1; }

for cmd in tar gzip awk du df stat wc pgrep chown rm basename find sort sha256sum systemctl; do
  command -v "$cmd" >/dev/null 2>&1 || { log_error "Required command not found: $cmd"; fail_restore 1; }
done
[[ -x "$MYSQL_BIN" ]]        || { log_error "mysql not executable: $MYSQL_BIN"; fail_restore 1; }
[[ -x "$MYSQLBINLOG_BIN" ]]  || { log_error "mysqlbinlog not executable: $MYSQLBINLOG_BIN"; fail_restore 1; }

# --- Select the backup to restore ---
if [[ "$CONFIG_ID" =~ ^[0-9]+$ ]]; then cfg_glob="job${CONFIG_ID}_"; else cfg_glob="job*_"; fi
if [[ -n "$BACKUP_DATE" ]]; then sel_glob="${cfg_glob}${BACKUP_DATE}_*.tar.gz"; else sel_glob="${cfg_glob}*.tar.gz"; fi
log_msg "Selecting backup: ${ARCHIVE_DIR}/${sel_glob} (latest by mtime)"

if [[ -d "$ARCHIVE_DIR" ]]; then
  COMPRESSED_BACKUP=$(find "$ARCHIVE_DIR" -maxdepth 1 -type f -name "$sel_glob" \
                        -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
fi
if [[ -z "$COMPRESSED_BACKUP" ]]; then
  log_error "No backup found matching ${sel_glob} in ${ARCHIVE_DIR}"
  fail_restore 1 "No backup found matching ${sel_glob}"
fi

NAME="$(basename "$COMPRESSED_BACKUP" .tar.gz)"
CHECKSUM_FILE="${ARCHIVE_DIR}/${NAME}.sha256"
BINLOG_INFO_FILE="${ARCHIVE_DIR}/${NAME}_binlog_info"
BINLOG_DIR="${BINLOG_ARCHIVE_BASE}/${NAME}"
log_msg "Selected backup: $NAME"

[[ -r "$COMPRESSED_BACKUP" ]] || { log_error "Backup not readable: $COMPRESSED_BACKUP"; fail_restore 1; }
BACKUP_SIZE=$(du -sh "$COMPRESSED_BACKUP" | awk '{print $1}')
[[ "$STATUS_ROW_CREATED" == "1" ]] && record "UPDATE ${STATUS_DB}.RLS03 SET S03F10='$(sql_escape "$NAME")' WHERE S03F02=${RESULT_ID} AND S03F05='RUNNING';"

# --- Verify SHA-256 ---
if [[ ! -f "$CHECKSUM_FILE" ]]; then
  log_warn "Checksum file missing: $CHECKSUM_FILE — integrity NOT verified"
  BACKUP_SHA256="N/A (checksum file missing)"
else
  [[ -s "$CHECKSUM_FILE" ]] || { log_error "Checksum file empty: $CHECKSUM_FILE"; fail_restore 1; }
  EXPECTED_SHA256=$(awk '{print $1}' "$CHECKSUM_FILE")
  log_msg "Verifying SHA-256 (may take a while)..."
  ACTUAL_SHA256=$(sha256sum "$COMPRESSED_BACKUP" | awk '{print $1}')
  if [[ "$EXPECTED_SHA256" != "$ACTUAL_SHA256" ]]; then
    log_error "SHA-256 MISMATCH (expected $EXPECTED_SHA256, got $ACTUAL_SHA256)"
    fail_restore 1 "SHA-256 checksum mismatch — backup may be corrupt"
  fi
  BACKUP_SHA256="$ACTUAL_SHA256"
  log_msg "SHA-256 verified."
  [[ "$STATUS_ROW_CREATED" == "1" ]] && record "UPDATE ${STATUS_DB}.RLS03 SET S03F11='$(sql_escape "$BACKUP_SHA256")' WHERE S03F02=${RESULT_ID} AND S03F05='RUNNING';"
fi

# --- Binlog info (start point) ---
[[ -s "$BINLOG_INFO_FILE" ]] || { log_error "Binlog info missing/empty: $BINLOG_INFO_FILE"; fail_restore 1; }
START_BINLOG="$(awk '{print $1}' "$BINLOG_INFO_FILE")"
START_POS="$(awk '{print $2}' "$BINLOG_INFO_FILE")"
[[ -n "$START_BINLOG" && -n "$START_POS" ]] || { log_error "Invalid binlog info format"; fail_restore 1; }
log_msg "Binlog checkpoint: $START_BINLOG:$START_POS"

# --- Binlog availability ---
BINLOGS_AVAILABLE=true
if [[ ! -d "$BINLOG_DIR" ]]; then
  log_warn "Binlog dir not found: $BINLOG_DIR — restore proceeds WITHOUT point-in-time recovery"
  BINLOGS_AVAILABLE=false
else
  BINLOG_COUNT=$(find "$BINLOG_DIR" -type f -name "binlog.*" 2>/dev/null | wc -l)
  [[ $BINLOG_COUNT -gt 0 ]] || { log_warn "No binlog files in $BINLOG_DIR"; BINLOGS_AVAILABLE=false; }
  [[ "$BINLOGS_AVAILABLE" == true ]] && log_msg "Found $BINLOG_COUNT binlog file(s)"
fi

# --- Datadir sanity + space ---
[[ -n "$MYSQL_DATADIR" && "$MYSQL_DATADIR" != "/" ]] || { log_error "Invalid MYSQL_DATADIR: $MYSQL_DATADIR"; fail_restore 1; }
[[ -d "$MYSQL_DATADIR" ]] || { log_error "MySQL datadir not found: $MYSQL_DATADIR"; fail_restore 1; }
validate_writable "$(dirname "$MYSQL_DATADIR")" || { log_error "Datadir parent not writable"; fail_restore 1; }

DATADIR_FREE=$(get_free_space_gb "$MYSQL_DATADIR")
CSZ=$(stat -c%s "$COMPRESSED_BACKUP" 2>/dev/null || echo 0)
NEED=$(( CSZ / 1024 / 1024 / 1024 * 4 + 4 ))
if [[ "$DATADIR_FREE" -lt "$NEED" ]]; then
  log_error "Insufficient space in $MYSQL_DATADIR (need ~${NEED}GB, have ${DATADIR_FREE}GB)"
  fail_restore 1 "Insufficient disk space for restore"
fi

is_mysql_running && MYSQL_WAS_RUNNING=true || true
log_msg "Pre-flight passed (MySQL running: $MYSQL_WAS_RUNNING)."

{
  echo ""
  echo "===================================================="
  echo "MYSQL DIRECT RESTORE STARTED"
  echo "Result ID     : $RESULT_ID"
  echo "Backup        : $NAME ($BACKUP_SIZE)"
  echo "SHA-256       : $BACKUP_SHA256"
  echo "Binlog start  : $START_BINLOG:$START_POS"
  echo "Binlogs avail : $BINLOGS_AVAILABLE"
  echo "Datadir       : $MYSQL_DATADIR"
  echo "===================================================="
} | tee -a "$RUN_LOG"

############################
# STEP 1: STOP MYSQL
############################

set_stage 1 "Stopping MySQL"
log_msg "[Step 1/5] Stopping MySQL..."
if is_mysql_running; then
  systemctl stop mysql 2>>"$ERROR_LOG" || { log_error "Failed to stop MySQL"; fail_restore 1; }
  sleep 3
  ! is_mysql_running || { log_error "MySQL still running after stop"; fail_restore 1; }
  log_msg "MySQL stopped."
else
  log_msg "MySQL already stopped."
fi

############################
# STEP 2: CLEAR + RESTORE DATADIR
############################

set_stage 2 "Restoring data directory"
log_msg "[Step 2/5] Clearing and restoring data directory..."
[[ -n "$MYSQL_DATADIR" && "$MYSQL_DATADIR" != "/" ]] || { log_error "Refusing to clear invalid datadir"; fail_restore 1; }

rm -rf "${MYSQL_DATADIR:?}/"* 2>>"$ERROR_LOG" || { log_error "Failed to clear data directory"; fail_restore 1; }
[[ -z "$(ls -A "$MYSQL_DATADIR" 2>/dev/null)" ]] || { log_error "Data directory not empty after clear"; fail_restore 1; }
log_msg "Data directory cleared."

log_msg "Extracting $NAME into datadir..."
tar -xzf "$COMPRESSED_BACKUP" -C "$MYSQL_DATADIR" --strip-components=1 2>>"$ERROR_LOG" \
  || { log_error "Failed to extract backup"; fail_restore 1; }
[[ -f "$MYSQL_DATADIR/ibdata1" ]] || { log_error "Core files (ibdata1) missing after extract"; fail_restore 1; }
chown -R mysql:mysql "$MYSQL_DATADIR" 2>>"$ERROR_LOG" || { log_error "Failed to chown datadir"; fail_restore 1; }
log_msg "Data directory restored."

############################
# STEP 3: POST-RESTORE VERIFICATION
############################

set_stage 3 "Verifying restore"
log_msg "[Step 3/5] Post-restore SHA-256 re-check..."
if [[ "$BACKUP_SHA256" != N/A* ]]; then
  POST_SHA=$(sha256sum "$COMPRESSED_BACKUP" | awk '{print $1}')
  [[ "$POST_SHA" == "$BACKUP_SHA256" ]] || { log_error "Checksum changed during extraction (fs corruption?)"; fail_restore 1; }
  log_msg "Post-restore checksum OK."
else
  log_msg "No reference checksum; skipping post-restore compare."
fi

############################
# STEP 4: START MYSQL
############################

set_stage 4 "Starting MySQL"
log_msg "[Step 4/5] Starting MySQL..."
systemctl start mysql 2>>"$ERROR_LOG" || { log_error "Failed to start MySQL"; fail_restore 1; }

MYSQL_READY=false
for i in {1..60}; do
  if mysql_cmd -e "SELECT 1" &>/dev/null; then MYSQL_READY=true; log_msg "MySQL is ready."; break; fi
  [[ $((i % 10)) -eq 0 ]] && log_msg "Waiting for MySQL... (${i}/60)"
  sleep 2
done
[[ "$MYSQL_READY" == true ]] || { log_error "MySQL not ready after 120s"; fail_restore 1 "MySQL failed to start after restore"; }

############################
# STEP 5: APPLY BINLOGS (point-in-time recovery)  — logic preserved from original
############################

set_stage 5 "Applying binlogs"
if [[ "$BINLOGS_AVAILABLE" != true ]]; then
  log_msg "[Step 5/5] No binlogs available — skipping apply."
else
  log_msg "[Step 5/5] Applying binary logs from $START_BINLOG:$START_POS..."

  shopt -s nullglob
  BINLOG_FILES=("$BINLOG_DIR"/binlog.*)
  shopt -u nullglob

  if [[ ${#BINLOG_FILES[@]} -eq 0 ]]; then
    log_warn "No binlog files found to apply"
  else
    IFS=$'\n' BINLOG_FILES=($(sort <<<"${BINLOG_FILES[*]}")); unset IFS
    APPLY_STARTED=false
    log_msg "Found ${#BINLOG_FILES[@]} binlog file(s) to process"

    for BINLOG_PATH in "${BINLOG_FILES[@]}"; do
      BINLOG_FILE="$(basename "$BINLOG_PATH")"
      [[ "$BINLOG_FILE" == *".log" ]] && continue
      [[ "$BINLOG_FILE" == "last_copied_binlog" ]] && continue

      if [[ "$BINLOG_FILE" == "$START_BINLOG" ]]; then
        log_msg "Applying $BINLOG_FILE from position $START_POS"
        rls03_apply_progress "$BINLOG_FILE"
        if ! "$MYSQLBINLOG_BIN" --skip-gtids --disable-log-bin --start-position="$START_POS" \
             "$BINLOG_PATH" 2>>"$ERROR_LOG" | mysql_cmd 2>>"$ERROR_LOG"; then
          log_error "Failed to apply $BINLOG_FILE from position $START_POS"
          BINLOG_ERRORS=$((BINLOG_ERRORS + 1))
        else
          APPLIED_COUNT=$((APPLIED_COUNT + 1)); log_msg "Applied: $BINLOG_FILE"
        fi
        APPLY_STARTED=true
        rls03_apply_progress "$BINLOG_FILE"
        continue
      fi

      if [[ "$APPLY_STARTED" == true ]]; then
        log_msg "Applying $BINLOG_FILE"
        rls03_apply_progress "$BINLOG_FILE"
        if ! "$MYSQLBINLOG_BIN" --skip-gtids --disable-log-bin \
             "$BINLOG_PATH" 2>>"$ERROR_LOG" | mysql_cmd 2>>"$ERROR_LOG"; then
          log_error "Failed to apply $BINLOG_FILE"
          BINLOG_ERRORS=$((BINLOG_ERRORS + 1))
        else
          APPLIED_COUNT=$((APPLIED_COUNT + 1)); log_msg "Applied: $BINLOG_FILE"
        fi
        rls03_apply_progress "$BINLOG_FILE"
      fi
    done

    [[ "$APPLY_STARTED" == true ]] || log_warn "Start binlog $START_BINLOG not found in archive"
    [[ $BINLOG_ERRORS -gt 0 ]] && log_warn "$BINLOG_ERRORS binlog(s) failed to apply (see $ERROR_LOG)"
    log_msg "Binlog apply: $APPLIED_COUNT applied, $BINLOG_ERRORS errors"
  fi
fi

############################
# FINAL VALIDATION
############################

is_mysql_running || { log_error "MySQL not running after restore"; fail_restore 1; }
test_mysql_connection || { log_error "Cannot connect to MySQL after restore"; fail_restore 1; }
DB_COUNT=$(mysql_cmd -NBe "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema','mysql','performance_schema','sys')" 2>>"$ERROR_LOG" || echo "0")
log_msg "Final validation passed. User databases: $DB_COUNT"

############################
# RECORD SUCCESS
############################

if [[ "$STATUS_ROW_CREATED" == "1" ]]; then
  heartbeat_stop
  close_stage "SUCCESS"
  record "UPDATE ${STATUS_DB}.RLS03
            SET S03F05='SUCCESS', S03F06='Completed', S03F07=${TOTAL_STAGES}, S03C07=NOW(),
                S03F12='$(sql_escape "$START_BINLOG")', S03F13='$(sql_escape "$START_POS")',
                S03F14=${DB_COUNT}, S03F15=${APPLIED_COUNT}, S03F16=${BINLOG_ERRORS},
                S03F17=0, S03F19=''
          WHERE S03F02=${RESULT_ID} AND S03F05='RUNNING';"
  log_msg "RLS03 SUCCESS recorded for RESULT_ID=${RESULT_ID}."
fi

END_EPOCH="$(date +%s)"; DURATION=$((END_EPOCH - START_EPOCH))
{
  echo ""
  echo "===================================================="
  echo "RESTORE COMPLETED SUCCESSFULLY"
  echo "===================================================="
  echo "Result ID       : $RESULT_ID"
  echo "Backup restored : $NAME"
  echo "Duration        : $((DURATION / 60))m $((DURATION % 60))s"
  echo "User databases  : $DB_COUNT"
  echo "Binlogs applied : $APPLIED_COUNT (errors: $BINLOG_ERRORS)"
  echo "Binlog start    : $START_BINLOG:$START_POS"
  echo "===================================================="
} | tee -a "$RUN_LOG"

trap - ERR INT TERM
exit 0
