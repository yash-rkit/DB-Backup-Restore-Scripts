#!/usr/bin/env bash
#
# stream-scripts/tests/pitr_snapshot.sh — snapshot the PITR test tables
#
# Records, for every database holding both test tables: row count, MAX(pk),
# CHECKSUM TABLE, and the per-batch row counts written by pitr_writer.sh.
# Run it on the SOURCE to capture the expected state, then on the RESTORED
# server, then diff the two files with pitr_compare.sh.
#
#   ./pitr_snapshot.sh --out /tmp/before.tsv --label baseline
#   ./pitr_snapshot.sh --out /tmp/expected.tsv --label frozen
#   ./pitr_snapshot.sh --out /tmp/restored.tsv --no-checksum
#
# The binlog position is captured BEFORE and AFTER the scan. If the two differ
# the server was still being written to and the snapshot is not a clean point
# to compare a restore against — the script says so and exits 2.
#
#   PART 1   configuration
#   PART 2   log engine
#   PART 3   arguments
#   PART 4   probes
#   PART 5   pre-flight
#   PART 6   discovery
#   PART 7   binlog position, before
#   PART 8   row counts
#   PART 9   checksums
#   PART 10  per-batch counts
#   PART 11  binlog position, after
#   PART 12  write the snapshot
#   PART 13  summary
#
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# PART 1  CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

MYSQL_USER="Admin"
MYSQL_PASSWORD=""
MYSQL_BIN="/usr/bin/mysql"

# table : primary key : batch-id column : marker column
TABLE_SPECS=(
  "yma01:A01F01:A01F03:A01X01"
  "ymp01:P01F01:P01F03:P01X01"
)
MARKER="PITRTEST"                 # value pitr_writer.sh puts in the marker column

COUNT_CHUNK=60                    # subqueries per UNION ALL statement
CHECKSUM_CHUNK=100                # tables per CHECKSUM TABLE statement

OUT=""
LABEL="snapshot"
DO_CHECKSUM=1
DO_BATCHES=1

# ═══════════════════════════════════════════════════════════════════════════
# PART 2  LOG ENGINE
#
# Everything human goes to stderr, so --out - and shell redirection stay usable.
# ═══════════════════════════════════════════════════════════════════════════

LOG_RULE='=============================================================='
LOG_SUB='--------------------------------------------------------------'
LOG_DOTS='..............................................................'

emit()   { printf '%s\n' "$1" >&2; }
banner() { emit "$LOG_RULE"; emit "$1"; emit "$LOG_RULE"; }
sub()    { emit "$LOG_SUB"; }
kv()     { emit "$(printf ' %-16s: %s' "$1" "$2")"; }

PHASE="init"
tag()  { printf '[%s]' "$PHASE"; }
info() { emit "$(printf '%s %-5s %-13s %s' "$(date +%T)" 'INFO'  "$(tag)" "$1")"; }
warn() { emit "$(printf '%s %-5s %-13s %s' "$(date +%T)" 'WARN'  "$(tag)" "$1")"; }
erro() { emit "$(printf '%s %-5s %-13s %s' "$(date +%T)" 'ERROR' "$(tag)" "$1")"; }
cont() { emit "$(printf '%-28s %s' '' "$1")"; }

leader() {
  local pad=$(( 40 - ${#1} - ${#2} ))
  (( pad < 3 )) && pad=3
  printf '%s %s %s' "$1" "${LOG_DOTS:0:$pad}" "$2"
}
ok()  { info "$(leader "$1" 'OK')"; }
val() { info "$(leader "$1" "$2")"; }
nok() { warn "$(leader "$1" "$2")"; }

die() { erro "$1"; shift; local l; for l in "$@"; do cont "$l"; done; exit 1; }

START_EPOCH="$(date +%s)"
elapsed() {
  local d=$(( $(date +%s) - $1 ))
  if (( d < 60 )); then printf '%ds' "$d"; else printf '%dm%02ds' $((d / 60)) $((d % 60)); fi
}

# ═══════════════════════════════════════════════════════════════════════════
# PART 3  ARGUMENTS
# ═══════════════════════════════════════════════════════════════════════════

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)          OUT="${2:-}"; shift 2 ;;
    --label)        LABEL="${2:-}"; shift 2 ;;
    --no-checksum)  DO_CHECKSUM=0; shift ;;
    --no-batches)   DO_BATCHES=0; shift ;;
    -h|--help)      sed -n '3,17p' "$0" | cut -c3- >&2; exit 0 ;;
    *)              die "unknown argument: $1" "see --help" ;;
  esac
