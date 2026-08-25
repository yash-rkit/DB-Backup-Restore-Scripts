#!/usr/bin/env bash
#
# stream-scripts/tests/pitr_writer.sh — generate PITR test traffic
#
# Inserts a tagged batch of rows into yma01 and ymp01 in every database that
# holds both, and records the batch in pitr_test.batches together with the
# binlog position it spans. Run every 15 minutes from cron, OFFSET from
# binlog_collect.sh so each batch commits before the next FLUSH BINARY LOGS:
#
#   5,20,35,50 * * * * /path/to/tests/pitr_writer.sh >> /var/log/pitr_writer.cron 2>&1
#
# The ledger lives in a real database, so the physical backup and the binlogs
# carry it to the restored server — the restored ledger is what tells you which
# batches the replay was supposed to reach.
#
#   ./pitr_writer.sh                  # one batch, all eligible databases
#   ./pitr_writer.sh --rows 100       # smaller batch
#   ./pitr_writer.sh --limit 20       # first 20 databases only, for a rehearsal
#   ./pitr_writer.sh --dry-run        # print the plan, write nothing
#   ./pitr_writer.sh --pause          # stop future cron runs
#   ./pitr_writer.sh --resume         # let them run again
#
#   PART 1   configuration
#   PART 2   log engine
#   PART 3   failure handling
#   PART 4   probes
#   PART 5   arguments
#   PART 6   pause switch
#   PART 7   single-run lock
#   PART 8   pre-flight
#   PART 9   control schema
#   PART 10  discovery
#   PART 11  open the ledger
#   PART 12  insert
#   PART 13  close the ledger
#   PART 14  summary
#
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# PART 1  CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

MYSQL_USER="Admin"
MYSQL_PASSWORD=""
MYSQL_BIN="/usr/bin/mysql"

ROWS_PER_TABLE=1000               # per table, per database, per batch
CONTROL_DB="pitr_test"            # ledger and the numbers table live here
MARKER="PITRTEST"                 # goes in the marker column; also the cleanup key

# table : batch-id column (varchar>=13) : marker column (varchar>=8) : label column (varchar>=29)
TABLE_SPECS=(
  "yma01:A01F03:A01X01:A01F02"
  "ymp01:P01F03:P01X01:P01F02"
)

LOG_DIR="/var/log/pitr_test"
LOCK_FILE="/var/lock/pitr_writer.lock"
PAUSE_FILE="/var/lib/dbvault/pitr_writer.pause"

PROGRESS_EVERY=25                 # databases between progress lines

DRY_RUN=0
DB_LIMIT=0                        # 0 = every eligible database

# ═══════════════════════════════════════════════════════════════════════════
# PART 2  LOG ENGINE
# ═══════════════════════════════════════════════════════════════════════════

RUN_LOG=""
PHASE="init"
WARN_COUNT=0

LOG_RULE='=============================================================='
LOG_SUB='--------------------------------------------------------------'
LOG_DOTS='..............................................................'

emit() {
  printf '%s\n' "$1"
  [[ -n "$RUN_LOG" && -d "${RUN_LOG%/*}" ]] && printf '%s\n' "$1" >> "$RUN_LOG"
  return 0
}
emit_err() {
  printf '%s\n' "$1" >&2
  [[ -n "$RUN_LOG" && -d "${RUN_LOG%/*}" ]] && printf '%s\n' "$1" >> "$RUN_LOG"
  return 0
}

banner() { emit "$LOG_RULE"; emit "$1"; emit "$LOG_RULE"; }
sub()    { emit "$LOG_SUB"; }
kv()     { emit "$(printf ' %-16s: %s' "$1" "$2")"; }

tag()  { printf '[%s]' "$PHASE"; }
info() { emit     "$(printf '%s %-5s %-13s %s' "$(date +%T)" 'INFO'  "$(tag)" "$1")"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1))
         emit     "$(printf '%s %-5s %-13s %s' "$(date +%T)" 'WARN'  "$(tag)" "$1")"; }
erro() { emit_err "$(printf '%s %-5s %-13s %s' "$(date +%T)" 'ERROR' "$(tag)" "$1")"; }
cont() { emit     "$(printf '%-28s %s' '' "$1")"; }
cerr() { emit_err "$(printf '%-28s %s' '' "$1")"; }

