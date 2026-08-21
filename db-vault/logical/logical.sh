#!/usr/bin/env bash
#
# db-vault/logical/logical.sh — portal (DB Vault) version of server/logical/logical.sh
#
# Per-database logical backup (mysqldump), launched by the DB Vault API over SSH.
#
# The WORK MODEL is unchanged from server/logical/logical.sh: one mysqldump per
# database inside its own --single-transaction, archived, read back, checksummed,
# and a run manifest written on both the success and failure paths.
#
# What differs from the standalone version:
#   - the run's identity and destination root arrive as positional args
#     ($1, $5, $7, $8) instead of being edited into REGION 1
#   - credentials come from {{CMC27:…}} tokens the API resolves before delivery
#   - every database gets a BLS01 status row (RUNNING -> SUCCESS/FAILED) so the
#     dashboard's live view can show per-database progress
#   - a background heartbeat bumps BLS01.S01C04 on this run's RUNNING rows, so
#     "working" is distinguishable from "stuck" (incl. an untrappable SIGKILL)
#   - an EXIT sweep closes any row left RUNNING, so an aborted run cannot leave
#     rows pending forever
#   - the destination is BASE_DIR/BACKUP_FOLDER, so one STORAGE_ROOT can be
#     shared by several jobs
#   - tar gets a stability wait and a retry, because the destination here is a
#     network mount whose background commit can still be touching the .sql when
#     tar starts reading ("file changed as we read it")
#
# Unlike the physical chain, logical backup is per-database: there is no single
# run-summary row. BLS01 holds one row per database, which is exactly what the
# portal's live view renders (a central BJR01 parent row plus these child rows).
#
# Parameterization (per DB Vault Script Authoring Guide, instructions/README.md §9):
#   - Positional args ($1, $5, $7, $8)  -> runtime data
#   - {{CMC27:key-name}} tokens         -> secrets, resolved by the API before
#                                          SSH delivery. Never visible in `ps aux`.
#   - everything else                   -> script variables in REGION 1
#
# Usage (delivered by the API via heredoc over SSH, no files written remotely):
#   the API passes positional args $1-$8; this script uses $1, $5, $7 and $8.
#   The other positions are part of the API's contract but are NOT read here —
#   they are fixed, so anything this script needs beyond them (server name,
#   database selection, dump options) is a variable in REGION 1.
#
# $1  RESULT_ID    - BJR01.CentralResultId this run belongs to; stored in
#                    BLS01.S01F02 on every status row this script inserts.
# $5  BASE_DIR     - STORAGE_ROOT; shared storage mount root. The destination is
#                    BASE_DIR/BACKUP_FOLDER (appended below), so the same base
#                    dir can be reused across scripts.
# $7  STATUS_DB    - database holding BLS01.
# $8  CONFIG_ID    - BJC03.ConfigId, the backup job *definition* (vs RESULT_ID,
#                    which is this one execution). Recorded in the manifest for
#                    traceability; deliberately NOT part of any filename — see
#                    the BACKUP_FOLDER note below.
#                    (Was $9 before the 2026-07-21 TIMEOUT_MIN-arg removal.)
#
set -euo pipefail

# =============================================================================
# REGION 1: CONFIGURATION
# =============================================================================

# --- Positional args — passed by the API at run time ---
# Only these four. The arg contract is fixed; everything else is a variable below.
RESULT_ID="$1"
BASE_DIR="$5"
STATUS_DB="$7"
CONFIG_ID="$8"

# --- DB credentials — injected from CMC27 before SSH delivery ---------------
# The API replaces these tokens with plaintext values before the script is sent
# to the server. They live in the script body, not as CLI args, so they are
# never visible in `ps aux`.
MYSQL_HOST="{{CMC27:db-host}}"
MYSQL_PORT="{{CMC27:db-port}}"
MYSQL_USER="{{CMC27:db-user}}"
MYSQL_PASSWORD="{{CMC27:db-password}}"

# --- Timezone for status writes --------------------------------------------
# Every `mysql` invocation pins the session to IST via --init-command, so NOW()
# in BLS01 timestamps is consistent regardless of the server's default tz.
# Held as a scalar, not an array: dump_one runs in an `xargs bash -c` subshell
# and only exported scalars survive that boundary.
MYSQL_TZ="+05:30"
MYSQL_INIT_CMD="SET time_zone='${MYSQL_TZ}'"

# --- Identity — recorded in the logs and the run manifest, and used to build
#     the destination folder below ----------------------------------------------
# Not an argument: the API's positional contract is fixed, so this is set per
# copy of the script.
SERVER_NAME="Cloud-Live-DB-Tirupati"