done

[[ -n "$OUT" ]] || OUT="./pitr_snapshot_$(hostname -s)_$(date +%Y%m%d_%H%M%S).tsv"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ═══════════════════════════════════════════════════════════════════════════
# PART 4  PROBES
# ═══════════════════════════════════════════════════════════════════════════

mysql_q() { "$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -NBe "$1" 2>/dev/null; }
mysql_f() { "$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -NB < "$1" 2>/dev/null; }

# SHOW BINARY LOG STATUS is 8.4+; SHOW MASTER STATUS covers older servers.
binlog_pos() {
  local r
  r=$(mysql_q "SHOW BINARY LOG STATUS" | awk '{print $1":"$2}')
  [[ -n "$r" ]] || r=$(mysql_q "SHOW MASTER STATUS" | awk '{print $1":"$2}')
  printf '%s' "${r:-unknown:0}"
}

# ═══════════════════════════════════════════════════════════════════════════
# PART 5  PRE-FLIGHT
# ═══════════════════════════════════════════════════════════════════════════

PHASE="preflight"
banner " PITR SNAPSHOT  $(hostname -s)  label=$LABEL"

[[ -x "$MYSQL_BIN" ]] || die "mysql client not found at $MYSQL_BIN"
mysql_q "SELECT 1" >/dev/null || die "cannot connect to MySQL as $MYSQL_USER" \
  "check MYSQL_USER / MYSQL_PASSWORD at the top of this script"
ok "mysql reachable"

mkdir -p "$(dirname "$OUT")" 2>/dev/null || die "cannot create $(dirname "$OUT")"
: > "$OUT" || die "cannot write $OUT"
val "output" "$OUT"

# ═══════════════════════════════════════════════════════════════════════════
# PART 6  DISCOVERY
#
# Which databases actually hold BOTH tables. Never assume all of them do — a
# snapshot over a guessed list quietly compares a different set of databases
# on the two servers, and the diff then blames the restore for it.
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
     AND TABLE_SCHEMA NOT IN ('information_schema','mysql','performance_schema','sys')
   GROUP BY TABLE_SCHEMA
  HAVING COUNT(DISTINCT TABLE_NAME) = $TBL_COUNT
   ORDER BY TABLE_SCHEMA")

[[ ${#DBS[@]} -gt 0 ]] || die "no database holds all of: $TBL_LIST" \
  "nothing to snapshot — check the table names in TABLE_SPECS"
val "databases" "${#DBS[@]} holding all $TBL_COUNT test tables"

# ═══════════════════════════════════════════════════════════════════════════
# PART 7  BINLOG POSITION — BEFORE
# ═══════════════════════════════════════════════════════════════════════════

POS_BEFORE="$(binlog_pos)"
val "binlog before" "$POS_BEFORE"

# ═══════════════════════════════════════════════════════════════════════════
# PART 8  ROW COUNTS
#
# One UNION ALL per COUNT_CHUNK tables rather than one query per table: 840
# round trips over a slow link is minutes of pure latency.
# ═══════════════════════════════════════════════════════════════════════════

PHASE="counts"
info "scanning $(( ${#DBS[@]} * TBL_COUNT )) tables for COUNT(*) and MAX(pk)"

: > "$TMP/sql"
N=0
for db in "${DBS[@]}"; do
  for spec in "${TABLE_SPECS[@]}"; do
    IFS=':' read -r t pk _ _ <<< "$spec"
    [[ $((N % COUNT_CHUNK)) -eq 0 ]] || printf ' UNION ALL ' >> "$TMP/sql"
    printf "SELECT '%s','%s',COUNT(*),IFNULL(MAX(\`%s\`),0) FROM \`%s\`.\`%s\`" \
      "$db" "$t" "$pk" "$db" "$t" >> "$TMP/sql"
    N=$((N + 1))
    [[ $((N % COUNT_CHUNK)) -eq 0 ]] && printf ';\n' >> "$TMP/sql"
  done
done
[[ $((N % COUNT_CHUNK)) -eq 0 ]] || printf ';\n' >> "$TMP/sql"

mysql_f "$TMP/sql" > "$TMP/counts.tsv" || die "the COUNT(*) sweep failed" \
  "run it by hand to see the error: $MYSQL_BIN -u$MYSQL_USER -p < $TMP/sql"

GOT=$(wc -l < "$TMP/counts.tsv")
if [[ "$GOT" -ne "$N" ]]; then
  nok "row counts" "$GOT of $N"
  cont "some tables did not report — a permission, or a table dropped mid-scan"
else
  ok "row counts"
fi
TOTAL_ROWS=$(awk -F'\t' '{s+=$3} END {print s+0}' "$TMP/counts.tsv")
val "rows in scope" "$TOTAL_ROWS"

# ═══════════════════════════════════════════════════════════════════════════
# PART 9  CHECKSUMS
#
# Counts can match while contents differ. On InnoDB this is a live full scan,
# so it is the expensive half of the snapshot — --no-checksum skips it.
# ═══════════════════════════════════════════════════════════════════════════

PHASE="checksum"
: > "$TMP/checksums.tsv"
if [[ $DO_CHECKSUM -eq 1 ]]; then
  info "checksumming $N tables"
  : > "$TMP/csql"
  M=0
  for db in "${DBS[@]}"; do
    for spec in "${TABLE_SPECS[@]}"; do
      t="${spec%%:*}"
      if [[ $((M % CHECKSUM_CHUNK)) -eq 0 ]]; then
        [[ $M -eq 0 ]] || printf ';\n' >> "$TMP/csql"
        printf 'CHECKSUM TABLE ' >> "$TMP/csql"
      else
        printf ', ' >> "$TMP/csql"
      fi
      printf '`%s`.`%s`' "$db" "$t" >> "$TMP/csql"
      M=$((M + 1))
    done
  done
  printf ';\n' >> "$TMP/csql"

  mysql_f "$TMP/csql" > "$TMP/checksums.tsv" || die "the CHECKSUM TABLE sweep failed" \
    "run it by hand to see the error: $MYSQL_BIN -u$MYSQL_USER -p < $TMP/csql"
  ok "checksums"
else
  nok "checksums" "SKIPPED (--no-checksum)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 10  PER-BATCH COUNTS
#
# The strongest single signal: which pitr_writer.sh batches landed. A replay
# that stopped mid-stream shows up here as a missing or short batch, which a
# total row count alone can hide.
# ═══════════════════════════════════════════════════════════════════════════

PHASE="batches"
: > "$TMP/batches.tsv"
BATCH_IDS=0
BATCH_ROWS=0
if [[ $DO_BATCHES -eq 1 ]]; then
  info "grouping test rows by batch id"
  : > "$TMP/bsql"
  M=0
  for db in "${DBS[@]}"; do
    for spec in "${TABLE_SPECS[@]}"; do
      IFS=':' read -r t _ bcol mcol <<< "$spec"
      [[ $((M % COUNT_CHUNK)) -eq 0 ]] || printf ' UNION ALL ' >> "$TMP/bsql"
      # Each branch carries its own GROUP BY, so it must be parenthesised.
      printf "(SELECT '%s','%s',\`%s\`,COUNT(*) FROM \`%s\`.\`%s\` WHERE \`%s\`='%s' GROUP BY \`%s\`)" \
        "$db" "$t" "$bcol" "$db" "$t" "$mcol" "$MARKER" "$bcol" >> "$TMP/bsql"
      M=$((M + 1))
      [[ $((M % COUNT_CHUNK)) -eq 0 ]] && printf ';\n' >> "$TMP/bsql"
    done
  done
  [[ $((M % COUNT_CHUNK)) -eq 0 ]] || printf ';\n' >> "$TMP/bsql"

  mysql_f "$TMP/bsql" > "$TMP/batches.tsv" || die "the per-batch sweep failed" \
    "run it by hand to see the error: $MYSQL_BIN -u$MYSQL_USER -p < $TMP/bsql"

  BATCH_IDS=$(awk -F'\t' '{print $3}' "$TMP/batches.tsv" | sort -u | wc -l)
  BATCH_ROWS=$(awk -F'\t' '{s+=$4} END {print s+0}' "$TMP/batches.tsv")
  if [[ "$BATCH_ROWS" -eq 0 ]]; then
    nok "test batches" "NONE FOUND"
    cont "no row carries marker '$MARKER' — pitr_writer.sh has not run here yet"
  else
    val "test batches" "$BATCH_IDS distinct, $BATCH_ROWS rows"
  fi
else
  nok "test batches" "SKIPPED (--no-batches)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 11  BINLOG POSITION — AFTER
#
# A moved position means the server was written to DURING the scan, so the file
# describes no single point in time and no restore can be held to it.
# ═══════════════════════════════════════════════════════════════════════════

PHASE="verify"
POS_AFTER="$(binlog_pos)"
val "binlog after" "$POS_AFTER"

CLEAN=yes
if [[ "$POS_BEFORE" != "$POS_AFTER" ]]; then
  CLEAN=no
  nok "quiet during scan" "NO — position moved"
  cont "writes landed while this snapshot was being taken, so it does not"
  cont "describe one point in time. As an EXPECTED state it is unusable:"
  cont "stop the writers, run binlog_collect.sh once, then snapshot again."
else
  ok "quiet during scan"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 12  WRITE THE SNAPSHOT
# ═══════════════════════════════════════════════════════════════════════════

PHASE="write"
{
  echo "# pitr_snapshot v1"
  echo "# label=$LABEL"
  echo "# host=$(hostname -s)"
  echo "# taken_at=$(date '+%F %T')"
  echo "# server_version=$(mysql_q 'SELECT VERSION()')"
  echo "# databases=${#DBS[@]}"
  echo "# tables=$N"
  echo "# total_rows=$TOTAL_ROWS"
  echo "# batch_ids=$BATCH_IDS"
  echo "# batch_rows=$BATCH_ROWS"
  echo "# binlog_before=$POS_BEFORE"
  echo "# binlog_after=$POS_AFTER"
  echo "# quiet_during_scan=$CLEAN"
  echo "# checksums=$([[ $DO_CHECKSUM -eq 1 ]] && echo yes || echo no)"
  echo "# batches=$([[ $DO_BATCHES -eq 1 ]] && echo yes || echo no)"
  echo "#"
  echo "# T<tab>db<tab>table<tab>rows<tab>max_pk<tab>checksum"
  echo "# B<tab>db<tab>table<tab>batch_id<tab>rows"

  # Join counts to checksums on "db.table", the key CHECKSUM TABLE reports.
  # Sorted so two snapshots diff line for line.
  #
  # Keyed on FILENAME, not the usual NR == FNR: with --no-checksum the first
  # file is EMPTY, awk never opens it, and NR == FNR would then be true while
  # reading the counts — swallowing every row into ck[] and emitting no T
  # records at all.
  awk -F'\t' -v ckfile="$TMP/checksums.tsv" '
    FILENAME == ckfile { ck[$1] = $2; next }
    { key = $1 "." $2
      print "T\t" $1 "\t" $2 "\t" $3 "\t" $4 "\t" (key in ck ? ck[key] : "-") }
  ' "$TMP/checksums.tsv" "$TMP/counts.tsv" | sort

  awk -F'\t' '{ print "B\t" $1 "\t" $2 "\t" $3 "\t" $4 }' "$TMP/batches.tsv" | sort
} > "$OUT"

RECORDS=$(grep -cv '^#' "$OUT" || true)
ok "snapshot written"

# ═══════════════════════════════════════════════════════════════════════════
# PART 13  SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

emit ""
banner " SNAPSHOT COMPLETE  label=$LABEL"
kv "file"        "$OUT"
kv "records"     "$RECORDS"
kv "databases"   "${#DBS[@]}"
kv "tables"      "$N"
kv "rows"        "$TOTAL_ROWS"
kv "batches"     "$BATCH_IDS ($BATCH_ROWS rows)"
kv "binlog"      "$POS_AFTER"
kv "clean point" "$CLEAN"
kv "duration"    "$(elapsed "$START_EPOCH")"
sub

if [[ "$CLEAN" != yes ]]; then
  emit " NOT a clean point — do not use this file as the expected state."
  exit 2
fi
emit " compare two of these with: ./pitr_compare.sh <expected> <actual>"
exit 0