leader() {
  local pad=$(( 40 - ${#1} - ${#2} ))
  (( pad < 3 )) && pad=3
  printf '%s %s %s' "$1" "${LOG_DOTS:0:$pad}" "$2"
}
ok()  { info "$(leader "$1" 'OK')"; }
val() { info "$(leader "$1" "$2")"; }
nok() { warn "$(leader "$1" "$2")"; }

START_EPOCH="$(date +%s)"
elapsed() {
  local d=$(( $(date +%s) - $1 ))
  if (( d < 60 )); then printf '%ds' "$d"; else printf '%dm%02ds' $((d / 60)) $((d % 60)); fi
}

# ═══════════════════════════════════════════════════════════════════════════
# PART 3  FAILURE HANDLING
#
# A batch that dies half way is a legitimate test state, not a lost cause: the
# ledger row stays at status='running' and names how far it got, which is
# exactly what the restored server should show for a batch cut in two.
# ═══════════════════════════════════════════════════════════════════════════

BATCH_ID=""
DBS_OK=0
DBS_FAILED=0
ROWS_INSERTED=0
LEDGER_OPEN=0
INTERRUPTED=0

fail_run() {
  trap - ERR INT TERM
  emit ""
  banner " BATCH FAILED  ${BATCH_ID:-(none)}"
  if [[ $INTERRUPTED -eq 1 ]]; then
    kv "cause" "interrupted — Ctrl-C or kill"
  else
    kv "cause" "failed in phase '$PHASE'"
  fi
  kv "databases ok"     "$DBS_OK"
  kv "databases failed" "$DBS_FAILED"
  kv "rows inserted"    "$ROWS_INSERTED"
  if [[ $LEDGER_OPEN -eq 1 ]]; then
    mysql_q "UPDATE \`$CONTROL_DB\`.batches
                SET status='aborted', finished_at=NOW(), dbs_ok=$DBS_OK,
                    dbs_failed=$DBS_FAILED, rows_inserted=$ROWS_INSERTED,
                    binlog_end=$(sql_str "$(binlog_pos)")
              WHERE batch_id=$(sql_str "$BATCH_ID")" >/dev/null 2>&1 \
      && kv "ledger" "marked aborted" \
      || kv "ledger" "COULD NOT BE UPDATED — fix batch $BATCH_ID by hand"
  fi
  kv "run log" "${RUN_LOG:-(none)}"
  sub
  banner " RESULT failed batch=${BATCH_ID:-none} phase=$PHASE ok=$DBS_OK failed=$DBS_FAILED dur_s=$(( $(date +%s) - START_EPOCH ))"
  exit 1
}

die() { erro "$1"; shift; local l; for l in "$@"; do cerr "$l"; done; fail_run; }

trap fail_run ERR
trap 'INTERRUPTED=1; fail_run' INT TERM

# ═══════════════════════════════════════════════════════════════════════════
# PART 4  PROBES
# ═══════════════════════════════════════════════════════════════════════════

mysql_q() { "$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -NBe "$1" 2>/dev/null; }
mysql_f() { "$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -NB < "$1" 2>/dev/null; }

# Single-quoted SQL literal. These values are script-generated, but quoting
# them properly keeps a database name with an apostrophe from becoming syntax.
sql_str() { printf "'%s'" "${1//\'/\'\'}"; }

# SHOW BINARY LOG STATUS is 8.4+; SHOW MASTER STATUS covers older servers.
binlog_pos() {
  local r
  r=$(mysql_q "SHOW BINARY LOG STATUS" | awk '{print $1":"$2}')
  [[ -n "$r" ]] || r=$(mysql_q "SHOW MASTER STATUS" | awk '{print $1":"$2}')
  printf '%s' "${r:-unknown:0}"
}

# ═══════════════════════════════════════════════════════════════════════════
# PART 5  ARGUMENTS
# ═══════════════════════════════════════════════════════════════════════════

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rows)     ROWS_PER_TABLE="${2:-}"; shift 2 ;;
    --limit)    DB_LIMIT="${2:-}"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --pause)    mkdir -p "$(dirname "$PAUSE_FILE")" 2>/dev/null || true
                date '+%F %T' > "$PAUSE_FILE"
                echo "paused — cron runs will skip until: $0 --resume"
                trap - ERR INT TERM; exit 0 ;;
    --resume)   rm -f "$PAUSE_FILE"; echo "resumed"; trap - ERR INT TERM; exit 0 ;;
    -h|--help)  sed -n '3,26p' "$0" | cut -c3-; trap - ERR INT TERM; exit 0 ;;
    *)          erro "unknown argument: $1"; cerr "see --help"; exit 1 ;;
  esac
