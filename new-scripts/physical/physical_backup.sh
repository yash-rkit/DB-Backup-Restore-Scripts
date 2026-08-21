#!/usr/bin/env bash
#
# physical_backup.sh
#
# Full physical (Percona XtraBackup) backup of the entire MySQL instance.
# Unlike the logical backup, XtraBackup snapshots the whole datadir as ONE
# atomic unit — there is no per-database granularity — so status is tracked as:
#   BLS02 : ONE summary row per run (RUNNING -> SUCCESS/FAILED), keyed by
#           RESULT_ID, holding current stage + final archive/size/checksum/binlog.
#   BLS03 : the stage timeline — one row per stage, RUNNING -> SUCCESS/FAILED,
#           each with StartedAt + CompletedAt, for the job-detail view.
# Both tables are created, and the RUNNING row inserted, BEFORE pre-flight, so a
# pre-flight failure or a cancelled run is still recorded rather than invisible.
# A background heartbeat bumps BLS02.S02C04 for the whole run so the dashboard
# can distinguish "working" from "stuck" (incl. an untrappable SIGKILL).
#
# Parameterization (per DB BRD Script Authoring Guide):
#   - Positional args ($1, $2, $5, $7)  -> runtime data
#   - {{CMC27:key-name}} tokens         -> secrets, resolved by the API before
#                                          SSH delivery. Never visible in `ps aux`.
#
# Usage (delivered by the API via heredoc over SSH, no files written remotely):
#   the API passes positional args $1-$9; this script uses $1, $2, $5, $7 and $9.
#
# $1  RESULT_ID    - BJR01.CentralResultId this run belongs to; stored in
#                    BLS02.S02F02 on the status row for this run.
# $2  SERVER_NAME  - source server identifier (used in logs + BLS02.S02F03).
# $5  BASE_DIR     - STORAGE_ROOT; shared storage mount root. The archive
#                    destination is BASE_DIR/ARCHIVE_FOLDER (appended below),
#                    so the same base dir can be reused across scripts.
# $7  STATUS_DB    - database holding BLS02.
# $9  CONFIG_ID    - BJC03.ConfigId, the backup job *definition* (vs RESULT_ID,
#                    which is this one execution). The archive filename is
#                    namespaced job<CONFIG_ID>_... so a file can be matched back
#                    to its job by eye at restore time.
#
# NOTE: BACKUP_BASE below is the LOCAL staging directory (must be fast local
# disk next to the datadir). The prepared+compressed archive is then moved to
# the shared archive dir under BASE_DIR. This mirrors the original
# BACKUP_BASE -> ARCHIVE_DIR flow.
#
set -euo pipefail

############################
# CONFIGURATION
############################

# --- Positional args — passed by the API at run time ---
RESULT_ID="$1"
SERVER_NAME="${2:-}"
BASE_DIR="$5"
STATUS_DB="$7"
CONFIG_ID="${9:-}"         # BJC03.ConfigId — the backup job *definition* this run
                          # belongs to; used to namespace the archive filename.

# --- DB credentials — injected from CMC27 before SSH delivery -------------
# The API replaces these tokens with plaintext values before the script is
# sent to the server. They live in the script body, not as CLI args, so they
# are never visible in `ps aux`.
MYSQL_HOST="{{CMC27:db-host}}"
MYSQL_PORT="{{CMC27:db-port}}"
MYSQL_USER="{{CMC27:db-user}}"
MYSQL_PASSWORD="{{CMC27:db-password}}"

# --- Timezone for ALL MySQL operations -------------------------------------
# Every mysql invocation in this script (record(), mysql_cmd(), heartbeat
# ticker, pre-flight checks, ensure_status_tables) pins the session to IST via
# --init-command, so NOW() in BLS02/BLS03/BLS04 timestamps and any timezone-
# sensitive reads are consistent regardless of the server's default tz.
MYSQL_TZ="+05:30"
MYSQL_CONNECT_OPTS=(--init-command="SET time_zone='${MYSQL_TZ}'")

# --- Archive destination folder — appended to BASE_DIR ($5) ---------------
ARCHIVE_FOLDER="Cloud-Live-DB-Tirupati"

# --- Server-local settings (edit here, not passed via CLI) ----------------
# Local staging area for the backup (fast local disk near the datadir).
BACKUP_BASE="/Data/Cloud-Live-DB-Tirupati"
# Percona XtraBackup binary path
XTRABACKUP_BIN="/usr/bin/xtrabackup"
# MySQL data directory
MYSQL_DATADIR="/Data/mysql"
# MySQL client binary for connection testing
MYSQL_BIN="/usr/bin/mysql"
# Number of parallel threads for xtrabackup
PARALLEL_THREADS=2
# MySQL binlog location: directory + basename (files are <BINLOG_BASE>.NNNNNN).
# Used by the inline post-backup binlog collection (stage 8).
BINLOG_BASE="/Data/mysql/binlog"

# --- Validate required positional arguments ---
missing=()
[[ -n "${RESULT_ID:-}" ]] || missing+=("RESULT_ID (\$1)")
[[ -n "${BASE_DIR:-}" ]]  || missing+=("BASE_DIR (\$5)")
[[ -n "${STATUS_DB:-}" ]] || missing+=("STATUS_DB (\$7)")
if [[ "${#missing[@]}" -gt 0 ]]; then
  echo "ERROR: missing required argument(s): ${missing[*]}" >&2
  echo "Usage: $0 expects positional args \$1=RESULT_ID \$5=BASE_DIR \$7=STATUS_DB" >&2
  exit 1
fi

# Remote / secondary storage directory (final archive destination)
ARCHIVE_DIR="${BASE_DIR}/${ARCHIVE_FOLDER}"