# --- Destination folder — appended to BASE_DIR ($5) ------------------------
# One folder holds exactly one backup job's output. Same-day archives from two
# jobs sharing a folder would collide on identical names, so give every job its
# own folder rather than namespacing filenames with CONFIG_ID.
BACKUP_FOLDER="Logical/${SERVER_NAME}"

# --- Server-local settings (edit here, not passed via CLI) ----------------
# Binary paths. Resolved against PATH in pre-flight if these do not exist — a
# non-interactive SSH shell can have a minimal PATH, and vice versa.
MYSQL_BIN="/usr/bin/mysql"
MYSQLDUMP_BIN="/usr/bin/mysqldump"

# --- Backup mode ---
#   ALL      -> every non-system database
#   SELECTED -> the databases named in the newest list file in DB_LIST_DIR
BACKUP_MODE="ALL"
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

# How often (seconds) the background ticker bumps this run's RUNNING rows.
# Keep well below the dashboard's "stuck" threshold.
HEARTBEAT_INTERVAL=30

# --- Validate required positional arguments ---
missing=()
[[ -n "${RESULT_ID:-}" ]] || missing+=("RESULT_ID (\$1)")
[[ -n "${BASE_DIR:-}" ]]  || missing+=("BASE_DIR (\$5)")
[[ -n "${STATUS_DB:-}" ]] || missing+=("STATUS_DB (\$7)")
[[ -n "${CONFIG_ID:-}" ]] || missing+=("CONFIG_ID (\$8)")
if [[ "${#missing[@]}" -gt 0 ]]; then
  echo "ERROR: missing required argument(s): ${missing[*]}" >&2
  echo "Usage: $0 expects positional args \$1=RESULT_ID \$5=BASE_DIR \$7=STATUS_DB \$8=CONFIG_ID" >&2
  exit 1
fi

# --- Derived (do not edit) ---
# Date alone; a time is appended by the collision check in REGION 7.
TS="$(date +'%Y-%m-%d')"
RUN_STARTED_AT="$(date +'%Y-%m-%d %H:%M:%S')"

BACKUP_DIR="$BASE_DIR/$BACKUP_FOLDER"
LOG_DIR="$BACKUP_DIR/logs"
LOG_FILE="$LOG_DIR/backup_$(date +'%Y%m%d').log"
MANIFEST_DIR="$BACKUP_DIR/manifests"

# Per-destination, not global: two jobs writing different folders on one host
# must not block each other. Kept on LOCAL disk — on a network mount a dropped
# mount reads as "no lock held" in exactly the situation where it matters.
LOCK_TAG="$(printf '%s' "$BACKUP_FOLDER" | tr -c 'A-Za-z0-9._-' '_')"
LOCK_DIR="/var/run"
[[ -w "$LOCK_DIR" ]] || LOCK_DIR="/tmp"
LOCKFILE="${LOCK_DIR}/dblogical_${LOCK_TAG}.lock"

DB_COUNT=0
OK_COUNT=0
FAILED_COUNT=0
FAILED_LIST=""
MISSING_LIST=""
SOURCE_DATA_OPT=""
RESOLVED_MODE=""
NICE_CMD=""
FAIL_FLAG=""
HEARTBEAT_PID=""
STATUS_TABLE_READY=0

# =============================================================================
# REGION 2: LOGGING
# =============================================================================

# The log file lives under BACKUP_DIR, which is a network mount that may not
# exist yet (or at all). Falling back to plain stdout matters: logging runs
# before the directories are created and while a failed mount is being
# diagnosed, and a failing `tee` inside a pipeline would abort the script under
# `set -e` — losing the very message explaining why.
_log_writable() { [[ -n "${LOG_FILE:-}" && -w "$(dirname "$LOG_FILE")" ]]; }

_log() {
  local level="$1"; shift
  local line
  line="$(printf '%s [%-5s] %s' "$(date +'%Y-%m-%d %H:%M:%S')" "$level" "$*")"
  if _log_writable; then
    printf '%s\n' "$line" | tee -a "$LOG_FILE"
  else
    printf '%s\n' "$line"
  fi
}
log_info()  { _log "INFO"  "$@"; }
log_warn()  { _log "WARN"  "$@"; }
log_error() { _log "ERROR" "$@"; }
log_step()  {
  if _log_writable; then printf '\n' | tee -a "$LOG_FILE"; else printf '\n'; fi
  _log "STEP" "==== $* ===="
}

# =============================================================================
# REGION 3: MYSQL HELPERS
# =============================================================================

