#!/bin/bash
#
# db_restore.sh
#
# Restores every backup archive for a run into its own database on a validation
# server, using the ORIGINAL database name embedded in each dump (not a
# synthetic name) — the schema/database name is never renamed during restore.
# Since a dump has no DROP statements of its own, its target database is
# dropped and recreated fresh before every load so repeated restores of the
# same config stay idempotent. This is intentionally destructive on the
# validation server, which exists specifically as a disposable restore target.
#
# Does NOT run RCM06 checks and does NOT drop the databases after loading —
# RestoreCheckRunner (C#) runs checks against the first successfully-restored
# database afterwards, over SSH, once every RLS02 row for this run is terminal.
# Retention/cleanup is handled elsewhere, not by this script.
#
# Exception to "restore every database": if a dump's own database name matches
# STATUS_DB ($4), that one database is skipped (logged, not treated as a
# fatal script error) instead of being dropped/recreated — STATUS_DB holds
# this script's own RLS02 status rows, and destroying it mid-run would leave
# every row for this run unreadable even though other databases restored fine.
#
# Parameterization (per DB BRD Script Authoring Guide):
#   - Positional args ($1-$4)   -> runtime data
#   - {{CMC27:key-name}} tokens -> secrets/config, resolved by the API before
#                                  SSH delivery. Never visible in `ps aux`.
#
# Usage (delivered by the API via heredoc over SSH, no files written remotely):
#   the API now passes $1-$7 (a shared contract with the physical/XtraBackup restore
#   flow, restore_direct.sh) — this script uses only $1-$4; $5-$7 are appended, unused
#   trailing args and can be safely ignored (bash does not error on extra positional args).
#
# > CHANGED 2026-07-21: the TIMEOUT_MIN argument (was $4) was removed (per-job
# > restore timeout dropped) and STATUS_DB shifted down from $5 to $4.
#
# $1  RESTORE_RESULT_ID  - RJR03 PK this run belongs to; stored in
#                          RLS02.S02F02 on every status row this script writes.
# $2  BACKUP_FILE_PATHS  - one backup archive to restore, as either a bare path
#                          (single-database backups) or a JSON array of paths
#                          (multi-database backups — mirrors BJR01.BackupFilePath,
#                          which now stores one path per database backed up in a
#                          run). Each path is a .tar.gz produced by the backup
#                          scripts (job{ConfigId}_{db}_{ts}.tar.gz) with a
#                          sibling .sha256 file at the same path + ".sha256".
#                          Assumed directly readable here (shared storage mount
#                          between backup source servers and this validation
#                          server within the same environment).
# $3  VALIDATION_SERVER  - hostname of this server, for logging only.
# $4  STATUS_DB          - database holding RLS02 (and, centrally, RJR03) on
#                          this validation server. (Was $5 before the 2026-07-21
#                          TIMEOUT_MIN-arg removal.)
#
# Live status is reported into RLS02 (restore_live_status) on STATUS_DB — ONE
# ROW PER DATABASE restored this run (S02F02=RESTORE_RESULT_ID, many rows share
# the same value, same fan-out as BLS01 for backups), polled every 30s by
# RestoreStatusPollJob. Per-database CurrentPhase (S02F04) advances
# VERIFYING_CHECKSUM -> EXTRACTING -> CREATING_DB -> LOADING -> SUCCESS/FAILED.
# This script does not signal overall run success/failure itself (no synthetic
# whole-run row, no special exit code) — same philosophy as the backup scripts:
# the API aggregates the per-database rows into the run's overall outcome, and
# the central timeout mechanism covers the case where nothing was ever written.
#
set -euo pipefail

# =============================================================================
# REGION 1: CONFIGURATION
# =============================================================================

# --- Positional args — passed by the API at run time ---
RESTORE_RESULT_ID="$1"
BACKUP_FILE_PATHS="$2"
VALIDATION_SERVER="$3"
STATUS_DB="$4"     # TIMEOUT_MIN (was $4) removed 2026-07-21; STATUS_DB shifted $5->$4