# Binlog collection (stage 8) — where binlogs live on disk and where they land.
BINLOG_DIR="$(dirname "$BINLOG_BASE")"
BINLOG_PREFIX="$(basename "$BINLOG_BASE")"
BINLOG_ARCHIVE_BASE="${ARCHIVE_DIR}/binlog"

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
UNCOMPRESSED_BYTES=0
COMPRESSED_SIZE=0
COMPRESSION_RATIO="N/A"
BACKUP_SHA256=""
BINLOG_NAME="unknown"
BINLOG_POS="0"
LAST_ERROR=""              # updated by log_error(); used for the FAILED status row
STATUS_ROW_CREATED=0       # set to 1 once the RUNNING row exists in BLS02
HEARTBEAT_PID=""           # PID of the background heartbeat ticker, when running
CURRENT_STAGE=0            # numeric stage the run is in (0 = pre-flight)
CURRENT_STAGE_TEXT="Pre-flight checks"   # human text for the current stage

# Today's date
TODAY="$(date +%Y%m%d)"

# Lock file — date-prefixed so yesterday's lock never affects today
# Removed by fail_backup on failure AND at end of script on success
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

# Log error function (also records the message for the FAILED status row)
log_error() {
  LAST_ERROR="$1"
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

# Fire-and-forget status write — ALWAYS guarded with `|| true` so a status-DB
# hiccup can never trigger the ERR trap and delete a good backup.
record() {
  "$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" \
    "${MYSQL_CONNECT_OPTS[@]}" \
    -e "$1" 2>/dev/null || true
}

# Escape single quotes for safe inlining into SQL string literals by doubling
# them ('' — the SQL standard). A quote variable is used deliberately: writing
# the replacement as \'\' inside double quotes leaves the backslashes literal
# and produces \'\' instead of '', which corrupts the value (and breaks under
# NO_BACKSLASH_ESCAPES). $q$q expands to two real quotes with no backslashes.
sql_escape() { local q="'"; printf '%s' "${1//$q/$q$q}"; }

# Total number of visible stages (keep in sync with the set_stage calls below).
# 1-7 = backup steps, 8 = post-backup binlog collection.
TOTAL_STAGES=8

# How often (seconds) the background ticker bumps the heartbeat during the two
# long xtrabackup phases. Keep well below the dashboard's "stuck" threshold.
HEARTBEAT_INTERVAL=30

# BLS03 stage timeline: one row per stage, RUNNING -> SUCCESS/FAILED, each with
# its own StartedAt (S03C06) and CompletedAt (S03C07) so the job-detail view can
# show every stage's status and duration.

# Close the currently-open stage row (if any) with a terminal status + end time.
# Only one stage is ever open (RUNNING) at a time, so the WHERE is unambiguous.
#   $1 = SUCCESS | FAILED    $2 = optional message (e.g. failure reason)
close_stage() {
  [[ "$STATUS_ROW_CREATED" == "1" ]] || return 0
  local status="$1" msg="${2:-}" set_msg=""
  if [[ -n "$msg" ]]; then set_msg=", S03F06='$(sql_escape "$msg")'"; fi
  record "UPDATE ${STATUS_DB}.BLS03
            SET S03F05='${status}', S03C07=NOW()${set_msg}
          WHERE S03F02=${RESULT_ID} AND S03F05='RUNNING';"
}

# Advance to a new stage: update the BLS02 summary row (progress bar + heartbeat),
# close the previous BLS03 stage as SUCCESS, and open this one as RUNNING.
# CURRENT_STAGE/_TEXT are set unconditionally so fail_backup can attribute a
# failure to the right stage even when the status row was never created.
set_stage() {
  local n="$1" text="$2"
  CURRENT_STAGE="$n"
  CURRENT_STAGE_TEXT="$text"
  [[ "$STATUS_ROW_CREATED" == "1" ]] || return 0
  record "UPDATE ${STATUS_DB}.BLS02
            SET S02F04='$(sql_escape "$text")', S02F17=${n}, S02F18=${TOTAL_STAGES}
          WHERE S02F02=${RESULT_ID} AND S02F07='RUNNING';"
  close_stage "SUCCESS"
  record "INSERT INTO ${STATUS_DB}.BLS03
            (S03F02, S03F03, S03F04, S03F05, S03C06)
          VALUES
            (${RESULT_ID}, ${n}, '$(sql_escape "$text")', 'RUNNING', NOW());"
}

# Create the physical-backup status tables if they don't already exist.
#   BLS02 = one summary row per run (current state + final metadata)
#   BLS03 = many rows per run — the timestamped stage timeline for the detail view
# Piped in via heredoc (not -e) so the DDL doesn't need any quote escaping; the
# mysql client runs both ;-separated statements. Guarded by the caller (used
# inside `if`) so a failure never aborts the backup.
ensure_status_tables() {
  local out rc
  out="$("$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" \
    "${MYSQL_CONNECT_OPTS[@]}" 2>&1 <<SQL
CREATE TABLE IF NOT EXISTS ${STATUS_DB}.BLS02 (
    S02F01 INT NOT NULL AUTO_INCREMENT
        COMMENT 'StatusId PK',
    S02F02 BIGINT NULL
        COMMENT 'CentralResultId FK→BJR01',
    S02F03 VARCHAR(255) NULL
        COMMENT 'ServerName',
    S02F04 VARCHAR(120) NULL
        COMMENT 'CurrentStage (live progress text)',
    S02F07 ENUM('RUNNING','SUCCESS','FAILED') NOT NULL
        COMMENT 'Status',
    S02F08 INT NULL
        COMMENT 'Pid',
    S02C06 DATETIME NOT NULL
        COMMENT 'StartedAt',
    S02C07 DATETIME NULL
        COMMENT 'CompletedAt',
    S02F09 VARCHAR(500) NULL
        COMMENT 'ArchiveFilePath',
    S02F10 BIGINT NULL
        COMMENT 'CompressedSizeBytes',
    S02F11 BIGINT NULL
        COMMENT 'UncompressedSizeBytes',
    S02F12 VARCHAR(64) NULL
        COMMENT 'Sha256Checksum',
    S02F13 VARCHAR(255) NULL
        COMMENT 'BinlogFile',
    S02F14 BIGINT NULL
        COMMENT 'BinlogPosition',
    S02F15 INT NULL
        COMMENT 'ExitCode',
    S02F16 TEXT NULL
        COMMENT 'ErrorMessage',
    S02F17 TINYINT NULL
        COMMENT 'StageNumber (1..7; used with TotalStages for progress bar)',
    S02F18 TINYINT NULL
        COMMENT 'TotalStages',
    S02F19 INT NULL
        COMMENT 'ConfigId (BJC03.ConfigId — the backup job definition, positional arg 9)',
    S02C04 DATETIME NOT NULL
        DEFAULT CURRENT_TIMESTAMP
        ON UPDATE CURRENT_TIMESTAMP
        COMMENT 'UpdatedAt (heartbeat — bumps on every write)',
    PRIMARY KEY (S02F01),
    INDEX idx_bls02_result (S02F02),
    INDEX idx_bls02_status (S02F07)
) ENGINE=InnoDB
DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS ${STATUS_DB}.BLS03 (
    S03F01 INT NOT NULL AUTO_INCREMENT
        COMMENT 'StageId PK',
    S03F02 BIGINT NULL
        COMMENT 'CentralResultId FK→BJR01/BLS02',
    S03F03 TINYINT NULL
        COMMENT 'StageNumber (0=pre-flight, 1..7=backup steps)',
    S03F04 VARCHAR(120) NULL
        COMMENT 'StageText',
    S03F05 ENUM('RUNNING','SUCCESS','FAILED') NOT NULL
        COMMENT 'StageStatus (RUNNING until the stage finishes)',
    S03F06 TEXT NULL
        COMMENT 'Message (e.g. failure reason)',
    S03C06 DATETIME NOT NULL
        COMMENT 'StartedAt',
    S03C07 DATETIME NULL
        COMMENT 'CompletedAt (set when the stage finishes)',
    PRIMARY KEY (S03F01),
    INDEX idx_bls03_result (S03F02),
    INDEX idx_bls03_result_stage (S03F02, S03F01)
) ENGINE=InnoDB
DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS ${STATUS_DB}.BLS04 (
    S04F01 INT NOT NULL AUTO_INCREMENT
        COMMENT 'CollectId PK',
    S04F02 BIGINT NULL
        COMMENT 'CentralResultId (the collection run — the backup RESULT_ID here)',
    S04F03 INT NULL
        COMMENT 'ConfigId (the backup job definition)',
    S04F04 VARCHAR(255) NULL
        COMMENT 'ServerName',
    S04F05 VARCHAR(64) NULL
        COMMENT 'ReferenceAnchor (job<cfg>_<date>)',
    S04F06 VARCHAR(32) NULL
        COMMENT 'ReferenceDate (yyyymmdd of the anchoring backup)',
    S04F07 ENUM('RUNNING','SUCCESS','FAILED','SKIPPED') NOT NULL
        COMMENT 'Status',
    S04F08 INT NULL
        COMMENT 'Pid',
    S04F09 VARCHAR(255) NULL
        COMMENT 'StartBinlog',
    S04F10 VARCHAR(255) NULL
        COMMENT 'LatestBinlog (live: file being copied; on success: newest in archive = coverage endpoint)',
    S04F11 INT NULL
        COMMENT 'CopiedThisRun',
    S04F12 INT NULL
        COMMENT 'SkippedThisRun',
    S04F13 INT NULL
        COMMENT 'ErrorsThisRun',
    S04F14 INT NULL
        COMMENT 'TotalBinlogsInArchive (cumulative for this reference)',
    S04F15 BIGINT NULL
        COMMENT 'TotalArchiveSizeBytes (cumulative)',
    S04F16 INT NULL
        COMMENT 'ExitCode',
    S04F17 TEXT NULL
        COMMENT 'ErrorMessage',
    S04C06 DATETIME NOT NULL
        COMMENT 'StartedAt',
    S04C07 DATETIME NULL
        COMMENT 'CompletedAt',
    S04C04 DATETIME NOT NULL
        DEFAULT CURRENT_TIMESTAMP
        ON UPDATE CURRENT_TIMESTAMP
        COMMENT 'UpdatedAt (heartbeat)',
    PRIMARY KEY (S04F01),
    INDEX idx_bls04_result (S04F02),
    INDEX idx_bls04_config (S04F03),
    INDEX idx_bls04_ref (S04F06),
    INDEX idx_bls04_status (S04F07)
) ENGINE=InnoDB
DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;
SQL
)"
  rc=$?
  # mysql prints the "Using a password on the command line" warning to stderr
  # even on success, so only surface output when it actually failed.
  if [[ $rc -ne 0 ]]; then
    log_warn "Status table setup failed (rc=$rc): ${out//$'\n'/ | }"
  fi
  return $rc
}