# stderr goes to the log, not /dev/null: an empty result must be
# distinguishable from a failed connection.
mysql_val() {
  "$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" \
    --init-command="$MYSQL_INIT_CMD" -N -B -e "$1" 2>>"$LOG_FILE"
}
mysql_run() {
  "$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" \
    --init-command="$MYSQL_INIT_CMD" -e "$1" 2>>"$LOG_FILE"
}

# Fire-and-forget status write — ALWAYS guarded with `|| true` so a status-DB
# hiccup can never abort the run under `set -e` or lose a good backup.
record() {
  "$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" \
    --init-command="$MYSQL_INIT_CMD" -e "$1" 2>/dev/null || true
}

# Escape single quotes for safe inlining into SQL string literals by doubling
# them ('' — the SQL standard). A quote variable is used deliberately: writing
# the replacement as \'\' inside double quotes leaves the backslashes literal
# and produces \'\' instead of '', which corrupts the value (and breaks under
# NO_BACKSLASH_ESCAPES). $q$q expands to two real quotes with no backslashes.
sql_escape() { local q="'"; printf '%s' "${1//$q/$q$q}"; }

# =============================================================================
# REGION 4: STATUS TABLE (BLS01)
# =============================================================================

# Create the per-database status table if it doesn't already exist.
# Piped in via heredoc (not -e) so the DDL needs no quote escaping. Guarded by
# the caller (used inside `if`) so a failure never aborts the backup.
ensure_status_table() {
  local out rc
  out="$("$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" \
    --init-command="$MYSQL_INIT_CMD" 2>&1 <<SQL
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
        COMMENT 'CurrentFileSize (uncompressed .sql bytes)',
    S01F11 BIGINT NULL
        COMMENT 'FinalFileSize (archive bytes)',
    S01F12 VARCHAR(64) NULL
        COMMENT 'Sha256Checksum',
    S01F13 INT NULL
        COMMENT 'ExitCode',
    S01F14 TEXT NULL
        COMMENT 'ErrorMessage',
    S01C04 DATETIME NOT NULL
        DEFAULT CURRENT_TIMESTAMP
        ON UPDATE CURRENT_TIMESTAMP
        COMMENT 'UpdatedAt (heartbeat — bumps on every write)',
    PRIMARY KEY (S01F01),
    INDEX idx_bls01_result (S01F02),
    INDEX idx_bls01_status (S01F07)
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

# Record a terminal FAILED row for something that is not a real database — a
# pre-flight refusal, lock contention, a name that does not exist. Without this
# an early exit leaves the run with no trace at all in the dashboard.
#   $1 = pseudo/real database name    $2 = reason    $3 = exit code
bls01_failed_row() {
  [[ "$STATUS_TABLE_READY" == "1" ]] || return 0
  record "INSERT INTO ${STATUS_DB}.BLS01
            (S01F02, S01F05, S01F07, S01F08, S01C06, S01C07, S01F13, S01F14)
          VALUES
            (${RESULT_ID}, '$(sql_escape "$1")', 'FAILED', $$, NOW(), NOW(),
             ${3:-1}, '$(sql_escape "$2")');"
}

# --- Live heartbeat for the whole run -------------------------------------
# A single mysqldump can run for a long time writing nothing to its status row.
# This ticker bumps S01C04 on every row this run still has RUNNING, so the
# dashboard can always tell "working" from "stuck" — and a hard kill (SIGKILL,
# which cannot be trapped) shows up as a stale heartbeat. Harmless before the
# first dump starts: the UPDATE simply matches no rows.
heartbeat_start() {
  [[ "$STATUS_TABLE_READY" == "1" ]] || return 0
  heartbeat_stop   # never leave two tickers running
  (
    while true; do
      sleep "$HEARTBEAT_INTERVAL"
      "$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" \
        --init-command="$MYSQL_INIT_CMD" \
        -e "UPDATE ${STATUS_DB}.BLS01 SET S01C04=NOW()
            WHERE S01F02=${RESULT_ID} AND S01F07='RUNNING';" 2>/dev/null || true
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

# Exit sweep. dump_one closes its own row on every path, so by the time the
# script exits nothing should still be RUNNING — unless the run was aborted
# (set -e, SIGINT/SIGTERM) or a status write was lost. Either way a row left
# RUNNING would sit "in progress" in the dashboard forever, so close it here.
# No xargs children are alive at this point, so any RUNNING row is genuinely
# stale and cannot be closed by anyone else.
on_exit() {
  local ec=$?
  local rc=$ec
  # A row still RUNNING is a failure even when the script itself exited 0, so
  # never record 0 as the exit code of one.
  [[ "$rc" -eq 0 ]] && rc=1
  heartbeat_stop
  if [[ "$STATUS_TABLE_READY" == "1" ]]; then
    record "UPDATE ${STATUS_DB}.BLS01
              SET S01F07='FAILED', S01C07=NOW(), S01F13=${rc},
                  S01F14='$(sql_escape "run ended before this database finished (script exit ${ec})")'
            WHERE S01F02=${RESULT_ID} AND S01F07='RUNNING';"
  fi
  if [[ -n "$FAIL_FLAG" ]]; then
    rm -f "$FAIL_FLAG" 2>/dev/null || true
  fi
  return 0
}
trap on_exit EXIT
# Convert signals into a normal exit so the EXIT trap above runs.
trap 'exit 130' INT
trap 'exit 143' TERM

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
result_id=${RESULT_ID}
config_id=${CONFIG_ID}
server_name=${SERVER_NAME}
started_at=${RUN_STARTED_AT}
finished_at=$(date +'%Y-%m-%d %H:%M:%S')
backup_mode=${RESOLVED_MODE}
mysql_host=${MYSQL_HOST}
mysql_port=${MYSQL_PORT}
mysql_version=$(mysql_val "SELECT VERSION()" 2>/dev/null || echo unknown)
character_set=$(mysql_val "SELECT @@character_set_server" 2>/dev/null || echo unknown)
db_count=${DB_COUNT}
ok_count=${OK_COUNT}
failed_count=${FAILED_COUNT}
failed_list=${FAILED_LIST}
missing_databases=${MISSING_LIST}
dump_opts=${DUMP_OPTS} ${SOURCE_DATA_OPT}
recovery_method=logical_per_database
consistency=per_database_only
EOF
  log_info "Manifest written: $mfile"
}

# =============================================================================
# REGION 6: BACKUP FUNCTION (runs in parallel via xargs)
# =============================================================================

# On a network-backed mount, a file can still be getting touched by the mount's
# background upload/commit process after `sync` returns. tar can start reading
# before that settles and abort with "file changed as we read it". Poll mtime+size
# until they stop changing across two consecutive checks. Always returns 0 (best
# effort) so a slow mount never blocks the backup indefinitely.
wait_for_stable_file() {
  local f="$1"
  local max_wait=30 interval=2 waited=0 prev="" cur=""

  while [[ "$waited" -lt "$max_wait" ]]; do
    cur=$(stat --format='%Y:%s' "$f" 2>/dev/null) || return 0
    if [[ "$cur" == "$prev" && -n "$prev" ]]; then
      return 0
    fi
    prev="$cur"
    sleep "$interval"
    waited=$((waited + interval))
  done
  return 0
}

dump_one() {
  local DB="$1"
  local DB_DIR="$BACKUP_DIR/$DB"
  local SQL_FILE="$DB_DIR/${DB}_${TS}.sql"
  local ARCHIVE_FILE="$DB_DIR/${DB}_${TS}.tar.gz"
  local DUMP_ERR="$DB_DIR/.dump_err_$$"
  local TAR_ERR="$DB_DIR/.tar_err_$$"

  mkdir -p "$DB_DIR"
  log_info "[$DB] start -> ${DB}/${DB}_${TS}.tar.gz"

  record "INSERT INTO ${STATUS_DB}.BLS01
            (S01F02, S01F05, S01F07, S01F08, S01C06)
          VALUES
            (${RESULT_ID}, '$(sql_escape "$DB")', 'RUNNING', $$, NOW());"

  # Close this database's row. $1 = SUCCESS|FAILED, $2 = exit code,
  # $3 = message (FAILED only). Scoped to the RUNNING row so a retry of the
  # same database in a later run is never touched.
  _close_row() {
    local st="$1" ec="$2" msg="${3:-}" set_msg=""
    [[ -n "$msg" ]] && set_msg=", S01F14='$(sql_escape "$msg")'"
    record "UPDATE ${STATUS_DB}.BLS01
              SET S01F07='${st}', S01C07=NOW(), S01F13=${ec}${set_msg}
            WHERE S01F02=${RESULT_ID} AND S01F05='$(sql_escape "$DB")'
              AND S01F07='RUNNING';"
  }

  # `|| dump_exit=$?` rather than `if ! cmd`, so the real mysqldump exit code is
  # captured instead of the negated 0/1 that `if !` would give — and rather than
  # a set +e/set -e pair, which would leave errexit ON for the rest of this
  # function. That matters: under errexit a later incidental failure (a `sync`
  # the filesystem rejects, say) would abort this subshell *before* it recorded
  # the failure or appended to FAIL_FLAG, and the database would be tallied as a
  # success. Every step below therefore handles its own errors explicitly.
  local dump_exit=0
  # shellcheck disable=SC2086  # DUMP_OPTS/NICE_CMD are deliberate word-split lists
  $NICE_CMD "$MYSQLDUMP_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" \
    -h"$MYSQL_HOST" -P"$MYSQL_PORT" \
    $DUMP_OPTS $SOURCE_DATA_OPT --databases "$DB" > "$SQL_FILE" 2>"$DUMP_ERR" \
    || dump_exit=$?

  if [[ "$dump_exit" -ne 0 ]]; then
    local reason
    reason=$(grep -v '\[Warning\].*password' "$DUMP_ERR" | head -1)
    reason="${reason:-unknown error}"
    log_error "[$DB] mysqldump FAILED: $reason"
    _close_row FAILED "$dump_exit" "mysqldump failed: $reason"
    rm -f "$DUMP_ERR" "$SQL_FILE"
    echo "$DB" >> "$FAIL_FLAG"
    return 0
  fi
  rm -f "$DUMP_ERR"

  if [[ ! -s "$SQL_FILE" ]]; then
    log_error "[$DB] dump is empty, skipping archive"
    _close_row FAILED 1 "dump produced an empty file"
    rm -f "$SQL_FILE"
    echo "$DB" >> "$FAIL_FLAG"
    return 0
  fi

  # Flush writes toward storage, then wait until the file settles — see
  # wait_for_stable_file above for why `sync` alone is not enough here.
  # `sync FILE` is not accepted by every coreutils/filesystem combination, and a
  # refusal is not a reason to fail the dump: the stability wait below is the
  # part that actually protects tar.
  sync "$SQL_FILE" 2>/dev/null || true
  wait_for_stable_file "$SQL_FILE"

  # --- Archive, with retry -----------------------------------------------
  # "file changed as we read it" is a timing race against the mount's
  # background commit. A short pause and a retry usually clears it without
  # needing a full re-dump.
  local tar_attempt=0 tar_ok=false tar_err_msg=""
  while [[ "$tar_attempt" -lt 3 ]]; do
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

  if [[ "$tar_ok" != true ]]; then
    log_error "[$DB] tar FAILED after 3 attempts: ${tar_err_msg:-unknown error}"
    _close_row FAILED 1 "tar failed after 3 attempts: ${tar_err_msg:-unknown error}"
    # $SQL_FILE is deliberately kept: nothing is lost, and the raw dump is the
    # only thing left to investigate or fall back on.
    rm -f "$ARCHIVE_FILE" "$TAR_ERR"
    echo "$DB" >> "$FAIL_FLAG"
    return 0
  fi
  rm -f "$TAR_ERR"

  # --- Verify BEFORE deleting the source SQL -----------------------------
  # An archive that "completed" but is truncated fails one of these checks, and
  # the original .sql is still sitting untouched when it does. Discovering a
  # corrupt .tar.gz at restore time is discovering it far too late.
  if ! gzip -t "$ARCHIVE_FILE" 2>>"$LOG_FILE"; then
    log_error "[$DB] archive FAILED integrity check (gzip -t), keeping raw SQL: $SQL_FILE"
    _close_row FAILED 1 "archive failed gzip -t integrity check"
    rm -f "$ARCHIVE_FILE"
    echo "$DB" >> "$FAIL_FLAG"
    return 0
  fi

  if ! tar -tzf "$ARCHIVE_FILE" >/dev/null 2>>"$LOG_FILE"; then
    log_error "[$DB] archive FAILED structural check (tar -tzf), keeping raw SQL: $SQL_FILE"
    _close_row FAILED 1 "archive failed tar -tzf structural check"
    rm -f "$ARCHIVE_FILE"
    echo "$DB" >> "$FAIL_FLAG"
    return 0
  fi

  # Capture the raw size before deleting it: S01F10 records the uncompressed
  # .sql size, S01F11 the archive size.
  local raw_bytes
  raw_bytes=$(stat --format=%s "$SQL_FILE" 2>/dev/null || echo 0)

  rm -f "$SQL_FILE"

  # Bare filename, not sha256sum's default absolute path, so `sha256sum -c`
  # survives the tree being moved or mounted elsewhere.
  sha256sum "$ARCHIVE_FILE" | awk -v f="${DB}_${TS}.tar.gz" '{print $1"  "f}' \
    > "$ARCHIVE_FILE.sha256" 2>>"$LOG_FILE" || true
  local checksum=""
  [[ -s "$ARCHIVE_FILE.sha256" ]] && checksum=$(cut -d' ' -f1 "$ARCHIVE_FILE.sha256")

  # The archive already passed gzip -t and tar -tzf, so it is good — but an
  # archive nobody can verify at restore time is an incomplete artifact set, and
  # reporting it as a success would hide that. The archive is kept either way.
  if [[ -z "$checksum" ]]; then
    log_error "[$DB] archive is valid but its SHA-256 could not be written"
    _close_row FAILED 1 "archive is valid but its SHA-256 could not be written"
    echo "$DB" >> "$FAIL_FLAG"
    return 0
  fi

  local size size_bytes
  size=$(du -h "$ARCHIVE_FILE" | cut -f1)
  size_bytes=$(stat --format=%s "$ARCHIVE_FILE" 2>/dev/null || echo 0)

  record "UPDATE ${STATUS_DB}.BLS01
            SET S01F07='SUCCESS', S01C07=NOW(),
                S01F09='$(sql_escape "$ARCHIVE_FILE")',
                S01F10=${raw_bytes}, S01F11=${size_bytes},
                S01F12='$(sql_escape "$checksum")', S01F13=0
          WHERE S01F02=${RESULT_ID} AND S01F05='$(sql_escape "$DB")'
            AND S01F07='RUNNING';"

  log_info "[$DB] done (size=$size)"
}

# =============================================================================
# REGION 7: MAIN
# =============================================================================

# --- Resolve binaries before anything else uses them ---
# A non-interactive SSH shell can have a minimal PATH, and a distro can put
# these somewhere other than /usr/bin. Try the configured path first, then PATH.
if [[ ! -x "$MYSQL_BIN" ]]; then
  resolved="$(command -v mysql 2>/dev/null || true)"
  [[ -n "$resolved" ]] || { log_error "mysql not found at $MYSQL_BIN and not in PATH"; exit 1; }
  log_warn "mysql not at $MYSQL_BIN; using $resolved"
  MYSQL_BIN="$resolved"
fi
if [[ ! -x "$MYSQLDUMP_BIN" ]]; then
  resolved="$(command -v mysqldump 2>/dev/null || true)"
  [[ -n "$resolved" ]] || { log_error "mysqldump not found at $MYSQLDUMP_BIN and not in PATH"; exit 1; }
  log_warn "mysqldump not at $MYSQLDUMP_BIN; using $resolved"
  MYSQLDUMP_BIN="$resolved"
fi

# --- Status table first ---
# Created BEFORE the directories, the lock and pre-flight (not after) so an
# unreachable mount, lock contention or a pre-flight refusal is still recorded
# as FAILED rather than being invisible in the dashboard. This needs nothing but
# MySQL to be reachable.
if ensure_status_table; then
  STATUS_TABLE_READY=1
  log_info "BLS01 status table verified/created in $STATUS_DB."
else
  log_warn "Could not create BLS01 (is MySQL reachable?); continuing without DB status."
fi

# --- Destination directories ---
if ! mkdir -p "$BACKUP_DIR" "$LOG_DIR" 2>/dev/null; then
  log_error "Cannot create destination directories under $BACKUP_DIR"
  log_error "Is the storage mount ($BASE_DIR) present and writable?"
  bls01_failed_row "PREFLIGHT" "Cannot create destination directories under $BACKUP_DIR" 1
  exit 1
fi

# --- Single-instance lock ---
# Guarded on flock's presence rather than run blind: `flock` missing exits 127,
# which `if ! flock` reads as "lock held" — every run would then no-op with a
# contention message and nothing would ever be backed up.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCKFILE"
  if ! flock -n 9; then
    log_warn "Another logical backup is already running for $BACKUP_DIR, exiting."
    bls01_failed_row "LOCK_CONTENTION" \
      "Skipped: another logical backup was already running on this server (lock held: $LOCKFILE)." 1
    exit 0
  fi
else
  log_warn "flock not found — running WITHOUT a single-instance lock."
  log_warn "Two overlapping runs could overwrite each other's archives."
fi

heartbeat_start

# --- Same-day collision check ---
# Must stay AFTER the lock, or two runs starting together both decide they are
# the first and `tar -czf` overwrites the earlier set.
if find "$BACKUP_DIR" -mindepth 2 -maxdepth 2 -type f -name "*_${TS}.tar.gz" -print -quit 2>/dev/null | grep -q .; then
  TS="${TS}_$(date +'%H-%M-%S')"
  log_warn "Archives for today already exist. Using timestamped run ID: $TS"
  log_warn "The earlier run's archives are left untouched."
fi

log_step "BACKUP RUN START (server=$SERVER_NAME, result=$RESULT_ID, config=${CONFIG_ID:-none}, parallel=$PARALLEL)"
log_info "Base path: $BACKUP_DIR"
log_info "Run ID   : $TS"

# --- Sanity checks ---
command -v tar       >/dev/null || { log_error "tar not found"; bls01_failed_row "PREFLIGHT" "tar not found" 1; exit 1; }
command -v gzip      >/dev/null || { log_error "gzip not found"; bls01_failed_row "PREFLIGHT" "gzip not found" 1; exit 1; }
command -v sha256sum >/dev/null || { log_error "sha256sum not found"; bls01_failed_row "PREFLIGHT" "sha256sum not found" 1; exit 1; }

# nice/ionice are a courtesy to the live server, not a requirement. Held as a
# scalar so it survives export into the xargs subshell.
if command -v nice >/dev/null && command -v ionice >/dev/null; then
  NICE_CMD="nice -n 19 ionice -c2 -n7"
else
  log_warn "nice/ionice unavailable — dumps will run at normal priority"
fi

if ! mysql_val "SELECT 1" >/dev/null; then
  log_error "Cannot connect to MySQL at $MYSQL_HOST:$MYSQL_PORT"
  bls01_failed_row "PREFLIGHT" "Cannot connect to MySQL at $MYSQL_HOST:$MYSQL_PORT" 1
  exit 1
fi

# --- Resolve the binlog-coordinate option ---
# MySQL renamed --master-data to --source-data in 8.0.26.
if "$MYSQLDUMP_BIN" --help 2>/dev/null | grep -q -- '--source-data'; then
  SOURCE_DATA_OPT="--source-data=2"
elif "$MYSQLDUMP_BIN" --help 2>/dev/null | grep -q -- '--master-data'; then
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
    bls01_failed_row "PREFLIGHT" \
      "mysqldump $SOURCE_DATA_OPT requires REPLICATION CLIENT on user '$MYSQL_USER'" 1
    exit 1
  fi
fi

# Collects every database that failed, including names resolved as missing
# below, so the tally at the end of the run covers them all.
FAIL_FLAG="$(mktemp /tmp/.dblogical_fail.XXXXXX)"

# --- Build the database list ---
REQUESTED=""
RESOLVED_MODE="$BACKUP_MODE"
if [[ "$BACKUP_MODE" == "ALL" ]]; then
  :
elif [[ "$BACKUP_MODE" == "SELECTED" ]]; then
  [[ -n "$DB_LIST_DIR" ]] || { log_error "BACKUP_MODE=SELECTED but DB_LIST_DIR is empty"; bls01_failed_row "PREFLIGHT" "BACKUP_MODE=SELECTED but DB_LIST_DIR is empty" 1; exit 1; }
  [[ -d "$DB_LIST_DIR" ]] || { log_error "DB_LIST_DIR not a directory: $DB_LIST_DIR"; bls01_failed_row "PREFLIGHT" "DB_LIST_DIR not a directory: $DB_LIST_DIR" 1; exit 1; }

  DB_LIST_FILE=$(find "$DB_LIST_DIR" -maxdepth 1 -type f \( -name '*.txt' -o -name '*.csv' -o -name '*.lst' \) -printf '%T@ %p\n' 2>/dev/null \
                 | sort -rn | head -1 | cut -d' ' -f2-)

  [[ -n "$DB_LIST_FILE" ]] || { log_error "No list files (.txt/.csv/.lst) found in $DB_LIST_DIR"; bls01_failed_row "PREFLIGHT" "No list files found in $DB_LIST_DIR" 1; exit 1; }
  [[ -r "$DB_LIST_FILE" ]] || { log_error "Latest file not readable: $DB_LIST_FILE"; bls01_failed_row "PREFLIGHT" "Latest list file not readable: $DB_LIST_FILE" 1; exit 1; }

  log_info "Using DB list file: $DB_LIST_FILE"
  REQUESTED=$(grep -vE '^\s*$|^\s*#' "$DB_LIST_FILE" || true)
else
  log_error "Invalid BACKUP_MODE: $BACKUP_MODE (must be ALL or SELECTED)"
  bls01_failed_row "PREFLIGHT" "Invalid BACKUP_MODE: $BACKUP_MODE" 1
  exit 1
fi

if [[ "$RESOLVED_MODE" == "ALL" ]]; then
  DATABASES=$(mysql_val "SHOW DATABASES" | grep -Ev "^(information_schema|performance_schema|mysql|sys)$" || true)
else
  # An explicitly requested name that does not exist is reported, not skipped
  # quietly: a renamed or dropped tenant must be visible in the dashboard as a
  # failure rather than vanishing from the run.
  EXISTING=$(mysql_val "SHOW DATABASES" || true)
  DATABASES=""
  while IFS= read -r db; do
    [[ -n "$db" ]] || continue
    if printf '%s\n' "$EXISTING" | grep -qxF -- "$db"; then
      DATABASES="${DATABASES}${db}"$'\n'
    else
      log_error "Requested database does not exist on this server: $db"
      bls01_failed_row "$db" "Requested database does not exist on this server" 1
      echo "$db" >> "$FAIL_FLAG"
      MISSING_LIST="${MISSING_LIST}${db} "
    fi
  done <<< "$REQUESTED"
  DATABASES="$(printf '%s' "$DATABASES")"
fi

# Count non-blank lines: `wc -l` on an empty string returns 1, not 0.
PRESENT_COUNT=$(printf '%s\n' "$DATABASES" | grep -c '[^[:space:]]' || true)
MISSING_COUNT=$(printf '%s\n' "$MISSING_LIST" | tr ' ' '\n' | grep -c '[^[:space:]]' || true)
DB_COUNT=$(( PRESENT_COUNT + MISSING_COUNT ))

if [[ "${PRESENT_COUNT:-0}" -eq 0 ]]; then
  log_error "Database list is EMPTY. Nothing was backed up."
  log_error "Check MySQL connectivity and BACKUP_MODE."
  bls01_failed_row "PREFLIGHT" "Resolved database list is empty; nothing was backed up" 1
  FAILED_COUNT="$DB_COUNT"
  FAILED_LIST="$MISSING_LIST"
  write_manifest
  exit 1
fi

log_info "Mode: $RESOLVED_MODE"
log_info "Databases ($PRESENT_COUNT): $(echo "$DATABASES" | tr '\n' ' ')"
[[ -n "$MISSING_LIST" ]] && log_warn "Missing (recorded as FAILED): $MISSING_LIST"

# --- Space check ---
# Measures ALL user databases even when a subset was selected — over-estimating
# is the safe direction. An under-estimate fills the volume and produces
# truncated dumps.
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
  bls01_failed_row "PREFLIGHT" \
    "Insufficient space in $BACKUP_DIR: need ~${REQUIRED_MB}MB, have ${FREE_MB}MB" 1
  FAILED_COUNT="$DB_COUNT"
  FAILED_LIST="$MISSING_LIST"
  write_manifest
  exit 1
fi
log_info "Space OK: ${FREE_MB}MB free, ~${REQUIRED_MB}MB needed"

# --- Run backups in parallel ---
log_step "DUMP DATABASES"
# _log_writable must be exported too, not just _log: without it the xargs
# subshells hit a command-not-found, take the fallback branch, and every
# per-database line goes to stdout only — never into the log file.
export -f dump_one wait_for_stable_file _log _log_writable log_info log_warn log_error record sql_escape
export BACKUP_DIR LOG_FILE TS DUMP_OPTS SOURCE_DATA_OPT NICE_CMD
export MYSQL_BIN MYSQLDUMP_BIN MYSQL_USER MYSQL_PASSWORD MYSQL_HOST MYSQL_PORT
export MYSQL_INIT_CMD RESULT_ID STATUS_DB FAIL_FLAG

echo "$DATABASES" | xargs -r -n1 -P "$PARALLEL" bash -c 'dump_one "$@"' _ || true

OK_COUNT="$PRESENT_COUNT"
FAILED_COUNT=0
FAILED_LIST=""

if [[ -s "$FAIL_FLAG" ]]; then
  FAILED_COUNT=$(grep -c '[^[:space:]]' "$FAIL_FLAG" || true)
  FAILED_LIST=$(tr '\n' ' ' < "$FAIL_FLAG")
  OK_COUNT=$(( DB_COUNT - FAILED_COUNT ))
  log_error "Failed databases ($FAILED_COUNT/$DB_COUNT): $FAILED_LIST"
else
  log_info "All $DB_COUNT databases dumped successfully."
fi

write_manifest

heartbeat_stop

# =============================================================================
# REGION 8: EXIT STATUS
# =============================================================================

if [[ ${FAILED_COUNT:-0} -gt 0 ]]; then
  log_step "BACKUP RUN FINISHED WITH ERRORS ($FAILED_COUNT/$DB_COUNT failed)"
  exit 1
fi

log_step "BACKUP RUN FINISHED"
exit 0
