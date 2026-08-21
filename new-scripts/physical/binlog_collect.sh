#!/usr/bin/env bash
#
# binlog_collect.sh
#
# Collects MySQL binary logs generated *since* the most recent physical backup
# for a given backup job (CONFIG_ID), copying them to the shared archive so the
# backup has point-in-time-recovery coverage. Designed to run every ~15 minutes
# as a scheduled DB BRD job; each run resumes from where the last one left off
# (state file) until the next day's backup creates a newer anchor.
#
# Parameterization (per DB BRD Script Authoring Guide):
#   - Positional args ($1, $2, $5, $7, $8)  -> runtime data
#   - {{CMC27:key-name}} tokens             -> secrets, resolved by the API
#                                              before SSH delivery.
#
# Positional args (this script uses $1, $2, $5, $7, $8):
#   $1 RESULT_ID    - this collection run's CentralResultId (stored in BLS04).
#   $2 SERVER_NAME  - source server identifier (logs + BLS04.S04F04).
#   $5 BASE_DIR     - STORAGE_ROOT; shared storage mount root.
#   $7 STATUS_DB    - database holding BLS04.
#   $8 CONFIG_ID    - this collection job's ConfigId; recorded in BLS04 for
#                     dashboard grouping. (The backup being collected against is
#                     found via the newest *_binlog_info in ARCHIVE_DIR, which is
#                     already scoped to one backup job by ARCHIVE_FOLDER — the
#                     backup's own job id is embedded in the anchor name.)
#                     (Was $9 before the 2026-07-21 TIMEOUT_MIN-arg removal.)
#
# Status (one row per collection run in BLS04, RUNNING -> SUCCESS/FAILED):
#   current binlog being copied, per-run copied/skipped/error counts, and the
#   cumulative TotalBinlogsInArchive ("how much collected so far" for this job).
# A background heartbeat bumps BLS04.S04C04 so the dashboard can tell working
# from stuck.
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
CONFIG_ID="${8:-}"         # was $9 before the 2026-07-21 TIMEOUT_MIN-arg removal

# --- DB credentials — injected from CMC27 before SSH delivery ---
MYSQL_HOST="{{CMC27:db-host}}"
MYSQL_PORT="{{CMC27:db-port}}"
MYSQL_USER="{{CMC27:db-user}}"
MYSQL_PASSWORD="{{CMC27:db-password}}"

# --- Archive destination folder — appended to BASE_DIR ($5).
#     MUST match the backup script so the *_binlog_info anchors are found. ---
ARCHIVE_FOLDER="YK/test_cloud_db"

# --- Server-local settings (edit here, not passed via CLI) ---
# MySQL binlog location: directory + basename (files are <BINLOG_BASE>.NNNNNN).
BINLOG_BASE="/Data/mysql1/binlog"
# MySQL client binary.
MYSQL_BIN="/usr/bin/mysql"
# How far back to trust an anchor if MySQL purged logs, etc. (informational).
MAX_LOOKBACK_DAYS=3
# If the backup lock is younger than this, a backup is in progress -> skip run.
LOCK_STALE_SECONDS=21600   # 6h
# How often (seconds) the heartbeat ticker bumps S04C04 during a run.
HEARTBEAT_INTERVAL=30

# --- Validate required positional arguments ---
missing=()
[[ -n "${RESULT_ID:-}" ]] || missing+=("RESULT_ID (\$1)")
[[ -n "${BASE_DIR:-}" ]]  || missing+=("BASE_DIR (\$5)")
[[ -n "${STATUS_DB:-}" ]] || missing+=("STATUS_DB (\$7)")
if [[ "${#missing[@]}" -gt 0 ]]; then
  echo "ERROR: missing required argument(s): ${missing[*]}" >&2
  echo "Usage: $0 expects \$1=RESULT_ID \$5=BASE_DIR \$7=STATUS_DB (\$2 server, \$8 config)" >&2
  exit 1
fi

# --- Derived paths ---
ARCHIVE_DIR="${BASE_DIR}/${ARCHIVE_FOLDER}"
BINLOG_ARCHIVE_BASE="${ARCHIVE_DIR}/binlog"
BINLOG_DIR="$(dirname "$BINLOG_BASE")"
BINLOG_PREFIX="$(basename "$BINLOG_BASE")"