# --- DB credentials — injected from CMC27 before SSH delivery -------------
# Resolved against THIS (validation) server's own CMC27 rows — same 4 standard
# keys the backup scripts use, just scoped to a different server id.
MYSQL_HOST="{{CMC27:db-host}}"
MYSQL_PORT="{{CMC27:db-port}}"
MYSQL_USER="{{CMC27:db-user}}"
MYSQL_PASSWORD="{{CMC27:db-password}}"

# --- Validate required positional arguments ---
missing=()
[ -n "${RESTORE_RESULT_ID:-}" ] || missing+=("RESTORE_RESULT_ID (\$1)")
[ -n "${BACKUP_FILE_PATHS:-}" ] || missing+=("BACKUP_FILE_PATHS (\$2)")
[ -n "${VALIDATION_SERVER:-}" ] || missing+=("VALIDATION_SERVER (\$3)")
[ -n "${STATUS_DB:-}" ]         || missing+=("STATUS_DB (\$4)")
if [ "${#missing[@]}" -gt 0 ]; then
  echo "ERROR: missing required argument(s): ${missing[*]}" >&2
  echo "Usage: $0 expects positional args \$1=RESTORE_RESULT_ID \$2=BACKUP_FILE_PATHS \$3=VALIDATION_SERVER \$4=STATUS_DB" >&2
  exit 1
fi

# --- Normalize BACKUP_FILE_PATHS ($2) into a bash array -------------------
# Accepts either a JSON array (["path1","path2"]) or a single bare path, the
# same JSON-or-CSV convention the backup scripts use for TARGET_DBS ($4 there).
case "$BACKUP_FILE_PATHS" in
  \[*\])
    mapfile -t BACKUP_FILES < <(echo "$BACKUP_FILE_PATHS" | tr -d '[]"' | tr ',' '\n' \
      | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$')
    ;;
  *)
    BACKUP_FILES=("$BACKUP_FILE_PATHS")
    ;;
esac

# --- Derived (do not edit) ---
WORK_DIR="$(mktemp -d "/tmp/dbbrd-restore-${RESTORE_RESULT_ID}-XXXXXX")"

# =============================================================================
# REGION 2: STATUS TRACKING (RLS02) + LOGGING
# =============================================================================

