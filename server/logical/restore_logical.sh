#!/bin/bash
#
# server/logical/restore_logical.sh — per-database logical restore
#
# Usage: ./restore_logical.sh <database> [restore_point]
# Docs:  instructions/server/logical/README.md
#
set -euo pipefail

# =============================================================================
# REGION 1: CONFIGURATION
# =============================================================================

# --- MySQL connection ---
MYSQL_USER="Admin"
MYSQL_PASSWORD=""
MYSQL_HOST="20.20.15.4"

# --- Backup location (MUST match BASE_DIR in logical.sh) ---
BASE_DIR="/livestorage/YK/Logical/Cloud-Live-DB-Restore"

# --- SAFETY SWITCH ---
#   0 = REPORT ONLY (keep it here between incidents)
#   1 = EXECUTE: drops the database and imports the archive over it
CONFIRM_RESTORE=0

# --- Paths ---
STAGE_DIR="/var/tmp/dblogical-restore"
STATE_DIR="/var/lib/dbvault"
LOCKFILE="/var/run/dblogical_restore.lock"

# =============================================================================
# REGION 2: ARGUMENTS
# =============================================================================

show_usage() {
  cat <<EOF
Usage: $0 <database> [restore_point]

  <database>       Database to restore (required)
  [restore_point]  Run ID, e.g. 2026-08-10 or 2026-08-10_14-30-11
                   (default: newest available)

Drops the existing database and imports the archive in its place.

Current settings (REGION 1):
  BASE_DIR        = $BASE_DIR
  CONFIRM_RESTORE = $CONFIRM_RESTORE  $([[ $CONFIRM_RESTORE -eq 0 ]] && echo '(report only)' || echo '(WILL EXECUTE)')
EOF
  exit 1
}