done

[[ "$ROWS_PER_TABLE" =~ ^[0-9]+$ && "$ROWS_PER_TABLE" -gt 0 ]] \
  || { erro "--rows must be a positive integer, got: $ROWS_PER_TABLE"; exit 1; }
[[ "$DB_LIMIT" =~ ^[0-9]+$ ]] \
  || { erro "--limit must be a non-negative integer, got: $DB_LIMIT"; exit 1; }

BATCH_ID="$(date +%Y%m%d_%H%M)"

mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp"
RUN_LOG="${LOG_DIR}/writer_$(date +%Y%m%d).log"

# ═══════════════════════════════════════════════════════════════════════════
# PART 6  PAUSE SWITCH
#
# A file rather than a crontab edit: stopping the writers is step one of
# freezing the test, and it has to be reversible without root or an editor.
# ═══════════════════════════════════════════════════════════════════════════

if [[ -f "$PAUSE_FILE" ]]; then
  echo " writer paused since $(cat "$PAUSE_FILE" 2>/dev/null) — skipping this run"
  echo " resume with: $0 --resume"
  trap - ERR INT TERM
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 7  SINGLE-RUN LOCK
#
# 420 databases x 2 tables x 1000 rows can outlast the 15-minute cron gap, and
# two writers interleaving would make the ledger's binlog span meaningless.
# ═══════════════════════════════════════════════════════════════════════════

# The redirection is scoped to the braces on purpose. `exec 9>f 2>/dev/null`
# looks equivalent and is not: exec applies EVERY redirection to the shell
# itself, so the 2>/dev/null would silence this script's stderr permanently and
# every later error message would vanish into it.
mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
if ! { exec 9>"$LOCK_FILE"; } 2>/dev/null; then
  erro "cannot open the lock file: $LOCK_FILE"
  cerr "a concurrent run cannot be detected, and two writers interleaving"
  cerr "would make the ledger's binlog span meaningless — refusing to run"
  exit 1
fi

if ! flock -n 9 2>/dev/null; then
  echo " a previous writer run is STILL GOING — skipping batch $BATCH_ID"
  echo " the batch is taking longer than the cron interval; lower --rows"
  echo " or widen the interval, or the batches will start dropping"
  trap - ERR INT TERM
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 8  PRE-FLIGHT
# ═══════════════════════════════════════════════════════════════════════════

PHASE="preflight"
emit ""
banner " PITR WRITER  batch=$BATCH_ID  rows/table=$ROWS_PER_TABLE"

[[ -x "$MYSQL_BIN" ]] || die "mysql client not found at $MYSQL_BIN"
mysql_q "SELECT 1" >/dev/null || die "cannot connect to MySQL as $MYSQL_USER" \
  "check MYSQL_USER / MYSQL_PASSWORD at the top of this script"
ok "mysql reachable"

# Row-based logging is what makes the replay reproduce these inserts exactly.
# Under STATEMENT the INSERT ... SELECT below is non-deterministic in ways that
# can diverge on replay, and the whole comparison stops meaning anything.
BINLOG_FORMAT="$(mysql_q "SELECT @@binlog_format")"
if [[ "$BINLOG_FORMAT" != "ROW" ]]; then
  nok "binlog_format" "$BINLOG_FORMAT"
  cont "this test assumes ROW; under $BINLOG_FORMAT a replay may legitimately"
  cont "diverge from the source and a failed comparison proves nothing"
else
  ok "binlog_format ROW"
fi