############################
# EARLY INITIALIZATION
############################

TARGET_BINLOG_DIR=""
STATE_FILE=""
STATE_FILE_PRE_EXISTED=false
RUN_LOG=""
ERROR_LOG=""
ANCHOR_FILE=""
ANCHOR_BASE=""
REFERENCE_DATE=""
START_BINLOG=""
CURRENT_BINLOG=""
CURRENT_COPYING_FILE=""      # file mid-copy, for cleanup
FOUND_START=false
COPIED_COUNT=0
SKIPPED_COUNT=0
ERROR_COUNT=0
TOTAL_IN_ARCHIVE=0
LAST_ERROR=""
STATUS_ROW_CREATED=0
HEARTBEAT_PID=""

TODAY="$(date +%Y%m%d)"
START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
START_EPOCH="$(date +%s)"

# Backup lock (written by the backup script into ARCHIVE_DIR while it runs).
LOCK_FILE="${ARCHIVE_DIR}/${TODAY}_lock"

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
# STATUS HELPERS (BLS04)
############################

# Fire-and-forget status write — always guarded so a status-DB hiccup can never
# abort collection.
record() {
  "$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" \
    -e "$1" 2>/dev/null || true
}

# Escape single quotes for SQL by doubling them (''). A quote variable is used
# deliberately: writing \'\' inside double quotes leaves the backslashes literal.
sql_escape() { local q="'"; printf '%s' "${1//$q/$q$q}"; }