# All log lines go to stdout, which the SSH detached launcher already
# redirects to /tmp/dbbrd-restore-{id}.log — no separate internal log file
# is needed here (unlike the backup scripts, which run on a schedule and
# consolidate many runs into one daily log).
log_info()  { printf '%s [INFO ] %s\n'  "$(date +'%Y-%m-%d %H:%M:%S')" "$*"; }
log_warn()  { printf '%s [WARN ] %s\n'  "$(date +'%Y-%m-%d %H:%M:%S')" "$*"; }
log_error() { printf '%s [ERROR] %s\n'  "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# Inserts a new RUNNING row for one database and echoes its StatusId (S02F01)
# so later calls can target this exact row — matching by id, not by name,
# since the real database name isn't known until after extraction. INSERT and
# SELECT LAST_INSERT_ID() must run in the same mysql invocation/session
# (separate mysql_run calls don't share a connection, so LAST_INSERT_ID()
# from a prior call would be invisible).
write_db_running() {
  local placeholder="$1"
  mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" -N -B -e \
    "INSERT INTO ${STATUS_DB}.RLS02 (S02F02, S02F03, S02F04, S02F05, S02F06, S02C06) VALUES ($RESTORE_RESULT_ID, 'RUNNING', 'VERIFYING_CHECKSUM', $$, '$placeholder', NOW()); SELECT LAST_INSERT_ID();" 2>/dev/null
}

write_db_phase() {
  local status_id="$1" phase="$2"
  mysql_run "UPDATE ${STATUS_DB}.RLS02 SET S02F04='$phase' WHERE S02F01=$status_id;"
}

# Swaps the placeholder name for the real original-database name once it's
# known (after extraction determines it from the dump's own USE statement).
write_db_rename() {
  local status_id="$1" db="$2"
  mysql_run "UPDATE ${STATUS_DB}.RLS02 SET S02F06='$db' WHERE S02F01=$status_id;"
}

write_db_success() {
  local status_id="$1"
  mysql_run "UPDATE ${STATUS_DB}.RLS02 SET S02F03='SUCCESS', S02F04='SUCCESS', S02C07=NOW(), S02F07=0 WHERE S02F01=$status_id;"
}

write_db_failed() {
  local status_id="$1" code="$2" msg="$3" msg_sql
  msg_sql="${msg//\'/\'\'}"
  mysql_run "UPDATE ${STATUS_DB}.RLS02 SET S02F03='FAILED', S02F04='FAILED', S02C07=NOW(), S02F07=$code, S02F08='$msg_sql' WHERE S02F01=$status_id;"
}

# Cleanup only — no synthetic status write. Per-database RLS02 rows are the
# sole source of truth for this run's outcome; there is no whole-run row to
# fall back to, matching the backup scripts' philosophy exactly.
trap 'rm -rf "$WORK_DIR"' EXIT

# =============================================================================
# REGION 3: MYSQL HELPERS
# =============================================================================

mysql_val() { mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" -N -B -e "$1" 2>/dev/null; }
mysql_run() { mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" -e "$1" 2>/dev/null; }

# Create the restore live-status table if it doesn't already exist yet.
# Piped in via heredoc (not -e) so the DDL doesn't need any quote escaping.
ensure_status_table() {
  mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" 2>/dev/null <<SQL
CREATE TABLE IF NOT EXISTS ${STATUS_DB}.RLS02 (
    S02F01 INT NOT NULL AUTO_INCREMENT
        COMMENT 'StatusId PK',
    S02F02 BIGINT NOT NULL
        COMMENT 'CentralResultId FK→RJR03 (many rows per result — one per database, like BLS01)',
    S02F03 ENUM('RUNNING','SUCCESS','FAILED') NOT NULL
        COMMENT 'Status',
    S02F04 ENUM('VERIFYING_CHECKSUM','EXTRACTING','CREATING_DB','LOADING','SUCCESS','FAILED')
        NOT NULL DEFAULT 'VERIFYING_CHECKSUM'
        COMMENT 'CurrentPhase (per database)',
    S02F05 INT NULL
        COMMENT 'Pid',
    S02C06 DATETIME NOT NULL
        COMMENT 'StartedAt',
    S02C07 DATETIME NULL
        COMMENT 'CompletedAt',
    S02F06 VARCHAR(255) NULL
        COMMENT 'DatabaseName (this row''s single database — placeholder until renamed post-extraction)',
    S02F07 INT NULL
        COMMENT 'ExitCode',
    S02F08 TEXT NULL
        COMMENT 'ErrorMessage',
    S02C04 DATETIME NOT NULL
        DEFAULT CURRENT_TIMESTAMP
        ON UPDATE CURRENT_TIMESTAMP
        COMMENT 'UpdatedAt',
    PRIMARY KEY (S02F01),
    INDEX idx_rls02_result (S02F02),
    INDEX idx_rls02_status (S02F03)
) ENGINE=InnoDB
DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;
SQL

  # CREATE TABLE IF NOT EXISTS above is a no-op on servers where RLS02 was
  # already created by an older version of this script — best-effort migrate
  # in place. Non-fatal if any statement can't run (e.g. already migrated,
  # or insufficient privilege): every ALTER is wrapped individually so one
  # failing/no-op statement doesn't skip the rest.
  set +e
  # Older versions used S02F06 as TEXT (comma-joined multi-db list) or had it
  # sized for a single name only — VARCHAR(255) is enough now that each row
  # holds exactly one database name.
  mysql_run "ALTER TABLE ${STATUS_DB}.RLS02 MODIFY COLUMN S02F06 VARCHAR(255) NULL COMMENT 'DatabaseName (this row''s single database — placeholder until renamed post-extraction)';"
  # Oldest versions enforced one row per run via a unique key — drop it so
  # multiple databases can each get their own row, then ensure the plain
  # (non-unique) lookup index exists in its place.
  mysql_run "ALTER TABLE ${STATUS_DB}.RLS02 DROP INDEX uq_rls02_result;"
  mysql_run "ALTER TABLE ${STATUS_DB}.RLS02 ADD INDEX idx_rls02_result (S02F02);"
  set -e
}

# =============================================================================
# REGION 4: PER-FILE RESTORE (runs once per entry in BACKUP_FILES)
# =============================================================================

FAILED_FILES=()
SKIPPED_FILES=()
RESTORED_DBS=()

# Restores a single archive, writing its own RLS02 row throughout (RUNNING at
# start, renamed to the real database name once known, terminal SUCCESS/FAILED
# at the end). On any failure, logs the reason, records it in FAILED_FILES,
# and returns 0 so the caller's loop continues to the next file instead of
# aborting the whole run for one bad database — same philosophy as dump_one()
# in the backup scripts.
restore_one() {
  local file="$1" idx="$2"
  local sub_dir="$WORK_DIR/f${idx}"
  mkdir -p "$sub_dir"

  local status_id
  status_id="$(write_db_running "file${idx}:$(basename "$file")")"

  if [ ! -f "$file" ]; then
    log_error "[$idx] backup file not found or not readable: $file"
    FAILED_FILES+=("$file: not found")
    write_db_failed "$status_id" 1 "backup file not found or not readable"
    return 0
  fi

  if [ ! -f "${file}.sha256" ]; then
    log_error "[$idx] checksum sidecar file missing: ${file}.sha256"
    FAILED_FILES+=("$file: checksum sidecar missing")
    write_db_failed "$status_id" 1 "checksum sidecar file missing"
    return 0
  fi

  set +e
  local checksum_out
  checksum_out="$(sha256sum -c "${file}.sha256" 2>&1)"
  local checksum_exit=$?
  set -e
  if [ "$checksum_exit" -ne 0 ]; then
    log_error "[$idx] checksum verification FAILED: $checksum_out"
    FAILED_FILES+=("$file: checksum verification failed")
    write_db_failed "$status_id" 1 "checksum verification failed"
    return 0
  fi
  log_info "[$idx] checksum OK: $(basename "$file")"

  write_db_phase "$status_id" EXTRACTING
  set +e
  tar -xzf "$file" -C "$sub_dir" 2>"$sub_dir/.tar_err"
  local tar_exit=$?
  set -e
  if [ "$tar_exit" -ne 0 ]; then
    log_error "[$idx] extraction FAILED: $(cat "$sub_dir/.tar_err" 2>/dev/null)"
    FAILED_FILES+=("$file: extraction failed")
    write_db_failed "$status_id" 1 "extraction failed"
    return 0
  fi

  local dump_file
  dump_file="$(find "$sub_dir" -maxdepth 1 -type f -name '*.sql' | head -1)"
  if [ -z "$dump_file" ]; then
    log_error "[$idx] no .sql file found inside archive: $file"
    FAILED_FILES+=("$file: no .sql file in archive")
    write_db_failed "$status_id" 1 "no .sql file found inside archive"
    return 0
  fi

  # mysqldump --databases <db> always emits "USE `<db>`;" — this is the ground
  # truth for what to restore into (no C# arg carries this; BJR01 has no
  # original-database-name column).
  local original_db
  original_db="$(grep -m1 '^USE ' "$dump_file" | sed -E 's/^USE `([^`]+)`;.*/\1/')"
  if [ -z "$original_db" ]; then
    log_error "[$idx] could not determine original database name from dump: $dump_file"
    FAILED_FILES+=("$file: no USE statement found in dump")
    write_db_failed "$status_id" 1 "no USE statement found in dump"
    return 0
  fi
  write_db_rename "$status_id" "$original_db"

  # Refuse to drop/recreate the database this very script uses to report its
  # own status. STATUS_DB holds RLS02 (and, on the same-env central host,
  # RJR03) — if a business database happens to share that name, restoring it
  # would wipe out every status row for this run mid-flight.
  if [ "$original_db" = "$STATUS_DB" ]; then
    log_warn "[$idx] skipping \`$original_db\` — its name matches this server's STATUS_DB ($STATUS_DB); restoring it would destroy RLS02 for this run"
    SKIPPED_FILES+=("$file: database name '$original_db' collides with STATUS_DB")
    write_db_failed "$status_id" 1 "skipped: database name matches STATUS_DB"
    return 0
  fi
  log_info "[$idx] restoring into \`$original_db\` from $(basename "$file")"

  write_db_phase "$status_id" CREATING_DB
  # Drop and recreate the database fresh. The dump has no DROP statements of
  # its own (backup scripts don't pass --add-drop-table/--add-drop-database),
  # so reloading onto an already-populated same-named database would fail on
  # "table already exists". Dropping first keeps repeated restores of the
  # same config idempotent. Intentionally destructive — the validation server
  # exists specifically as a disposable restore target.
  mysql_run "DROP DATABASE IF EXISTS \`$original_db\`;"
  mysql_run "CREATE DATABASE \`$original_db\`;"

  write_db_phase "$status_id" LOADING
  set +e
  local load_err="$sub_dir/.load_err"
  mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -P"$MYSQL_PORT" \
    -D "$original_db" < "$dump_file" 2>"$load_err"
  local load_exit=$?
  set -e

  if [ "$load_exit" -ne 0 ]; then
    local reason
    reason="$(grep -v '\[Warning\].*password' "$load_err" | head -1)"
    reason="${reason:-unknown error}"
    log_error "[$idx] dump load FAILED for \`$original_db\`: $reason"
    FAILED_FILES+=("$file ($original_db): $reason")
    write_db_failed "$status_id" "$load_exit" "$reason"
    return 0
  fi

  log_info "[$idx] restore of \`$original_db\` complete."
  RESTORED_DBS+=("$original_db")
  write_db_success "$status_id"
}

# =============================================================================
# REGION 5: MAIN
# =============================================================================

ensure_status_table
log_info "RESTORE RUN START (resultId=${RESTORE_RESULT_ID}, validationServer=${VALIDATION_SERVER}, files=${#BACKUP_FILES[@]})"

# --- Sanity checks (nothing to restore yet, so no RLS02 row to write — same
# as the backup scripts' own pre-flight checks) ---
command -v mysql >/dev/null || { log_error "mysql client not found"; exit 1; }
command -v tar    >/dev/null || { log_error "tar not found"; exit 1; }

if [ "${#BACKUP_FILES[@]}" -eq 0 ]; then
  log_error "No backup files resolved from BACKUP_FILE_PATHS: $BACKUP_FILE_PATHS"
  exit 1
fi

idx=0
for file in "${BACKUP_FILES[@]}"; do
  idx=$((idx + 1))
  restore_one "$file" "$idx"
done

if [ "${#FAILED_FILES[@]}" -gt 0 ]; then
  # "${arr[*]}" joins using only the first character of $IFS, so a two-character
  # separator like "; " can't be produced that way — build it with printf instead.
  failed_summary="$(printf '%s; ' "${FAILED_FILES[@]}")"
  failed_summary="${failed_summary%; }"
  log_error "Failed files: $failed_summary"
fi

if [ "${#SKIPPED_FILES[@]}" -gt 0 ]; then
  skipped_summary="$(printf '%s; ' "${SKIPPED_FILES[@]}")"
  skipped_summary="${skipped_summary%; }"
  log_warn "Skipped files (STATUS_DB name collision): $skipped_summary"
fi

# No exit code or synthetic row reflects the run's overall outcome — the API
# aggregates the per-database RLS02 rows written above into the RJR03 result,
# exactly as BJR01 is derived from BLS01 for backups.
log_info "RESTORE RUN FINISHED (databases=${RESTORED_DBS[*]:-none}, failed=${#FAILED_FILES[@]}, skipped=${#SKIPPED_FILES[@]})"