LOG_BIN="$(mysql_q "SELECT @@log_bin")"
[[ "$LOG_BIN" == "1" ]] || die "log_bin is OFF — there is nothing to collect" \
  "no binlog means no PITR, so this test cannot run at all"
ok "log_bin on"

val "run log" "$RUN_LOG"

# ═══════════════════════════════════════════════════════════════════════════
# PART 9  CONTROL SCHEMA
#
# `seq` is a plain numbers table rather than a recursive CTE: it sidesteps
# cte_max_recursion_depth entirely and is reused by every one of the 840
# inserts below.
# ═══════════════════════════════════════════════════════════════════════════

PHASE="control"

if [[ $DRY_RUN -eq 0 ]]; then
  mysql_q "
    CREATE DATABASE IF NOT EXISTS \`$CONTROL_DB\`;
    CREATE TABLE IF NOT EXISTS \`$CONTROL_DB\`.batches (
      batch_id      varchar(20) NOT NULL,
      host          varchar(64) DEFAULT NULL,
      status        varchar(16) DEFAULT NULL,
      started_at    datetime    DEFAULT NULL,
      finished_at   datetime    DEFAULT NULL,
      rows_per_table int        DEFAULT 0,
      dbs_total     int         DEFAULT 0,
      dbs_ok        int         DEFAULT 0,
      dbs_failed    int         DEFAULT 0,
      rows_inserted bigint      DEFAULT 0,
      binlog_start  varchar(80) DEFAULT NULL,
      binlog_end    varchar(80) DEFAULT NULL,
      PRIMARY KEY (batch_id)
    ) ENGINE=InnoDB;
    CREATE TABLE IF NOT EXISTS \`$CONTROL_DB\`.batch_dbs (
      batch_id varchar(20) NOT NULL,
      db_name  varchar(64) NOT NULL,
      status   varchar(16) DEFAULT NULL,
      rows_inserted int    DEFAULT 0,
      PRIMARY KEY (batch_id, db_name)
    ) ENGINE=InnoDB;
    CREATE TABLE IF NOT EXISTS \`$CONTROL_DB\`.\`seq\` (
      n int NOT NULL, PRIMARY KEY (n)
    ) ENGINE=InnoDB;" >/dev/null || die "could not create the control schema in $CONTROL_DB"
  ok "control schema"

  # Top up `seq` to ROWS_PER_TABLE. Idempotent, so raising --rows later just
  # extends it instead of needing a rebuild.
  SEQ_MAX="$(mysql_q "SELECT IFNULL(MAX(n),0) FROM \`$CONTROL_DB\`.\`seq\`")"
  if [[ "${SEQ_MAX:-0}" -lt "$ROWS_PER_TABLE" ]]; then
    info "extending the numbers table from ${SEQ_MAX:-0} to $ROWS_PER_TABLE"
    mysql_q "
      SET SESSION cte_max_recursion_depth = $((ROWS_PER_TABLE + 100));
      INSERT INTO \`$CONTROL_DB\`.\`seq\` (n)
      WITH RECURSIVE s(n) AS (
        SELECT 1 UNION ALL SELECT n + 1 FROM s WHERE n < $ROWS_PER_TABLE
      )
      SELECT n FROM s WHERE n > ${SEQ_MAX:-0}" >/dev/null \
      || die "could not extend $CONTROL_DB.seq to $ROWS_PER_TABLE rows"
  fi
  val "numbers table" "$(mysql_q "SELECT COUNT(*) FROM \`$CONTROL_DB\`.\`seq\`") rows"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 10  DISCOVERY
# ═══════════════════════════════════════════════════════════════════════════

PHASE="discover"
TBL_LIST=""
for spec in "${TABLE_SPECS[@]}"; do
  TBL_LIST+="${TBL_LIST:+,}'${spec%%:*}'"
done
TBL_COUNT=${#TABLE_SPECS[@]}

mapfile -t DBS < <(mysql_q "
  SELECT TABLE_SCHEMA FROM information_schema.TABLES
   WHERE TABLE_NAME IN ($TBL_LIST)
     AND TABLE_SCHEMA NOT IN ('information_schema','mysql','performance_schema','sys','$CONTROL_DB')
   GROUP BY TABLE_SCHEMA
  HAVING COUNT(DISTINCT TABLE_NAME) = $TBL_COUNT
   ORDER BY TABLE_SCHEMA")

[[ ${#DBS[@]} -gt 0 ]] || die "no database holds all of: $TBL_LIST" \
  "nothing to write to — check the table names in TABLE_SPECS"

if [[ "$DB_LIMIT" -gt 0 && "$DB_LIMIT" -lt "${#DBS[@]}" ]]; then
  DBS=("${DBS[@]:0:$DB_LIMIT}")
  nok "databases" "${#DBS[@]} (--limit, not the full set)"
else
  val "databases" "${#DBS[@]}"
fi

PLANNED_ROWS=$(( ${#DBS[@]} * TBL_COUNT * ROWS_PER_TABLE ))
val "rows this batch" "$PLANNED_ROWS across $(( ${#DBS[@]} * TBL_COUNT )) tables"

if [[ $DRY_RUN -eq 1 ]]; then
  emit ""
  banner " DRY RUN — NOTHING WAS WRITTEN"
  kv "batch id"     "$BATCH_ID"
  kv "databases"    "${#DBS[@]}"
  kv "tables"       "$(( ${#DBS[@]} * TBL_COUNT ))"
  kv "rows"         "$PLANNED_ROWS"
  kv "first three"  "${DBS[0]:-}${DBS[1]:+, ${DBS[1]}}${DBS[2]:+, ${DBS[2]}}"
  kv "marker"       "$MARKER"
  sub
  trap - ERR INT TERM
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 11  OPEN THE LEDGER
#
# Written BEFORE the inserts, so a batch cut in half by the collector leaves a
# row saying 'running' on the restored server. That is the evidence of where
# the replay landed, not a bug to be tidied away.
# ═══════════════════════════════════════════════════════════════════════════

PHASE="ledger"
BINLOG_START="$(binlog_pos)"
val "binlog start" "$BINLOG_START"

mysql_q "
  REPLACE INTO \`$CONTROL_DB\`.batches
    (batch_id, host, status, started_at, rows_per_table, dbs_total, binlog_start)
  VALUES ($(sql_str "$BATCH_ID"), $(sql_str "$(hostname -s)"), 'running', NOW(),
          $ROWS_PER_TABLE, ${#DBS[@]}, $(sql_str "$BINLOG_START"))" >/dev/null \
  || die "could not open the ledger row for batch $BATCH_ID"
LEDGER_OPEN=1
ok "ledger opened"

# ═══════════════════════════════════════════════════════════════════════════
# PART 12  INSERT
#
# One connection per database, not one per table: per-database error handling
# stays possible while the connection count stays in the hundreds, and a
# failing database no longer takes the rest of the batch down with it.
# ═══════════════════════════════════════════════════════════════════════════

PHASE="insert"
sub
info "inserting $ROWS_PER_TABLE rows per table into ${#DBS[@]} databases"

FAILED_DBS=()
IDX=0
for db in "${DBS[@]}"; do
  IDX=$((IDX + 1))
  SQL="START TRANSACTION;"
  for spec in "${TABLE_SPECS[@]}"; do
    IFS=':' read -r t bcol mcol lcol <<< "$spec"
    # Only the three tag columns are set; every other column takes its DEFAULT.
    # Under ROW logging the binlog still carries the whole row image, so the
    # binlog volume this generates is realistic even though the SQL is small.
    SQL+="
      INSERT INTO \`$db\`.\`$t\` (\`$lcol\`, \`$bcol\`, \`$mcol\`)
      SELECT CONCAT('$MARKER-', '$BATCH_ID', '-', LPAD(n, 6, '0')),
             '$BATCH_ID', '$MARKER'
        FROM \`$CONTROL_DB\`.\`seq\` WHERE n <= $ROWS_PER_TABLE;"
  done
  SQL+="COMMIT;"

  if printf '%s\n' "$SQL" | "$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" \
       -NB >/dev/null 2>>"${RUN_LOG}.sql_errors"; then
    DBS_OK=$((DBS_OK + 1))
    ROWS_INSERTED=$(( ROWS_INSERTED + TBL_COUNT * ROWS_PER_TABLE ))
    mysql_q "INSERT INTO \`$CONTROL_DB\`.batch_dbs (batch_id, db_name, status, rows_inserted)
             VALUES ($(sql_str "$BATCH_ID"), $(sql_str "$db"), 'ok', $((TBL_COUNT * ROWS_PER_TABLE)))
             ON DUPLICATE KEY UPDATE status='ok', rows_inserted=VALUES(rows_inserted)" >/dev/null 2>&1 || true
  else
    DBS_FAILED=$((DBS_FAILED + 1))
    FAILED_DBS+=("$db")
    warn "$(leader "$db" 'INSERT FAILED')"
    cont "see ${RUN_LOG}.sql_errors"
    mysql_q "INSERT INTO \`$CONTROL_DB\`.batch_dbs (batch_id, db_name, status, rows_inserted)
             VALUES ($(sql_str "$BATCH_ID"), $(sql_str "$db"), 'failed', 0)
             ON DUPLICATE KEY UPDATE status='failed', rows_inserted=0" >/dev/null 2>&1 || true
  fi

  if [[ $((IDX % PROGRESS_EVERY)) -eq 0 ]]; then
    RATE=$(awk -v i="$IDX" -v s="$(( $(date +%s) - START_EPOCH ))" \
             'BEGIN { printf "%.1f", (s > 0 ? i / s : 0) }')
    val "progress" "$IDX/${#DBS[@]} databases, $ROWS_INSERTED rows, ${RATE} db/s"
  fi
done

sub
if [[ $DBS_FAILED -gt 0 ]]; then
  nok "inserts" "$DBS_OK ok, $DBS_FAILED FAILED"
  for db in "${FAILED_DBS[@]}"; do cont "failed: $db"; done
else
  ok "inserts"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 13  CLOSE THE LEDGER
# ═══════════════════════════════════════════════════════════════════════════

PHASE="ledger"
BINLOG_END="$(binlog_pos)"
val "binlog end" "$BINLOG_END"

STATUS=$([[ $DBS_FAILED -eq 0 ]] && echo 'complete' || echo 'partial')
mysql_q "
  UPDATE \`$CONTROL_DB\`.batches
     SET status=$(sql_str "$STATUS"), finished_at=NOW(), dbs_ok=$DBS_OK,
         dbs_failed=$DBS_FAILED, rows_inserted=$ROWS_INSERTED,
         binlog_end=$(sql_str "$BINLOG_END")
   WHERE batch_id=$(sql_str "$BATCH_ID")" >/dev/null \
  || die "CRITICAL: the inserts SUCCEEDED but the ledger row was not closed" \
         "set status/binlog_end for batch $BATCH_ID in $CONTROL_DB.batches by hand," \
         "or the restore comparison will read this batch as aborted"
LEDGER_OPEN=0
ok "ledger closed"

# ═══════════════════════════════════════════════════════════════════════════
# PART 14  SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

PHASE="done"
trap - ERR INT TERM

emit ""
banner " BATCH $STATUS  $BATCH_ID"
kv "databases"     "$DBS_OK ok, $DBS_FAILED failed, of ${#DBS[@]}"
kv "rows inserted" "$ROWS_INSERTED"
kv "binlog span"   "$BINLOG_START  ->  $BINLOG_END"
kv "duration"      "$(elapsed "$START_EPOCH")"
kv "warnings"      "$WARN_COUNT"
kv "run log"       "$RUN_LOG"
sub

# A batch that outlasts the cron interval means the next one is being skipped
# by the lock, which silently thins the test traffic.
DUR=$(( $(date +%s) - START_EPOCH ))
if [[ $DUR -gt 840 ]]; then
  emit " this batch took $(elapsed "$START_EPOCH") — close to or past the 15 minute"
  emit " cron interval. Lower --rows, or the next batches will be skipped."
fi

banner " RESULT $STATUS batch=$BATCH_ID ok=$DBS_OK failed=$DBS_FAILED rows=$ROWS_INSERTED dur_s=$DUR warn=$WARN_COUNT"
[[ $DBS_FAILED -eq 0 ]] || exit 1
exit 0