# Create the binlog-collection status table if absent. Captures output so a real
# error is logged instead of silently swallowed. No positional args ($1..$9) may
# appear in the heredoc body — it is unquoted (for ${STATUS_DB}) and set -u would
# abort on an unbound arg.
ensure_status_table() {
  local out rc
  out="$("$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" 2>&1 <<SQL
CREATE TABLE IF NOT EXISTS ${STATUS_DB}.BLS04 (
    S04F01 INT NOT NULL AUTO_INCREMENT
        COMMENT 'CollectId PK',
    S04F02 BIGINT NULL
        COMMENT 'CentralResultId (this collection run)',
    S04F03 INT NULL
        COMMENT 'ConfigId (the backup job definition)',
    S04F04 VARCHAR(255) NULL
        COMMENT 'ServerName',
    S04F05 VARCHAR(64) NULL
        COMMENT 'ReferenceAnchor (job<cfg>_<date>, ties runs to a backup)',
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
  if [[ $rc -ne 0 ]]; then
    log_warn "Status table setup failed (rc=$rc): ${out//$'\n'/ | }"
  fi
  return $rc
}

# Push live progress (current binlog + counts + cumulative total) to BLS04.
# Bumps the heartbeat as a side effect. Best-effort.
bls04_progress() {
  [[ "$STATUS_ROW_CREATED" == "1" ]] || return 0
  record "UPDATE ${STATUS_DB}.BLS04
            SET S04F09='$(sql_escape "$START_BINLOG")',
                S04F10='$(sql_escape "$CURRENT_COPYING_FILE")',
                S04F11=${COPIED_COUNT}, S04F12=${SKIPPED_COUNT}, S04F13=${ERROR_COUNT},
                S04F14=${TOTAL_IN_ARCHIVE}
          WHERE S04F02=${RESULT_ID} AND S04F07='RUNNING';"
}

############################
# HEARTBEAT
############################

heartbeat_start() {
  [[ "$STATUS_ROW_CREATED" == "1" ]] || return 0
  heartbeat_stop
  (
    while true; do
      sleep "$HEARTBEAT_INTERVAL"
      "$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" \
        -e "UPDATE ${STATUS_DB}.BLS04 SET S04C04=NOW() WHERE S04F02=${RESULT_ID} AND S04F07='RUNNING';" \
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
# FAILURE HANDLING
############################

# Central failure path. Records FAILED in BLS04, stops the heartbeat, removes a
# partially copied file, and exits 1. Every handled failure routes here (a plain
# `exit 1` would not fire the ERR trap).
fail_collect() {
  local ec="${1:-1}"
  local reason="${2:-${LAST_ERROR:-Binlog collection failed; see logs}}"

  trap - ERR INT TERM
  heartbeat_stop

  log_error "Binlog collection failed (exit code: $ec). Cleaning up..."

  if [[ "$STATUS_ROW_CREATED" == "1" && -n "${RESULT_ID:-}" ]]; then
    record "UPDATE ${STATUS_DB}.BLS04
              SET S04F07='FAILED', S04C07=NOW(), S04F16=${ec},
                  S04F17='$(sql_escape "$reason")',
                  S04F11=${COPIED_COUNT}, S04F12=${SKIPPED_COUNT}, S04F13=${ERROR_COUNT},
                  S04F14=${TOTAL_IN_ARCHIVE}
            WHERE S04F02=${RESULT_ID} AND S04F07='RUNNING';"
  fi

  # Remove a file that was mid-copy when we failed.
  if [[ -n "${CURRENT_COPYING_FILE:-}" && -n "${TARGET_BINLOG_DIR:-}" \
        && -f "$TARGET_BINLOG_DIR/$CURRENT_COPYING_FILE" ]]; then
    log_msg "Removing partially copied file: $CURRENT_COPYING_FILE"
    rm -f "$TARGET_BINLOG_DIR/$CURRENT_COPYING_FILE" 2>/dev/null || true
  fi

  log_error "Binlog collection aborted. Check logs: ${RUN_LOG:-'(not initialized)'}"
  exit 1
}

on_trap() { local ec=$?; fail_collect "$ec"; }
trap on_trap ERR INT TERM
trap heartbeat_stop EXIT

############################
# GENERIC HELPERS
############################

mysql_cmd() { "$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" "$@"; }

test_mysql_connection() { mysql_cmd -e "SELECT 1" >/dev/null 2>&1; }

is_mysql_running() {
  systemctl is-active --quiet mysql 2>/dev/null && return 0
  systemctl is-active --quiet mysqld 2>/dev/null && return 0
  pgrep -x mysqld >/dev/null 2>&1 && return 0
  return 1
}

# Current active binlog (works across MySQL versions).
get_current_binlog() {
  local result
  result=$(mysql_cmd -NBe "SHOW BINARY LOG STATUS" 2>/dev/null | awk '{print $1}') || true
  if [[ -z "$result" ]]; then
    result=$(mysql_cmd -NBe "SHOW MASTER STATUS" 2>/dev/null | awk '{print $1}') || true
  fi
  echo "$result"
}

# A real binlog file ends in .NNNNNN (6 digits).
is_binlog_file() { [[ "$1" =~ \.[0-9]{6}$ ]]; }

validate_writable() {
  local dir="$1" test_file="$1/.write_test_$$"
  touch "$test_file" 2>/dev/null || return 1
  rm -f "$test_file"
  return 0
}

# Count binlog files already in the archive target (cumulative for this ref).
count_archived() {
  find "$TARGET_BINLOG_DIR" -maxdepth 1 -type f -name "${BINLOG_PREFIX}.*" 2>/dev/null | wc -l
}

############################
# LOCK CHECK — skip while a backup is running
############################

if [[ -f "$LOCK_FILE" ]]; then
  LOCK_AGE=$(( $(date +%s) - $(stat -c%Y "$LOCK_FILE") ))
  if [[ $LOCK_AGE -lt $LOCK_STALE_SECONDS ]]; then
    log_msg "Backup lock present (age ${LOCK_AGE}s) — backup in progress. Skipping this run."
    exit 0
  fi
  log_warn "Backup lock is STALE (age ${LOCK_AGE}s > ${LOCK_STALE_SECONDS}s); backup may have crashed. Proceeding."
fi

############################
# LOCATE THE BACKUP ANCHOR
# ARCHIVE_FOLDER is scoped to a single backup job's output, so the newest
# *_binlog_info in ARCHIVE_DIR is this job's most recent backup. Its filename
# (job<cfg>_<date>) is recorded as the reference so runs group under it.
############################

if [[ -d "$ARCHIVE_DIR" ]]; then
  ANCHOR_FILE=$(find "$ARCHIVE_DIR" -maxdepth 1 -type f -name "*_binlog_info" \
                  -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
fi

if [[ -z "$ANCHOR_FILE" ]]; then
  log_msg "No backup anchor (*_binlog_info) found yet in $ARCHIVE_DIR. Nothing to collect. Exiting cleanly."
  exit 0
fi

ANCHOR_BASE="$(basename "$ANCHOR_FILE" _binlog_info)"          # job5_20260711
REFERENCE_DATE="$(echo "$ANCHOR_BASE" | grep -oE '[0-9]{8}' | head -1)"
TARGET_BINLOG_DIR="${BINLOG_ARCHIVE_BASE}/${ANCHOR_BASE}"
STATE_FILE="${TARGET_BINLOG_DIR}/last_copied_binlog"
RUN_LOG="${TARGET_BINLOG_DIR}/binlog_collect.log"
ERROR_LOG="${TARGET_BINLOG_DIR}/binlog_collect_errors.log"

[[ -f "$STATE_FILE" ]] && STATE_FILE_PRE_EXISTED=true

############################
# SETUP + STATUS ROW (created before pre-flight so failures are recorded)
############################

if ! mkdir -p "$TARGET_BINLOG_DIR" 2>/dev/null; then
  log_error "Failed to create target directory: $TARGET_BINLOG_DIR"
  fail_collect 1
fi

TOTAL_IN_ARCHIVE=$(count_archived)

CONFIG_ID_SQL="NULL"
if [[ "$CONFIG_ID" =~ ^[0-9]+$ ]]; then CONFIG_ID_SQL="$CONFIG_ID"; fi

log_msg "Ensuring status table (BLS04) exists..."
if ensure_status_table; then
  record "INSERT INTO ${STATUS_DB}.BLS04
            (S04F02, S04F03, S04F04, S04F05, S04F06, S04F07, S04F08, S04F14, S04C06)
          VALUES
            (${RESULT_ID}, ${CONFIG_ID_SQL}, '$(sql_escape "$SERVER_NAME")',
             '$(sql_escape "$ANCHOR_BASE")', '$(sql_escape "$REFERENCE_DATE")',
             'RUNNING', $$, ${TOTAL_IN_ARCHIVE}, NOW());"
  STATUS_ROW_CREATED=1
  heartbeat_start
  log_msg "BLS04 RUNNING row created for RESULT_ID=${RESULT_ID} (anchor ${ANCHOR_BASE})."
else
  log_warn "Could not create BLS04 status table; continuing without DB status."
fi

# Initialize error log
cat >> "$ERROR_LOG" <<EOF
========================================
BINLOG COLLECTION ERROR LOG  ($(date '+%F %T'))
========================================
EOF

############################
# PRE-FLIGHT CHECKS
############################

log_msg "===================================================="
log_msg "Binlog collection pre-flight (anchor: $ANCHOR_BASE)"
log_msg "===================================================="

for cmd in awk cp du df find basename dirname grep wc stat sync sort; do
  command -v "$cmd" >/dev/null 2>&1 || { log_error "Required command not found: $cmd"; fail_collect 1; }
done
[[ -x "$MYSQL_BIN" ]] || { log_error "MySQL binary not executable: $MYSQL_BIN"; fail_collect 1; }

is_mysql_running || { log_error "MySQL is not running"; fail_collect 1; }
test_mysql_connection || { log_error "Cannot connect to MySQL with provided credentials (user: $MYSQL_USER)"; fail_collect 1; }

[[ -d "$BINLOG_DIR" ]] || { log_error "Binlog directory not found: $BINLOG_DIR"; fail_collect 1; }
validate_writable "$TARGET_BINLOG_DIR" || { log_error "Target directory not writable: $TARGET_BINLOG_DIR"; fail_collect 1; }
[[ -s "$ANCHOR_FILE" ]] || { log_error "Backup anchor is empty/unreadable: $ANCHOR_FILE"; fail_collect 1; }

BINLOG_STATUS=$(mysql_cmd -NBe "SELECT @@log_bin" 2>/dev/null || echo "0")
[[ "$BINLOG_STATUS" == "1" ]] || { log_error "Binary logging is not enabled on MySQL server"; fail_collect 1; }

log_msg "Pre-flight checks passed."

############################
# DETERMINE START BINLOG
############################

if [[ -f "$STATE_FILE" ]]; then
  START_BINLOG="$(cat "$STATE_FILE")"
  if [[ -z "$START_BINLOG" ]]; then
    START_BINLOG="$(awk '{print $1}' "$ANCHOR_FILE")"
    log_warn "State file empty; starting from backup anchor position: $START_BINLOG"
  else
    log_msg "Resuming after last copied binlog: $START_BINLOG"
  fi
else
  START_BINLOG="$(awk '{print $1}' "$ANCHOR_FILE")"
  log_msg "No state file; starting from backup anchor position: $START_BINLOG"
fi

is_binlog_file "$START_BINLOG" || { log_error "Invalid start binlog format: $START_BINLOG"; fail_collect 1; }

# Purged-binlog fallback: if the start binlog is gone from disk, fall back to the
# earliest available so we collect *something* (a gap is logged).
if [[ ! -f "$BINLOG_DIR/$START_BINLOG" ]]; then
  log_warn "Start binlog $START_BINLOG not on disk (purged by MySQL?)."
  EARLIEST_BINLOG=$(find "$BINLOG_DIR" -name "${BINLOG_PREFIX}.*" -type f 2>/dev/null | sort | head -1 | xargs -r basename 2>/dev/null || echo "")
  [[ -n "$EARLIEST_BINLOG" ]] || { log_error "No binlog files on disk at all."; fail_collect 1; }
  log_warn "Falling back to earliest available: $EARLIEST_BINLOG (coverage gap $START_BINLOG..$EARLIEST_BINLOG)"
  START_BINLOG="$EARLIEST_BINLOG"
fi

############################
# FLUSH + CURRENT BINLOG (the active one is skipped — still being written)
############################

log_msg "Flushing binary logs..."
mysql_cmd -e "FLUSH BINARY LOGS;" 2>>"$ERROR_LOG" || { log_error "Failed to flush binary logs"; fail_collect 1; }
sync; sleep 2

CURRENT_BINLOG="$(get_current_binlog)"
{ [[ -n "$CURRENT_BINLOG" ]] && is_binlog_file "$CURRENT_BINLOG"; } || { log_error "Unable to determine current binlog"; fail_collect 1; }
log_msg "Current active binlog (skipped): $CURRENT_BINLOG"

############################
# COLLECT
############################

log_msg "Collecting from $START_BINLOG (anchor $ANCHOR_BASE)..."

shopt -s nullglob
mapfile -t BINLOG_FILES < <(for f in "$BINLOG_DIR/${BINLOG_PREFIX}."*; do basename "$f"; done | sort)
shopt -u nullglob
[[ ${#BINLOG_FILES[@]} -gt 0 ]] || { log_error "No binlog files found to process"; fail_collect 1; }

for BINLOG_FILE in "${BINLOG_FILES[@]}"; do
  is_binlog_file "$BINLOG_FILE" || continue

  [[ "$BINLOG_FILE" == "$START_BINLOG" ]] && FOUND_START=true

  if [[ "$FOUND_START" != true ]]; then
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1)); continue
  fi
  if [[ "$BINLOG_FILE" == "$CURRENT_BINLOG" ]]; then
    log_msg "Skipping active binlog: $BINLOG_FILE"; continue
  fi
  if [[ -f "$TARGET_BINLOG_DIR/$BINLOG_FILE" ]]; then
    continue   # already collected in a previous run
  fi

  local_src="$BINLOG_DIR/$BINLOG_FILE"
  if [[ ! -r "$local_src" ]]; then
    log_warn "Source not readable/missing: $BINLOG_FILE"; ERROR_COUNT=$((ERROR_COUNT + 1)); continue
  fi
  SOURCE_SIZE=$(stat -c%s "$local_src" 2>/dev/null || echo "0")
  [[ "$SOURCE_SIZE" -gt 0 ]] || { log_warn "Empty source, skipping: $BINLOG_FILE"; continue; }

  CURRENT_COPYING_FILE="$BINLOG_FILE"
  bls04_progress   # live: show the file we're about to copy

  if ! cp -p "$local_src" "$TARGET_BINLOG_DIR/" 2>>"$ERROR_LOG"; then
    log_error "Failed to copy $BINLOG_FILE"
    rm -f "$TARGET_BINLOG_DIR/$BINLOG_FILE" 2>/dev/null || true
    CURRENT_COPYING_FILE=""; ERROR_COUNT=$((ERROR_COUNT + 1)); continue
  fi

  DEST_SIZE=$(stat -c%s "$TARGET_BINLOG_DIR/$BINLOG_FILE" 2>/dev/null || echo "0")
  if [[ "$SOURCE_SIZE" -ne "$DEST_SIZE" ]]; then
    log_error "Size mismatch for $BINLOG_FILE (src $SOURCE_SIZE, dst $DEST_SIZE)"
    rm -f "$TARGET_BINLOG_DIR/$BINLOG_FILE" 2>/dev/null || true
    CURRENT_COPYING_FILE=""; ERROR_COUNT=$((ERROR_COUNT + 1)); continue
  fi

  CURRENT_COPYING_FILE=""
  echo "$BINLOG_FILE" > "$STATE_FILE"
  COPIED_COUNT=$((COPIED_COUNT + 1))
  TOTAL_IN_ARCHIVE=$((TOTAL_IN_ARCHIVE + 1))
  log_msg "Copied: $BINLOG_FILE"
  bls04_progress   # live: refresh counts after each copy
done

if [[ "$FOUND_START" != true ]]; then
  log_error "Start binlog not found in file list: $START_BINLOG"
  fail_collect 1
fi

############################
# SUCCESS
############################

TOTAL_IN_ARCHIVE=$(count_archived)
TOTAL_SIZE_BYTES=$(du -sb "$TARGET_BINLOG_DIR" 2>/dev/null | awk '{print $1}'); TOTAL_SIZE_BYTES="${TOTAL_SIZE_BYTES:-0}"
TOTAL_SIZE_HUMAN=$(du -sh "$TARGET_BINLOG_DIR" 2>/dev/null | awk '{print $1}')
# Newest binlog now in the archive = the coverage endpoint (shown as LatestBinlog).
LATEST_BINLOG=$(find "$TARGET_BINLOG_DIR" -maxdepth 1 -type f -name "${BINLOG_PREFIX}.*" 2>/dev/null | sort | tail -1 | xargs -r basename 2>/dev/null || echo "")
END_EPOCH="$(date +%s)"; DURATION=$((END_EPOCH - START_EPOCH))

if [[ "$STATUS_ROW_CREATED" == "1" ]]; then
  heartbeat_stop
  record "UPDATE ${STATUS_DB}.BLS04
            SET S04F07='SUCCESS', S04C07=NOW(), S04F16=0,
                S04F09='$(sql_escape "$START_BINLOG")',
                S04F10='$(sql_escape "$LATEST_BINLOG")',
                S04F11=${COPIED_COUNT}, S04F12=${SKIPPED_COUNT}, S04F13=${ERROR_COUNT},
                S04F14=${TOTAL_IN_ARCHIVE}, S04F15=${TOTAL_SIZE_BYTES}
          WHERE S04F02=${RESULT_ID} AND S04F07='RUNNING';"
fi

{
  echo ""
  echo "===================================================="
  echo "BINLOG COLLECTION COMPLETED"
  echo "===================================================="
  echo "Result ID          : $RESULT_ID"
  echo "Config ID          : $CONFIG_ID"
  echo "Reference anchor    : $ANCHOR_BASE"
  echo "Duration           : ${DURATION}s"
  echo "Start binlog       : $START_BINLOG"
  echo "Current (skipped)  : $CURRENT_BINLOG"
  echo "Copied this run    : $COPIED_COUNT"
  echo "Skipped this run   : $SKIPPED_COUNT"
  echo "Errors this run    : $ERROR_COUNT"
  echo "Total in archive   : $TOTAL_IN_ARCHIVE ($TOTAL_SIZE_HUMAN)"
  echo "Target directory   : $TARGET_BINLOG_DIR"
  echo "===================================================="
} | tee -a "$RUN_LOG"

log_msg "BLS04 SUCCESS recorded for RESULT_ID=${RESULT_ID} (total collected: ${TOTAL_IN_ARCHIVE})."

trap - ERR INT TERM
exit 0