[[ $# -ge 1 && $# -le 2 ]] || show_usage
case "${1:-}" in -h|--help|"") show_usage ;; esac

DB="$1"
TS="${2:-}"

DB_DIR="$BASE_DIR/$DB"
LOG_DIR="$BASE_DIR/logs"
RUN_TS="$(date +'%Y%m%d_%H%M%S')"
LOG_FILE="$LOG_DIR/restore_${DB}_${RUN_TS}.log"

mkdir -p "$LOG_DIR" "$STAGE_DIR" "$STATE_DIR"

# =============================================================================
# REGION 3: LOGGING AND HELPERS
# =============================================================================

_log() {
  local lvl="$1"; shift
  printf '%s [%-5s] %s\n' "$(date +'%F %T')" "$lvl" "$*" | tee -a "$LOG_FILE"
}
log_info()  { _log "INFO"  "$@"; }
log_warn()  { _log "WARN"  "$@"; }
log_error() { _log "ERROR" "$@"; }
log_step()  { printf '\n' | tee -a "$LOG_FILE"; _log "STEP" "==== $* ===="; }

mysql_val() {
  mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -N -B -e "$1" 2>>"$LOG_FILE"
}
mysql_run() {
  mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" -e "$1" 2>>"$LOG_FILE"
}

WORK_DIR=""
cleanup() {
  local rc=$?
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
  if [[ $rc -ne 0 ]]; then
    log_error "Exiting with status $rc"
  fi
  exit $rc
}
trap cleanup EXIT INT TERM

# =============================================================================
# REGION 4: PRE-FLIGHT CHECKS
# =============================================================================

log_step "LOGICAL RESTORE PRE-FLIGHT (db=$DB)"

command -v mysql     >/dev/null || { log_error "mysql client not found"; exit 1; }
command -v mysqldump >/dev/null || { log_error "mysqldump not found"; exit 1; }
command -v tar       >/dev/null || { log_error "tar not found"; exit 1; }
log_info "Check 1/8: required tools present"

exec 9>"$LOCKFILE"
flock -n 9 || { log_error "Another logical restore is already running."; exit 1; }
log_info "Check 2/8: lock acquired"

mysql_val "SELECT 1" >/dev/null || { log_error "Cannot connect to MySQL at $MYSQL_HOST"; exit 1; }
log_info "Check 3/8: MySQL reachable"

[[ -d "$DB_DIR" ]] || { log_error "No backup directory for '$DB': $DB_DIR"; exit 1; }
log_info "Check 4/8: backup directory present"

log_info "Available restore points for '$DB':"
FOUND=0
while read -r f; do
  FOUND=1
  base=$(basename "$f"); pt="${base#${DB}_}"; pt="${pt%.tar.gz}"
  age_h=$(( ( $(date +%s) - $(stat -c%Y "$f") ) / 3600 ))
  chk="MISSING"; [[ -f "${f}.sha256" ]] && chk="ok"
  printf '    %-24s  %8s  %4sh old  checksum:%s\n' \
    "$pt" "$(du -h "$f" | cut -f1)" "$age_h" "$chk" | tee -a "$LOG_FILE"
done < <(find "$DB_DIR" -maxdepth 1 -type f -name "${DB}_*.tar.gz" | LC_ALL=C sort)
[[ $FOUND -eq 1 ]] || { log_error "No archives found in $DB_DIR"; exit 1; }

# --- Resolve the restore point: run IDs sort lexically, newest last.
# LC_ALL=C is required — locale collation can ignore punctuation and make
# 2026-08-10 vs 2026-08-10_14-30-11 order unpredictably.
if [[ -z "$TS" ]]; then
  ARCHIVE=$(find "$DB_DIR" -maxdepth 1 -type f -name "${DB}_*.tar.gz" | LC_ALL=C sort | tail -1)
  TS=$(basename "$ARCHIVE"); TS="${TS#${DB}_}"; TS="${TS%.tar.gz}"
  log_info "Check 5/8: no restore point given, selected newest: $TS"
else
  ARCHIVE="$DB_DIR/${DB}_${TS}.tar.gz"
  [[ -f "$ARCHIVE" ]] || { log_error "Restore point not found: $ARCHIVE"; exit 1; }
  log_info "Check 5/8: restore point $TS"
fi

ARCHIVE_AGE_H=$(( ( $(date +%s) - $(stat -c%Y "$ARCHIVE") ) / 3600 ))
log_info "Check 6/8: archive $(du -h "$ARCHIVE" | cut -f1), ${ARCHIVE_AGE_H}h old"

# Verify before anything is dropped, so a failure here costs nothing.
if [[ -f "${ARCHIVE}.sha256" ]]; then
  if ( cd "$DB_DIR" && sha256sum -c "$(basename "${ARCHIVE}.sha256")" >/dev/null 2>&1 ); then
    log_info "Check 7/8: SHA-256 verified"
  else
    log_error "CHECKSUM MISMATCH. Archive is corrupt. Nothing was changed."
    exit 1
  fi
else
  log_warn "Check 7/8: no checksum file, falling back to archive integrity test"
  tar -tzf "$ARCHIVE" >/dev/null 2>&1 || { log_error "Archive is unreadable"; exit 1; }
fi

DB_EXISTS=$(mysql_val "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${DB}';")
if [[ "$DB_EXISTS" == "1" ]]; then
  CUR_TABLES=$(mysql_val "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${DB}';")
  log_info "Check 8/8: target exists with ${CUR_TABLES} table(s), will be DROPPED"
else
  CUR_TABLES=0
  log_info "Check 8/8: target does not exist, will be created"
fi

# =============================================================================
# REGION 5: SAFETY GATE
# =============================================================================

if [[ $CONFIRM_RESTORE -ne 1 ]]; then
  log_step "REPORT ONLY. Nothing was changed."
  cat <<EOF | tee -a "$LOG_FILE"

  Database        : $DB
  Restore point   : $TS  (${ARCHIVE_AGE_H}h old)
  Archive         : $ARCHIVE
  Current state   : ${CUR_TABLES} table(s) -> will be DROPPED and replaced
  Data loss       : everything written to '$DB' in the last ${ARCHIVE_AGE_H}h

  To execute: set CONFIRM_RESTORE=1 in REGION 1, then re-run.

EOF
  exit 0
fi

log_warn "CONFIRM_RESTORE=1. Proceeding with a DESTRUCTIVE restore of '$DB'."

# =============================================================================
# REGION 6: EXTRACT AND VALIDATE
# =============================================================================

log_step "STEP 1/5: EXTRACT"

WORK_DIR="${STAGE_DIR}/${DB}_${RUN_TS}"
mkdir -p "$WORK_DIR"
tar -xzf "$ARCHIVE" -C "$WORK_DIR" || { log_error "Extraction failed"; exit 1; }

SQL_FILE=$(find "$WORK_DIR" -maxdepth 1 -type f -name '*.sql' | head -1)
[[ -s "$SQL_FILE" ]] || { log_error "No .sql file inside the archive"; exit 1; }
log_info "Extracted $(basename "$SQL_FILE") ($(du -h "$SQL_FILE" | cut -f1))"

# Guard against a renamed archive dropping and overwriting the wrong database.
if ! grep -qiE "CREATE DATABASE.*\`${DB}\`|^USE \`${DB}\`" "$SQL_FILE"; then
  log_error "Dump does not reference database '${DB}'. Refusing to import."
  log_error "Confirm you selected the correct archive."
  exit 1
fi
log_info "Dump content matches target database"

# Informational only — this script never applies binlogs.
BINLOG_LINE=$(grep -m1 'CHANGE MASTER TO\|CHANGE REPLICATION SOURCE TO' "$SQL_FILE" || true)
if [[ -n "$BINLOG_LINE" ]]; then
  log_info "Dump binlog coordinate: $(echo "$BINLOG_LINE" | tr -d '-' | tr -s ' ')"
else
  log_warn "No binlog coordinate in dump (--source-data=2 not set at backup time)"
fi

# =============================================================================
# REGION 7: SAFETY DUMP
# A failure here does NOT stop the restore — see the README.
# =============================================================================

log_step "STEP 2/5: SAFETY DUMP"

SAFETY_FILE=""
if [[ "$DB_EXISTS" == "1" ]]; then
  CANDIDATE="${DB_DIR}/PRE-RESTORE_${DB}_${RUN_TS}.sql.gz"
  log_info "Dumping current state to $CANDIDATE"
  # Mirrors DUMP_OPTS in logical.sh. Change one, change the other.
  if mysqldump -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" \
       --single-transaction --quick --routines --events --triggers \
       --set-gtid-purged=OFF --default-character-set=utf8mb4 \
       --databases "$DB" 2>>"$LOG_FILE" | gzip > "$CANDIDATE"; then
    SAFETY_FILE="$CANDIDATE"
    log_info "Safety dump complete ($(du -h "$SAFETY_FILE" | cut -f1))"
    log_info "Rollback: zcat '$SAFETY_FILE' | mysql -u$MYSQL_USER -p -h$MYSQL_HOST"
  else
    rm -f "$CANDIDATE"
    log_warn "===================================================="
    log_warn "SAFETY DUMP FAILED — CONTINUING ANYWAY"
    log_warn "===================================================="
    log_warn "The current contents of '$DB' could not be dumped, most likely"
    log_warn "because they are damaged — which is why you are restoring."
    log_warn ""
    log_warn "CONSEQUENCE: this restore has NO ROLLBACK. Once the database is"
    log_warn "dropped below, the current data is gone for good."
    log_warn "Press Ctrl+C NOW if you need it preserved first."
    log_warn "===================================================="
  fi
else
  log_info "Target does not exist, nothing to preserve"
fi

# =============================================================================
# REGION 8: DROP AND IMPORT
# =============================================================================

log_step "STEP 3/5: DROP AND IMPORT"

if [[ "$DB_EXISTS" == "1" ]]; then
  log_warn "Dropping database '${DB}' (${CUR_TABLES} tables)"
  mysql_run "DROP DATABASE \`${DB}\`;" || { log_error "DROP DATABASE failed"; exit 1; }
  log_info "Dropped"
fi

log_info "Importing, this may take a while..."
IMPORT_START=$(date +%s)

# No --force: the import must halt at the first error rather than leave a
# schema that is part imported, part missing.
if ! mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -h"$MYSQL_HOST" \
       < "$SQL_FILE" 2>>"$LOG_FILE"; then
  log_error "===================================================="
  log_error "IMPORT FAILED. Database '${DB}' is in a PARTIAL state."
  log_error "Do NOT let applications use it."
  log_error "Review: $LOG_FILE"
  if [[ -n "$SAFETY_FILE" ]]; then
    log_error "Rollback: zcat '$SAFETY_FILE' | mysql -u$MYSQL_USER -p -h$MYSQL_HOST"
  else
    log_error "There is NO safety dump to roll back to."
  fi
  log_error "===================================================="
  exit 1
fi

IMPORT_SECS=$(( $(date +%s) - IMPORT_START ))
log_info "Import completed in ${IMPORT_SECS}s"

# =============================================================================
# REGION 9: VERIFY
# =============================================================================

log_step "STEP 4/5: VERIFY"

NEW_EXISTS=$(mysql_val "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${DB}';")
[[ "$NEW_EXISTS" == "1" ]] || { log_error "Database '${DB}' missing after import"; exit 1; }

NEW_TABLES=$(mysql_val   "SELECT COUNT(*) FROM information_schema.TABLES   WHERE TABLE_SCHEMA='${DB}';")
[[ ${NEW_TABLES:-0} -gt 0 ]] || { log_error "Database restored with ZERO tables"; exit 1; }

NEW_ROUTINES=$(mysql_val "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='${DB}';")
NEW_TRIGGERS=$(mysql_val "SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='${DB}';")
NEW_SIZE_MB=$(mysql_val  "SELECT ROUND(SUM(data_length+index_length)/1048576,1)
                          FROM information_schema.TABLES WHERE TABLE_SCHEMA='${DB}';")

log_info "Tables   : ${NEW_TABLES}  (was ${CUR_TABLES})"
log_info "Routines : ${NEW_ROUTINES}"
log_info "Triggers : ${NEW_TRIGGERS}"
log_info "Size     : ${NEW_SIZE_MB} MB"

# =============================================================================
# REGION 10: RECORD STATE
# =============================================================================

log_step "STEP 5/5: RECORD STATE"

MARKER="${STATE_DIR}/logical_${DB}_${RUN_TS}"
cat > "$MARKER" <<EOF
restored_at=$(date +'%F %T')
database=${DB}
restore_point=${TS}
archive=${ARCHIVE}
recovery_method=logical_per_database
binlogs_applied=no
safety_dump=${SAFETY_FILE:-none}
tables_before=${CUR_TABLES}
tables_after=${NEW_TABLES}
import_seconds=${IMPORT_SECS}
EOF
log_info "Marker: $MARKER"

cat <<EOF | tee -a "$LOG_FILE"

====================================================
LOGICAL RESTORE COMPLETE
====================================================
Database      : $DB
Restore point : $TS  (${ARCHIVE_AGE_H}h old)
Tables        : $NEW_TABLES  (was $CUR_TABLES)
Duration      : ${IMPORT_SECS}s
Safety dump   : ${SAFETY_FILE:-none}

DATA LOSS: everything written to '$DB' in the last
${ARCHIVE_AGE_H}h is gone. Binlogs were NOT applied.

Before reopening traffic:
  1. Application smoke test for this database
  2. Spot-check row counts against expectations
  3. Notify the SLA owner of the ${ARCHIVE_AGE_H}h loss window

Reminder: set CONFIRM_RESTORE back to 0 in REGION 1.
====================================================
EOF

log_step "RESTORE FINISHED"
exit 0