# --- Live heartbeat for the whole run -------------------------------------
# Long phases (xtrabackup --backup/--prepare, compression) are single commands
# that write nothing to the status row while they run. This background ticker
# bumps S02C04 every HEARTBEAT_INTERVAL seconds for the ENTIRE run, so the
# dashboard can always tell "working" from "stuck" — and a hard kill (SIGKILL,
# which cannot be trapped) shows up as a stale heartbeat. Started right after the
# status row is created; stopped on success, on failure, and via the EXIT trap.
heartbeat_start() {
  [[ "$STATUS_ROW_CREATED" == "1" ]] || return 0
  heartbeat_stop   # never leave two tickers running
  (
    while true; do
      sleep "$HEARTBEAT_INTERVAL"
      "$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" \
        "${MYSQL_CONNECT_OPTS[@]}" \
        -e "UPDATE ${STATUS_DB}.BLS02 SET S02C04=NOW() WHERE S02F02=${RESULT_ID} AND S02F07='RUNNING';" \
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

# Mark the run FAILED, stop the heartbeat, clean up partial artifacts, exit 1.
# Central failure path: called both from the ERR/signal trap and directly from
# handled step failures (plain `exit 1` does NOT fire the ERR trap, so every
# failure must route through here to guarantee the BLS02 row is closed out).
#   $1 = exit/return code to record (defaults 1)
#   $2 = reason (defaults to the last logged error)
fail_backup() {
  local ec="${1:-1}"
  local reason="${2:-${LAST_ERROR:-Backup failed; see logs}}"

  trap - ERR INT TERM        # disarm so cleanup can't re-enter
  heartbeat_stop

  log_error "Backup failed (exit code: $ec). Cleaning up..."

  # Close the open BLS03 stage as FAILED + mark the BLS02 summary row FAILED
  # (only if the RUNNING row was created).
  if [[ "$STATUS_ROW_CREATED" == "1" && -n "${RESULT_ID:-}" ]]; then
    close_stage "FAILED" "$reason"
    record "UPDATE ${STATUS_DB}.BLS02
              SET S02F07='FAILED', S02C07=NOW(), S02F15=${ec}, S02F16='$(sql_escape "$reason")'
            WHERE S02F02=${RESULT_ID} AND S02F07='RUNNING';"
  fi

  # Remove lock file
  if [[ -f "$LOCK_FILE" ]]; then
    log_msg "Removing lock file on failure: $LOCK_FILE"
    rm -f "$LOCK_FILE" 2>/dev/null || true
  fi

  # Remove incomplete backup directory
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
  exit 1
}

# ERR / signal trap — captures the failing command's exit code, then fails.
on_trap() { local ec=$?; fail_backup "$ec"; }
trap on_trap ERR INT TERM

# Safety net: never let the background heartbeat ticker outlive the script,
# no matter how we exit (normal, handled failure, or preflight exit).
trap heartbeat_stop EXIT

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
  if ! "$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" \
       "${MYSQL_CONNECT_OPTS[@]}" \
       -e "SELECT 1" >/dev/null 2>&1; then
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
# BINLOG COLLECTION (STAGE 8) — helpers
############################

# Live BLS04 progress counters (globals so bls04_progress can read them).
BL_START=""; BL_CUR=""; BL_COPIED=0; BL_SKIPPED=0; BL_ERRORS=0; BL_TOTAL=0

mysql_cmd() { "$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" "${MYSQL_CONNECT_OPTS[@]}" "$@"; }
is_binlog_file() { [[ "$1" =~ \.[0-9]{6}$ ]]; }
get_current_binlog() {
  local r
  r=$(mysql_cmd -NBe "SHOW BINARY LOG STATUS" 2>/dev/null | awk '{print $1}') || true
  [[ -n "$r" ]] || r=$(mysql_cmd -NBe "SHOW MASTER STATUS" 2>/dev/null | awk '{print $1}') || true
  echo "$r"
}

# Push live binlog progress to the BLS04 row (best-effort; also bumps heartbeat).
bls04_progress() {
  [[ "$STATUS_ROW_CREATED" == "1" ]] || return 0
  record "UPDATE ${STATUS_DB}.BLS04
            SET S04F10='$(sql_escape "$BL_CUR")',
                S04F11=${BL_COPIED}, S04F12=${BL_SKIPPED}, S04F13=${BL_ERRORS}, S04F14=${BL_TOTAL}
          WHERE S04F02=${RESULT_ID} AND S04F07='RUNNING';"
}

# Inline post-backup binlog collection. Anchor = THIS backup's binlog position;
# copies binlogs generated since the backup into BINLOG_ARCHIVE_BASE/<NAME> and
# records a BLS04 row. Best-effort: invoked via `if collect_binlogs` so errexit
# is disabled inside and a failure here NEVER aborts the backup (archive is safe).
collect_binlogs() {
  local anchor_base="$NAME"
  local ref_date target_dir state_file start_binlog current_binlog src size dst_size cfg_sql total_bytes f found_start
  ref_date="$(echo "$NAME" | grep -oE '[0-9]{8}' | head -1)"
  target_dir="${BINLOG_ARCHIVE_BASE}/${anchor_base}"
  state_file="${target_dir}/last_copied_binlog"

  mkdir -p "$target_dir" 2>/dev/null || { log_warn "binlog: cannot create $target_dir"; return 1; }
  BL_TOTAL=$(find "$target_dir" -maxdepth 1 -type f -name "${BINLOG_PREFIX}.*" 2>/dev/null | wc -l)

  # Resume from state file if present, else this backup's binlog position.
  start_binlog=""
  [[ -s "$state_file" ]] && start_binlog="$(cat "$state_file")"
  [[ -n "$start_binlog" ]] || start_binlog="$BINLOG_NAME"
  is_binlog_file "$start_binlog" || { log_warn "binlog: invalid start '$start_binlog'; skipping"; return 1; }
  BL_START="$start_binlog"

  cfg_sql="NULL"; [[ "$CONFIG_ID" =~ ^[0-9]+$ ]] && cfg_sql="$CONFIG_ID"
  record "INSERT INTO ${STATUS_DB}.BLS04
            (S04F02, S04F03, S04F04, S04F05, S04F06, S04F07, S04F08, S04F09, S04F14, S04C06)
          VALUES
            (${RESULT_ID}, ${cfg_sql}, '$(sql_escape "$SERVER_NAME")',
             '$(sql_escape "$anchor_base")', '$(sql_escape "$ref_date")',
             'RUNNING', $$, '$(sql_escape "$start_binlog")', ${BL_TOTAL}, NOW());"

  # Rotate so the binlog active during the backup becomes safe to copy.
  mysql_cmd -e "FLUSH BINARY LOGS;" 2>>"$ERROR_LOG" || log_warn "binlog: FLUSH failed"
  sync; sleep 1
  current_binlog="$(get_current_binlog)"
  log_msg "binlog: collecting from ${start_binlog}; active (skipped) = ${current_binlog:-?}"

  found_start=false
  local files=()
  shopt -s nullglob
  mapfile -t files < <(for f in "$BINLOG_DIR/${BINLOG_PREFIX}."*; do basename "$f"; done | sort)
  shopt -u nullglob

  for f in "${files[@]}"; do
    is_binlog_file "$f" || continue
    [[ "$f" == "$start_binlog" ]] && found_start=true
    if [[ "$found_start" != true ]]; then BL_SKIPPED=$((BL_SKIPPED + 1)); continue; fi
    [[ "$f" == "$current_binlog" ]] && continue
    [[ -f "$target_dir/$f" ]] && continue          # already collected
    src="$BINLOG_DIR/$f"
    [[ -r "$src" ]] || { log_warn "binlog: unreadable $f"; BL_ERRORS=$((BL_ERRORS + 1)); continue; }
    size=$(stat -c%s "$src" 2>/dev/null || echo 0)
    [[ "$size" -gt 0 ]] || { BL_SKIPPED=$((BL_SKIPPED + 1)); continue; }
    BL_CUR="$f"; bls04_progress
    if ! cp -p "$src" "$target_dir/" 2>>"$ERROR_LOG"; then
      log_warn "binlog: copy failed $f"; rm -f "$target_dir/$f" 2>/dev/null || true; BL_ERRORS=$((BL_ERRORS + 1)); continue
    fi
    dst_size=$(stat -c%s "$target_dir/$f" 2>/dev/null || echo 0)
    if [[ "$size" -ne "$dst_size" ]]; then
      log_warn "binlog: size mismatch $f"; rm -f "$target_dir/$f" 2>/dev/null || true; BL_ERRORS=$((BL_ERRORS + 1)); continue
    fi
    echo "$f" > "$state_file"
    BL_COPIED=$((BL_COPIED + 1)); BL_TOTAL=$((BL_TOTAL + 1)); BL_CUR=""
    bls04_progress
    log_msg "binlog: copied $f"
  done

  [[ "$found_start" == true ]] || log_warn "binlog: start $start_binlog not on disk (purged?); collected nothing new"

  BL_TOTAL=$(find "$target_dir" -maxdepth 1 -type f -name "${BINLOG_PREFIX}.*" 2>/dev/null | wc -l)
  total_bytes=$(du -sb "$target_dir" 2>/dev/null | awk '{print $1}'); total_bytes="${total_bytes:-0}"
  local latest_binlog
  latest_binlog=$(find "$target_dir" -maxdepth 1 -type f -name "${BINLOG_PREFIX}.*" 2>/dev/null | sort | tail -1 | xargs -r basename 2>/dev/null || echo "")
  record "UPDATE ${STATUS_DB}.BLS04
            SET S04F07='SUCCESS', S04C07=NOW(), S04F16=0,
                S04F10='$(sql_escape "$latest_binlog")',
                S04F11=${BL_COPIED}, S04F12=${BL_SKIPPED}, S04F13=${BL_ERRORS},
                S04F14=${BL_TOTAL}, S04F15=${total_bytes}
          WHERE S04F02=${RESULT_ID} AND S04F07='RUNNING';"
  log_msg "binlog: done — copied ${BL_COPIED}, total in archive ${BL_TOTAL}"
  return 0
}

############################
# DERIVED PATHS
############################

# Base name for every artifact of this run:
#   job<CONFIG_ID>  - namespaces the file to its backup job definition ($9), so
#                     it can be matched back to the job by eye at restore time.
#   <TODAY>         - date of the run.
# e.g. job5_20260711 ; on a same-day collision, job5_20260711_143005 (a time
# component is appended below to keep the name unique across same-day runs).
NAME="job${CONFIG_ID}_${TODAY}"

# Temporary directory for backup (will be removed after compression)
TARGET_DIR="${BACKUP_BASE}/${NAME}"

# Final compressed backup file
COMPRESSED_FILE="${BACKUP_BASE}/${NAME}.tar.gz"

# SHA-256 checksum file
CHECKSUM_FILE="${BACKUP_BASE}/${NAME}.sha256"

# External binlog info file (for fast access without extracting archive)
BINLOG_INFO_FILE="${BACKUP_BASE}/${NAME}_binlog_info"

# Log files
XTRABACKUP_LOG="${BACKUP_BASE}/${NAME}_xtrabackup.log"
RUN_LOG="${BACKUP_BASE}/${NAME}_backup.log"
ERROR_LOG="${BACKUP_BASE}/${NAME}_errors.log"

# Timestamps for duration tracking
START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
START_EPOCH="$(date +%s)"

############################
# INITIALIZE STATUS TRACKING
# Done BEFORE setup and pre-flight (not after) so the status tables ALWAYS exist
# and a failure or cancellation during setup/pre-flight is still recorded as
# FAILED — previously a pre-flight failure left no trace at all. This only needs
# MySQL to be reachable; local backup dirs are created later.
############################

# ConfigId is an INT column; use NULL when $9 is absent/non-numeric.
CONFIG_ID_SQL="NULL"
if [[ "$CONFIG_ID" =~ ^[0-9]+$ ]]; then CONFIG_ID_SQL="$CONFIG_ID"; fi

log_msg "Ensuring status tables (BLS02/BLS03) exist..."
if ensure_status_tables; then
  record "INSERT INTO ${STATUS_DB}.BLS02
            (S02F02, S02F03, S02F04, S02F07, S02F08, S02F17, S02F18, S02F19, S02C06)
          VALUES
            (${RESULT_ID}, '$(sql_escape "$SERVER_NAME")', 'Pre-flight checks',
             'RUNNING', $$, 0, ${TOTAL_STAGES}, ${CONFIG_ID_SQL}, NOW());"
  STATUS_ROW_CREATED=1
  set_stage 0 "Pre-flight checks"   # opens the first BLS03 stage row
  heartbeat_start
  log_msg "Status row created (BLS02) for RESULT_ID=${RESULT_ID}; pre-flight starting."
else
  log_warn "Could not create status tables (is MySQL reachable?); continuing without DB status."
fi

############################
# SETUP
############################

# Handle existing backup (append a time component if a same-day run already
# exists, to keep the name unique): job5_20260711_143005.
# The archive is checked too, not just local staging: staging is wiped after
# each run, so without the ARCHIVE_DIR check a same-day rerun would not detect
# the already-archived job<cfg>_<date>.tar.gz and could overwrite it on move.
if [[ -d "$TARGET_DIR" || -f "$COMPRESSED_FILE" || -f "${ARCHIVE_DIR}/${NAME}.tar.gz" ]]; then
  TIMESTAMP="$(date +%H%M%S)"
  NAME="job${CONFIG_ID}_${TODAY}_${TIMESTAMP}"
  TARGET_DIR="${BACKUP_BASE}/${NAME}"
  COMPRESSED_FILE="${BACKUP_BASE}/${NAME}.tar.gz"
  CHECKSUM_FILE="${BACKUP_BASE}/${NAME}.sha256"
  BINLOG_INFO_FILE="${BACKUP_BASE}/${NAME}_binlog_info"
  XTRABACKUP_LOG="${BACKUP_BASE}/${NAME}_xtrabackup.log"
  RUN_LOG="${BACKUP_BASE}/${NAME}_backup.log"
  ERROR_LOG="${BACKUP_BASE}/${NAME}_errors.log"
fi

# Create directories with proper error handling
for dir in "$BACKUP_BASE" "$ARCHIVE_DIR"; do
  if [[ ! -d "$dir" ]]; then
    if ! mkdir -p "$dir" 2>/dev/null; then
      log_error "Failed to create directory: $dir"
      fail_backup 1
    fi
  fi
done

# Create target directory
if ! mkdir -p "$TARGET_DIR" 2>/dev/null; then
  log_error "Failed to create target directory: $TARGET_DIR"
  fail_backup 1
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
    fail_backup 1
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
  fail_backup 1
fi
log_msg "MySQL is running"

# Check 5: Verify MySQL data directory exists and is readable
log_msg "Check 5/14: Verifying MySQL data directory..."
if [[ ! -d "$MYSQL_DATADIR" ]]; then
  log_error "MySQL datadir not found: $MYSQL_DATADIR"
  fail_backup 1
fi

if [[ ! -r "$MYSQL_DATADIR" ]]; then
  log_error "MySQL datadir not readable: $MYSQL_DATADIR"
  fail_backup 1
fi
log_msg "MySQL datadir exists and is readable: $MYSQL_DATADIR"

# Check 6: Verify MySQL connection
log_msg "Check 6/14: Testing MySQL connection..."
if ! test_mysql_connection; then
  log_error "Cannot connect to MySQL with provided credentials"
  log_error "User: $MYSQL_USER"
  fail_backup 1
fi
log_msg "MySQL connection successful"

# Check 7: Verify backup directory is writable
log_msg "Check 7/14: Verifying backup directory is writable..."
if ! validate_writable "$BACKUP_BASE"; then
  log_error "Backup directory is not writable: $BACKUP_BASE"
  fail_backup 1
fi
log_msg "Backup directory is writable"

# Check 8: Verify archive directory is writable
log_msg "Check 8/14: Verifying archive directory is writable..."
if ! validate_writable "$ARCHIVE_DIR"; then
  log_error "Archive directory is not writable: $ARCHIVE_DIR"
  fail_backup 1
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
  fail_backup 1
fi

if [[ $ARCHIVE_FREE_SPACE -lt $REQUIRED_ARCHIVE_SPACE ]]; then
  log_error "Insufficient space in $ARCHIVE_DIR"
  log_error "Required: ${REQUIRED_ARCHIVE_SPACE}GB, Available: ${ARCHIVE_FREE_SPACE}GB"
  fail_backup 1
fi

log_msg "Sufficient disk space available"

# Check 10: Verify no other backup is running
#
# Earlier versions used `pgrep -f` against process command lines, then
# re-verified with `ps`. That is fundamentally racy: it can only report what
# matched at the instant it ran, and a live system is constantly forking and
# reaping processes — by the time a human (or the script) acts on the
# reported PID, the process can easily have already exited. That's exactly
# the "No such process" you saw: the check wasn't lying, it just couldn't
# stay accurate across the gap between detection and action.
#
# Fixed approach: a kernel-enforced flock() on a fixed lock file instead of
# string-matching. flock() is atomic (no race between "check" and "act") and
# — critically — the kernel releases it automatically the instant the holding
# process's file descriptor closes, including on crash or an untrappable
# SIGKILL. There is no PID pattern to get wrong and no stale lock to clean up
# by hand. FD 200 is held open for the rest of this script, so the lock
# covers the entire run, not just this one check.
############################
log_msg "Check 10/14: Checking for concurrent backups..."

CONCURRENCY_LOCK_FILE="${BACKUP_BASE}/.xtrabackup_run.lock"
# <> opens read-write, creating the file if missing, WITHOUT truncating —
# using '>' here would wipe the current holder's metadata out from under it.
exec 200<>"$CONCURRENCY_LOCK_FILE"

if ! flock -n 200; then
  # Another process holds the lock. Read the metadata it wrote right after
  # acquiring (best-effort — a brand-new holder may not have written yet) and
  # report everything available about that PID for a real diagnosis.
  HOLDER_PID="$(awk -F= '/^PID=/{print $2}' "$CONCURRENCY_LOCK_FILE" 2>/dev/null)"

  log_error "Another backup is already running (lock held: $CONCURRENCY_LOCK_FILE)"
  if [[ -n "$HOLDER_PID" && -d "/proc/$HOLDER_PID" ]]; then
    PROC_USER="$(ps -o user= -p "$HOLDER_PID" 2>/dev/null | xargs)"
    PROC_START="$(ps -o lstart= -p "$HOLDER_PID" 2>/dev/null | xargs)"
    PROC_ETIME="$(ps -o etime= -p "$HOLDER_PID" 2>/dev/null | xargs)"
    PROC_PPID="$(ps -o ppid= -p "$HOLDER_PID" 2>/dev/null | xargs)"
    PROC_CMD="$(ps -o cmd= -p "$HOLDER_PID" 2>/dev/null)"
    log_error "  Holder PID   : $HOLDER_PID  (PPID: $PROC_PPID)"
    log_error "  User         : $PROC_USER"
    log_error "  Started at   : $PROC_START"
    log_error "  Elapsed time : $PROC_ETIME"
    log_error "  Command      : $PROC_CMD"
    log_error "  Lock metadata: $(tr '\n' ' ' < "$CONCURRENCY_LOCK_FILE" 2>/dev/null)"
  else
    log_error "  Holder PID   : ${HOLDER_PID:-unknown} — process details unavailable (it may be finishing right now; the lock itself is still held)"
  fi

  fail_backup 1 "Another backup is already running (holder PID: ${HOLDER_PID:-unknown})"
fi

# Lock acquired — overwrite the file with our own identity so, if a future
# run finds this one still going, it can report exactly who holds it.
: > "$CONCURRENCY_LOCK_FILE"
{
  echo "PID=$$"
  echo "RESULT_ID=$RESULT_ID"
  echo "SERVER_NAME=$SERVER_NAME"
  echo "STARTED_AT=$(date '+%F %T')"
} >> "$CONCURRENCY_LOCK_FILE"

log_msg "No concurrent backups detected (lock acquired: $CONCURRENCY_LOCK_FILE)"

# Check 11: Verify MySQL has binary logging enabled
log_msg "Check 11/14: Verifying binary logging is enabled..."
BINLOG_STATUS=$("$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" \
  "${MYSQL_CONNECT_OPTS[@]}" \
  -NBe "SELECT @@log_bin" 2>/dev/null || echo "0")
if [[ "$BINLOG_STATUS" != "1" ]]; then
  log_warn "Binary logging is not enabled. Point-in-time recovery will not be possible."
else
  log_msg "Binary logging is enabled"
fi

# Check 12: Verify target directory is empty
log_msg "Check 12/14: Verifying target directory is empty..."
if [[ -n "$(ls -A "$TARGET_DIR" 2>/dev/null)" ]]; then
  log_error "Target directory is not empty: $TARGET_DIR"
  fail_backup 1
fi
log_msg "Target directory is empty"

# Check 13: Test tar and gzip functionality
log_msg "Check 13/14: Testing compression utilities..."
TEST_FILE="$TARGET_DIR/.test_$$"
echo "test" > "$TEST_FILE"
if ! tar -czf "$TARGET_DIR/.test.tar.gz" -C "$TARGET_DIR" "$(basename "$TEST_FILE")" 2>/dev/null; then
  log_error "tar/gzip test failed"
  fail_backup 1
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
  fail_backup 1
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
  echo "Result ID      : $RESULT_ID"
  echo "Server name    : $SERVER_NAME"
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
  echo "Archive dir    : $ARCHIVE_DIR"
  echo "===================================================="
  echo ""
} | tee -a "$RUN_LOG"

############################
# CREATE LOCK FILE
# Created after pre-flight checks pass.
# Tells binlog_collect to skip while backup is running.
# ALWAYS removed — via fail_backup on failure, explicitly on success.
############################

log_msg "Creating lock file: $LOCK_FILE"
echo "$$" > "$LOCK_FILE"
log_msg "Lock file created (PID: $$)"

############################
# STEP 1: CREATE BACKUP
############################

set_stage 1 "Creating backup (xtrabackup)"
log_msg "[Step 1/7] Creating backup with xtrabackup..."

set +e
"$XTRABACKUP_BIN" \
  --backup \
  --user="$MYSQL_USER" \
  --password="$MYSQL_PASSWORD" \
  --host="$MYSQL_HOST" \
  --port="$MYSQL_PORT" \
  --datadir="$MYSQL_DATADIR" \
  --parallel="$PARALLEL_THREADS" \
  --target-dir="$TARGET_DIR" \
  2>&1 | tee -a "$XTRABACKUP_LOG"

BACKUP_STATUS=${PIPESTATUS[0]}
set -e

if [[ $BACKUP_STATUS -ne 0 ]]; then
  log_error "xtrabackup --backup failed (exit code: $BACKUP_STATUS)"
  cat "$XTRABACKUP_LOG" >> "$ERROR_LOG"
  fail_backup "$BACKUP_STATUS"
fi

# Verify backup files were created
if [[ ! -f "$TARGET_DIR/xtrabackup_checkpoints" ]]; then
  log_error "xtrabackup_checkpoints file not found in backup"
  fail_backup 1
fi

log_msg "Backup created successfully"

############################
# STEP 2: VALIDATE BACKUP INTEGRITY
############################

set_stage 2 "Validating backup integrity"
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

set_stage 3 "Preparing backup (applying redo log)"
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
  fail_backup "$PREPARE_STATUS"
fi

# Verify prepare was successful
if ! grep -q "completed OK!" "$XTRABACKUP_LOG"; then
  log_error "xtrabackup prepare did not complete successfully"
  fail_backup 1
fi

log_msg "Backup prepared successfully"

############################
# STEP 4: COPY BINLOG INFO
############################

set_stage 4 "Extracting binlog info"
log_msg "[Step 4/7] Extracting binlog information..."

# Check for binlog info file
if [[ -f "${TARGET_DIR}/xtrabackup_binlog_info" ]]; then
  cp "${TARGET_DIR}/xtrabackup_binlog_info" "$BINLOG_INFO_FILE"

  # Validate binlog info content
  if [[ ! -s "$BINLOG_INFO_FILE" ]]; then
    log_error "Binlog info file is empty"
    fail_backup 1
  fi

  BINLOG_NAME=$(awk '{print $1}' "$BINLOG_INFO_FILE")
  BINLOG_POS=$(awk '{print $2}' "$BINLOG_INFO_FILE")

  if [[ -z "$BINLOG_NAME" || -z "$BINLOG_POS" ]]; then
    log_error "Invalid binlog info format"
    fail_backup 1
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

# Normalize binlog position to a plain integer for the BIGINT column
if [[ ! "$BINLOG_POS" =~ ^[0-9]+$ ]]; then
  BINLOG_POS="0"
fi

############################
# STEP 5: COMPRESS BACKUP
############################

set_stage 5 "Compressing backup"
log_msg "[Step 5/7] Compressing backup..."

# Record uncompressed size
UNCOMPRESSED_SIZE=$(du -sh "$TARGET_DIR" | awk '{print $1}')
log_msg "Uncompressed size: $UNCOMPRESSED_SIZE"

# Compress with progress monitoring
if ! tar -czf "$COMPRESSED_FILE" -C "$BACKUP_BASE" "$(basename "$TARGET_DIR")" 2>>"$ERROR_LOG"; then
  log_error "Compression failed"
  fail_backup 1
fi

# Verify compressed file was created and has size
if [[ ! -f "$COMPRESSED_FILE" ]]; then
  log_error "Compressed file was not created"
  fail_backup 1
fi

COMPRESSED_SIZE=$(stat -c%s "$COMPRESSED_FILE" 2>/dev/null || echo "0")
if [[ "$COMPRESSED_SIZE" -eq 0 ]]; then
  log_error "Compressed file is empty"
  fail_backup 1
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

set_stage 6 "Generating & verifying SHA-256 checksum"
log_msg "[Step 6/7] Generating and verifying SHA-256 checksum..."

# Generate SHA-256 checksum for the compressed backup
if ! sha256sum "$COMPRESSED_FILE" > "$CHECKSUM_FILE" 2>>"$ERROR_LOG"; then
  log_error "Failed to generate SHA-256 checksum"
  fail_backup 1
fi

# Verify checksum file was created and is not empty
if [[ ! -s "$CHECKSUM_FILE" ]]; then
  log_error "SHA-256 checksum file is empty or was not created"
  fail_backup 1
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
  fail_backup 1
fi
cd "$CURRENT_DIR"
log_msg "SHA-256 checksum verified successfully - archive integrity confirmed"

############################
# STEP 7: MOVE TO ARCHIVE
############################

set_stage 7 "Moving backup to archive"
log_msg "[Step 7/7] Moving backup to archive directory..."

# Move compressed file
if ! mv "$COMPRESSED_FILE" "$ARCHIVE_DIR/" 2>>"$ERROR_LOG"; then
  log_error "Failed to move compressed file to $ARCHIVE_DIR"
  fail_backup 1
fi

# Move checksum file
if ! mv "$CHECKSUM_FILE" "$ARCHIVE_DIR/" 2>>"$ERROR_LOG"; then
  log_error "Failed to move checksum file to $ARCHIVE_DIR"
  fail_backup 1
fi

# Move binlog info
if ! mv "$BINLOG_INFO_FILE" "$ARCHIVE_DIR/" 2>>"$ERROR_LOG"; then
  log_error "Failed to move binlog info to $ARCHIVE_DIR"
  fail_backup 1
fi

# Update paths after move
COMPRESSED_FILE="$ARCHIVE_DIR/$(basename "$COMPRESSED_FILE")"
CHECKSUM_FILE="$ARCHIVE_DIR/$(basename "$CHECKSUM_FILE")"
BINLOG_INFO_FILE="$ARCHIVE_DIR/$(basename "$BINLOG_INFO_FILE")"

# Verify files in archive
if [[ ! -f "$COMPRESSED_FILE" || ! -f "$CHECKSUM_FILE" || ! -f "$BINLOG_INFO_FILE" ]]; then
  log_error "Files not found in archive after move"
  fail_backup 1
fi

# Re-verify SHA-256 checksum after move (update path inside checksum file)
log_msg "Updating checksum file with new path..."
BACKUP_SHA256=$(awk '{print $1}' "$CHECKSUM_FILE")
echo "$BACKUP_SHA256  $COMPRESSED_FILE" > "$CHECKSUM_FILE"

log_msg "Verifying checksum after move..."
if ! sha256sum -c "$CHECKSUM_FILE" >/dev/null 2>>"$ERROR_LOG"; then
  log_error "SHA-256 checksum verification failed after move to archive"
  fail_backup 1
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
  fail_backup 1
fi

if [[ ! -r "$CHECKSUM_FILE" ]]; then
  log_error "Final checksum file is not readable"
  fail_backup 1
fi

if [[ ! -r "$BINLOG_INFO_FILE" ]]; then
  log_error "Final binlog info file is not readable"
  fail_backup 1
fi

# Final SHA-256 integrity check
log_msg "Final SHA-256 integrity verification..."
if ! sha256sum -c "$CHECKSUM_FILE" >/dev/null 2>>"$ERROR_LOG"; then
  log_error "Final SHA-256 checksum verification failed"
  fail_backup 1
fi
log_msg "Final SHA-256 integrity check passed"

log_msg "Final validation passed"

############################
# STEP 8: POST-BACKUP BINLOG COLLECTION
# Best-effort: collects binlogs generated during the backup window so PITR
# coverage starts immediately. A failure here NEVER fails the backup — its
# archive is already validated. Ongoing collection is done by the scheduled
# binlog_collect job every ~15 minutes.
############################

set_stage 8 "Collecting binlogs"
if [[ "$BINLOG_NAME" == "unknown" ]] || ! is_binlog_file "$BINLOG_NAME"; then
  log_warn "Binary logging disabled/unknown at backup time; skipping binlog collection."
  close_stage "SUCCESS"
elif collect_binlogs; then
  close_stage "SUCCESS"
else
  log_warn "Binlog collection reported a problem (backup archive is unaffected)."
  close_stage "FAILED" "binlog collection error"
fi

############################
# RECORD SUCCESS STATUS
############################

if [[ "$STATUS_ROW_CREATED" == "1" ]]; then
  heartbeat_stop   # run is done — stop the ticker before flipping to SUCCESS
  record "UPDATE ${STATUS_DB}.BLS02
            SET S02F07='SUCCESS',
                S02F04='Completed',
                S02F17=${TOTAL_STAGES},
                S02C07=NOW(),
                S02F09='$(sql_escape "$COMPRESSED_FILE")',
                S02F10=${COMPRESSED_SIZE},
                S02F11=${UNCOMPRESSED_BYTES},
                S02F12='$(sql_escape "$BACKUP_SHA256")',
                S02F13='$(sql_escape "$BINLOG_NAME")',
                S02F14=${BINLOG_POS},
                S02F15=0
          WHERE S02F02=${RESULT_ID} AND S02F07='RUNNING';"
  log_msg "BLS02 SUCCESS row recorded for RESULT_ID=${RESULT_ID}"
fi

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
  echo "Result ID        : $RESULT_ID"
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
# On failure it is removed inside fail_backup above.
############################

log_msg "Removing lock file: $LOCK_FILE"
rm -f "$LOCK_FILE" 2>/dev/null || true
log_msg "Lock file removed"

trap - ERR INT TERM

exit 0