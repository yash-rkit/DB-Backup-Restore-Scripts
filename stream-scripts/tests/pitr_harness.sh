#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# pitr_snapshot.sh / pitr_writer.sh / pitr_compare.sh test harness
#
# Drives all three PITR test scripts against a stub `mysql` binary, so the SQL
# they generate, their chunking arithmetic and their control flow can be
# exercised WITHOUT a MySQL instance. The stub parses the SQL it is handed and
# answers from a fake catalogue of databases, which is what makes a broken
# UNION ALL or an off-by-one chunk boundary fail here instead of on the server.
#
#   ./tests/pitr_harness.sh          # all scenarios
#   ./tests/pitr_harness.sh 4        # one scenario by number
#   KEEP=1 ./tests/pitr_harness.sh   # keep the sandbox for inspection
#
# Exit 0 = every scenario reached its expected outcome.
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAP="${SCRIPT_DIR}/pitr_snapshot.sh"
WRITER="${SCRIPT_DIR}/pitr_writer.sh"
CMP="${SCRIPT_DIR}/pitr_compare.sh"
for f in "$SNAP" "$WRITER" "$CMP"; do
  [[ -f "$f" ]] || { echo "cannot find $(basename "$f") next to tests/"; exit 1; }
done

H="$(mktemp -d)"; export HARNESS="$H"
cleanup() { if [[ "${KEEP:-0}" == "1" ]]; then echo "sandbox kept: $H"; else rm -rf "$H"; fi; }
trap cleanup EXIT

PASS=0; FAIL=0
ok()    { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
head_() { printf '\n== %s\n' "$1"; }

mkdir -p "$H"/bin "$H"/state "$H"/out "$H"/var/log/pitr_test \
         "$H"/var/lib/dbvault "$H"/var/lock
cd "$H"

# ─── the fake catalogue: 7 databases with both tables, 2 with only one ────
printf 'appdb01\nappdb02\nappdb03\nappdb04\nappdb05\nappdb06\nappdb07\n' > state/dbs_both
printf 'halfdb01\nhalfdb02\n' > state/dbs_partial
: > state/sql_seen          # every statement the stub was handed
: > state/inserts           # one line per INSERT the writer issued
echo 0 > state/seq_max

# ═══════════════════════════════════════════════════════════════════════════
# THE STUB
#
# Answers from state/. STUB_ROWS sets the per-table row count it reports,
# STUB_DROP names a db.table to pretend does not exist, STUB_FAIL_DB names a
# database whose INSERT should fail, STUB_POS overrides the binlog position.
# ═══════════════════════════════════════════════════════════════════════════
cat > bin/mysql <<'STUB'
#!/bin/bash
Q=""; MODE="file"
prev=""
for a in "$@"; do
  case "$prev" in -NBe|-e) Q="$a"; MODE="inline" ;; esac
  case "$a" in -NBe|-e) prev="$a"; continue ;; esac
  prev="$a"
done
[[ "$MODE" == "file" ]] && Q="$(cat)"
printf '%s\n===\n' "$Q" >> "$HARNESS/state/sql_seen"

R="${STUB_ROWS:-2000}"
POS="${STUB_POS:-binlog.001600:4321}"

# --- scalar probes -------------------------------------------------------
case "$Q" in
  "SELECT 1")                 echo 1; exit 0 ;;
  "SELECT @@binlog_format")   echo "${STUB_FORMAT:-ROW}"; exit 0 ;;
  "SELECT @@log_bin")         echo "${STUB_LOGBIN:-1}"; exit 0 ;;
  "SELECT VERSION()")         echo "8.0.36-stub"; exit 0 ;;
esac
case "$Q" in
  *"SHOW BINARY LOG STATUS"*) printf '%s\t%s\n' "${POS%%:*}" "${POS##*:}"; exit 0 ;;
  *"SHOW MASTER STATUS"*)     printf '%s\t%s\n' "${POS%%:*}" "${POS##*:}"; exit 0 ;;
esac

# --- discovery ----------------------------------------------------------
if [[ "$Q" == *"information_schema.TABLES"* ]]; then
  cat "$HARNESS/state/dbs_both"
  exit 0
fi

# --- the numbers table --------------------------------------------------
# Matched on text unique to each seq statement. A looser pattern such as
# *"INSERT INTO"*".seq"* also swallows the writer's real per-database inserts,
# because those select FROM `pitr_test`.`seq` and so contain ".seq" as well.
if [[ "$Q" == *"IFNULL(MAX(n),0)"* ]]; then cat "$HARNESS/state/seq_max"; exit 0; fi
if [[ "$Q" == "SELECT COUNT(*) FROM"*seq* ]]; then cat "$HARNESS/state/seq_max"; exit 0; fi
if [[ "$Q" == *"WITH RECURSIVE"* ]]; then
  n=$(printf '%s' "$Q" | grep -o 'n < [0-9]*' | head -1 | awk '{print $3}')
  echo "${n:-1000}" > "$HARNESS/state/seq_max"; exit 0
fi

# --- DDL and ledger writes ----------------------------------------------
case "$Q" in
  CREATE*|*"REPLACE INTO"*batches*|*"UPDATE "*batches*|*"INSERT INTO"*batch_dbs*)
    exit 0 ;;
esac

# --- the writer's per-database INSERT block -----------------------------
if [[ "$Q" == *"START TRANSACTION"* ]]; then
  db=$(printf '%s' "$Q" | grep -o 'INSERT INTO `[^`]*`' | head -1 | sed 's/.*`\(.*\)`/\1/')
  printf '%s\n' "$Q" | grep -o 'INSERT INTO `[^`]*`\.`[^`]*`' \
    | sed 's/INSERT INTO //; s/`//g' >> "$HARNESS/state/inserts"
  [[ -n "${STUB_FAIL_DB:-}" && "$db" == "$STUB_FAIL_DB" ]] && {
    echo "ERROR 1146 (42S02): Table '$db.yma01' doesn't exist" >&2; exit 1; }
  exit 0
fi

# --- CHECKSUM TABLE -----------------------------------------------------
if [[ "$Q" == *"CHECKSUM TABLE"* ]]; then
  printf '%s' "$Q" | grep -o '`[^`]*`\.`[^`]*`' | sed 's/`//g' | while read -r t; do
    [[ -n "${STUB_DROP:-}" && "$t" == "$STUB_DROP" ]] && continue
    printf '%s\t%s\n' "$t" "$(printf '%s' "$t" | cksum | awk '{print $1}')"
  done
  exit 0
fi

# --- the per-batch GROUP BY sweep --------------------------------------
if [[ "$Q" == *"GROUP BY"* ]]; then
  printf '%s' "$Q" | grep -o "SELECT '[^']*','[^']*'" \
    | sed "s/SELECT '//; s/','/\t/; s/'//" | while IFS=$'\t' read -r d t; do
      [[ -n "${STUB_DROP:-}" && "$d.$t" == "$STUB_DROP" ]] && continue
      for b in ${STUB_BATCHES:-20260825_1105 20260825_1120}; do
        printf '%s\t%s\t%s\t%s\n' "$d" "$t" "$b" "${STUB_BATCH_ROWS:-1000}"
      done
    done
  exit 0
fi

# --- the COUNT(*) / MAX(pk) sweep --------------------------------------
if [[ "$Q" == *"COUNT(*)"* ]]; then
  printf '%s' "$Q" | grep -o "SELECT '[^']*','[^']*'" \
    | sed "s/SELECT '//; s/','/\t/; s/'//" | while IFS=$'\t' read -r d t; do
      [[ -n "${STUB_DROP:-}" && "$d.$t" == "$STUB_DROP" ]] && continue
      printf '%s\t%s\t%s\t%s\n' "$d" "$t" "$R" "$((R + 490))"
    done
  exit 0
fi

exit 0
STUB

printf '#!/bin/bash\nexit 0\n' > bin/flock
chmod +x bin/*
export PATH="$H/bin:$PATH"

# Point both scripts at the sandbox instead of the real system paths.
sed -e "s#^MYSQL_BIN=.*#MYSQL_BIN=\"$H/bin/mysql\"#" "$SNAP"   > "$H/snap.sh"
sed -e "s#^MYSQL_BIN=.*#MYSQL_BIN=\"$H/bin/mysql\"#" \
    -e "s#^LOG_DIR=.*#LOG_DIR=\"$H/var/log/pitr_test\"#" \
    -e "s#^LOCK_FILE=.*#LOCK_FILE=\"$H/var/lock/pitr_writer.lock\"#" \
    -e "s#^PAUSE_FILE=.*#PAUSE_FILE=\"$H/var/lib/dbvault/pitr_writer.pause\"#" \
    "$WRITER" > "$H/writer.sh"
chmod +x "$H/snap.sh" "$H/writer.sh"

WANT="${1:-all}"
run_it() { [[ "$WANT" == "all" || "$WANT" == "$1" ]]; }

# ═══════════════════════════════════════════════════════════════════════════
# 1  snapshot: a clean point over the whole catalogue
# ═══════════════════════════════════════════════════════════════════════════
if run_it 1; then
head_ "1  snapshot on a quiet server"
: > state/sql_seen
"$H/snap.sh" --out out/s1.tsv --label baseline > out/s1.log 2>&1
RC=$?
[[ $RC -eq 0 ]] && ok "exit 0 on a quiet server" || bad "expected exit 0, got $RC"
grep -q '^# quiet_during_scan=yes' out/s1.tsv \
  && ok "recorded as a clean point" || bad "clean point not recorded"
# 7 databases x 2 tables
T=$(grep -c '^T' out/s1.tsv)
[[ "$T" -eq 14 ]] && ok "14 T records (7 dbs x 2 tables)" || bad "expected 14 T records, got $T"
B=$(grep -c '^B' out/s1.tsv)
[[ "$B" -eq 28 ]] && ok "28 B records (14 tables x 2 batches)" || bad "expected 28 B records, got $B"
# Every T record must carry a checksum, not the "-" placeholder.
if grep '^T' out/s1.tsv | awk -F'\t' '$6 == "-"' | grep -q .; then
  bad "some T records lost their checksum in the join"
else
  ok "every T record carries a checksum"
fi
grep -q '^# total_rows=28000' out/s1.tsv \
  && ok "total_rows summed correctly" || bad "total_rows wrong: $(grep '^# total_rows' out/s1.tsv)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 2  snapshot: --no-checksum must still emit T records
#
# The regression that motivated this scenario: an empty checksum file made
# awk's NR == FNR true for the COUNTS file, and the snapshot came out with no
# T records at all while still exiting 0.
# ═══════════════════════════════════════════════════════════════════════════
if run_it 2; then
head_ "2  snapshot with --no-checksum"
"$H/snap.sh" --out out/s2.tsv --no-checksum > out/s2.log 2>&1
RC=$?
[[ $RC -eq 0 ]] && ok "exit 0" || bad "expected exit 0, got $RC"
T=$(grep -c '^T' out/s2.tsv)
[[ "$T" -eq 14 ]] && ok "14 T records survive an empty checksum file" \
                  || bad "expected 14 T records, got $T (the empty-first-file bug)"
if grep '^T' out/s2.tsv | awk -F'\t' '$6 != "-"' | grep -q .; then
  bad "checksums appeared despite --no-checksum"
else
  ok "checksum column is the placeholder"
fi
grep -q '^# checksums=no' out/s2.tsv && ok "header records checksums=no" || bad "header wrong"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 3  snapshot: writes landing during the scan is refused as an expected state
# ═══════════════════════════════════════════════════════════════════════════
if run_it 3; then
head_ "3  snapshot while the server is being written to"
# A stub that reports a DIFFERENT position on each call, which is what a server
# taking writes looks like to the two reads bracketing the scan.
cat > bin/mysql2 <<'STUB3'
#!/bin/bash
Q=""; prev=""
for a in "$@"; do case "$prev" in -NBe|-e) Q="$a";; esac; case "$a" in -NBe|-e) prev="$a"; continue;; esac; prev="$a"; done
if [[ "$Q" == *"BINARY LOG STATUS"* || "$Q" == *"MASTER STATUS"* ]]; then
  n=$(cat "$HARNESS/state/poscount" 2>/dev/null || echo 0); echo $((n+1)) > "$HARNESS/state/poscount"
  printf 'binlog.001600\t%s\n' "$((1000 + n * 500))"; exit 0
fi
exec "$HARNESS/bin/mysql" "$@"
STUB3
chmod +x bin/mysql2
sed -e "s#^MYSQL_BIN=.*#MYSQL_BIN=\"$H/bin/mysql2\"#" "$SNAP" > "$H/snap2.sh"
chmod +x "$H/snap2.sh"
echo 0 > state/poscount
"$H/snap2.sh" --out out/s3b.tsv --no-checksum --no-batches > out/s3b.log 2>&1
RC=$?
[[ $RC -eq 2 ]] && ok "exit 2 when the position moved mid-scan" \
               || bad "expected exit 2, got $RC"
grep -q '^# quiet_during_scan=no' out/s3b.tsv \
  && ok "recorded quiet_during_scan=no" || bad "did not record the moving position"
grep -q 'NOT a clean point' out/s3b.log \
  && ok "said so in the summary" || bad "summary did not warn"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 4  writer: the SQL it generates, over every database
# ═══════════════════════════════════════════════════════════════════════════
if run_it 4; then
head_ "4  writer over the whole catalogue"
: > state/inserts; : > state/sql_seen; echo 0 > state/seq_max
"$H/writer.sh" --rows 1000 > out/w4.log 2>&1
RC=$?
[[ $RC -eq 0 ]] && ok "exit 0" || bad "expected exit 0, got $RC"
I=$(wc -l < state/inserts)
[[ "$I" -eq 14 ]] && ok "14 INSERTs (7 dbs x 2 tables)" || bad "expected 14 INSERTs, got $I"
# Each database must be one transaction, not one per table.
TX=$(grep -c 'START TRANSACTION' state/sql_seen)
[[ "$TX" -eq 7 ]] && ok "one transaction per database" || bad "expected 7 transactions, got $TX"
grep -q 'PITRTEST-' state/sql_seen && ok "rows carry the marker" || bad "marker missing from the SQL"
grep -q 'LPAD(n, 6' state/sql_seen && ok "row labels are sequence-numbered" || bad "no LPAD in the SQL"
grep -q "batch complete\|BATCH complete" out/w4.log && ok "reported the batch complete" \
  || bad "no completion banner: $(tail -3 out/w4.log | tr '\n' ' ')"
grep -q 'rows inserted.*14000' out/w4.log && ok "counted 14000 rows" \
  || bad "row count wrong: $(grep 'rows inserted' out/w4.log)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 5  writer: one database fails, the rest of the batch still lands
# ═══════════════════════════════════════════════════════════════════════════
if run_it 5; then
head_ "5  writer with one failing database"
: > state/inserts; : > state/sql_seen; echo 1000 > state/seq_max
STUB_FAIL_DB=appdb04 "$H/writer.sh" --rows 1000 > out/w5.log 2>&1
RC=$?
[[ $RC -eq 1 ]] && ok "exit 1 on a partial batch" || bad "expected exit 1, got $RC"
grep -q 'appdb04.*INSERT FAILED' out/w5.log \
  && ok "named the failing database" || bad "did not name appdb04"
grep -q 'ok, 1 failed' out/w5.log \
  && ok "counted 6 ok and 1 failed" || bad "tally wrong: $(grep 'databases' out/w5.log | head -2 | tr '\n' ' ')"
grep -q 'partial' out/w5.log && ok "marked the batch partial" || bad "not marked partial"
# The failure must not stop the databases after it.
grep -q 'appdb07' state/inserts && ok "kept going past the failure" \
  || bad "the batch stopped at the failing database"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 6  writer: pause and resume
# ═══════════════════════════════════════════════════════════════════════════
if run_it 6; then
head_ "6  writer pause switch"
"$H/writer.sh" --pause > out/w6a.log 2>&1
: > state/inserts
"$H/writer.sh" --rows 10 > out/w6b.log 2>&1
RC=$?
[[ $RC -eq 0 ]] && ok "a paused run exits 0" || bad "expected exit 0, got $RC"
[[ ! -s state/inserts ]] && ok "wrote nothing while paused" \
  || bad "inserted despite being paused"
grep -q 'paused since' out/w6b.log && ok "said why it skipped" || bad "no pause message"
"$H/writer.sh" --resume > out/w6c.log 2>&1
"$H/writer.sh" --rows 10 > out/w6d.log 2>&1
[[ -s state/inserts ]] && ok "resumed and wrote again" || bad "still paused after --resume"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 7  writer: --dry-run and --limit touch nothing
# ═══════════════════════════════════════════════════════════════════════════
if run_it 7; then
head_ "7  writer --dry-run and --limit"
: > state/inserts
"$H/writer.sh" --dry-run --rows 500 > out/w7.log 2>&1
RC=$?
[[ $RC -eq 0 ]] && ok "--dry-run exits 0" || bad "expected exit 0, got $RC"
[[ ! -s state/inserts ]] && ok "--dry-run wrote nothing" || bad "--dry-run inserted rows"
grep -q 'rows.*: 7000' out/w7.log && ok "planned 7000 rows" \
  || bad "plan wrong: $(grep -i 'rows' out/w7.log | tail -2 | tr '\n' ' ')"
: > state/inserts
"$H/writer.sh" --limit 3 --rows 100 > out/w7b.log 2>&1
I=$(wc -l < state/inserts)
[[ "$I" -eq 6 ]] && ok "--limit 3 wrote 6 INSERTs" || bad "expected 6 INSERTs, got $I"
grep -q 'not the full set' out/w7b.log \
  && ok "warned that --limit narrowed the scope" || bad "no --limit warning"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 8  writer: refuses a server with the binlog off, warns on STATEMENT
# ═══════════════════════════════════════════════════════════════════════════
if run_it 8; then
head_ "8  writer pre-flight"
STUB_LOGBIN=0 "$H/writer.sh" --rows 10 > out/w8.log 2>&1
RC=$?
[[ $RC -eq 1 ]] && ok "exit 1 when log_bin is off" || bad "expected exit 1, got $RC"
grep -q 'log_bin is OFF' out/w8.log && ok "named the reason" || bad "did not name log_bin"
: > state/inserts
STUB_FORMAT=STATEMENT "$H/writer.sh" --rows 10 > out/w8b.log 2>&1
RC=$?
[[ $RC -eq 0 ]] && ok "STATEMENT warns but proceeds" || bad "expected exit 0, got $RC"
grep -q 'this test assumes ROW' out/w8b.log \
  && ok "warned about binlog_format" || bad "no binlog_format warning"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 9  end to end: snapshot, write a batch, snapshot, compare
# ═══════════════════════════════════════════════════════════════════════════
if run_it 9; then
head_ "9  snapshot -> compare, end to end"
STUB_ROWS=2000 "$H/snap.sh" --out out/e_expected.tsv --label frozen > out/e1.log 2>&1
STUB_ROWS=2000 "$H/snap.sh" --out out/e_actual.tsv   --label restored > out/e2.log 2>&1
"$CMP" out/e_expected.tsv out/e_actual.tsv > out/e_cmp.log 2>&1
RC=$?
[[ $RC -eq 0 ]] && ok "identical snapshots compare equal" || bad "expected exit 0, got $RC"
grep -q 'MATCH' out/e_cmp.log && ok "reported MATCH" || bad "no MATCH banner"

# A restore that fell behind: fewer rows and one batch short.
STUB_ROWS=1000 STUB_BATCHES="20260825_1105" \
  "$H/snap.sh" --out out/e_behind.tsv --label restored > out/e3.log 2>&1
"$CMP" out/e_expected.tsv out/e_behind.tsv > out/e_cmp2.log 2>&1
RC=$?
[[ $RC -eq 1 ]] && ok "a short restore compares unequal" || bad "expected exit 1, got $RC"
grep -q 'is BEHIND the expected state' out/e_cmp2.log \
  && ok "diagnosed the restore as behind" || bad "did not diagnose the direction"
grep -q '20260825_1120' out/e_cmp2.log \
  && ok "named the missing batch id" || bad "did not name the missing batch"

# A table missing from the restore entirely.
STUB_ROWS=2000 STUB_DROP="appdb03.ymp01" \
  "$H/snap.sh" --out out/e_dropped.tsv --label restored > out/e4.log 2>&1
"$CMP" out/e_expected.tsv out/e_dropped.tsv > out/e_cmp3.log 2>&1
RC=$?
[[ $RC -eq 1 ]] && ok "a missing table compares unequal" || bad "expected exit 1, got $RC"
grep -q 'appdb03.ymp01' out/e_cmp3.log \
  && ok "named the missing table" || bad "did not name appdb03.ymp01"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 10  compare: refuses to judge against a snapshot that was not a clean point
# ═══════════════════════════════════════════════════════════════════════════
if run_it 10; then
head_ "10  compare refuses a dirty expected file"
# Runnable on its own, so it takes its own snapshot rather than relying on 9.
[[ -f out/e_expected.tsv ]] \
  || STUB_ROWS=2000 "$H/snap.sh" --out out/e_expected.tsv --label frozen >/dev/null 2>&1
sed 's/^# quiet_during_scan=yes/# quiet_during_scan=no/' out/e_expected.tsv > out/e_dirty.tsv
"$CMP" out/e_dirty.tsv out/e_expected.tsv > out/e_cmp4.log 2>&1
RC=$?
[[ $RC -eq 2 ]] && ok "exit 2 rather than a verdict" || bad "expected exit 2, got $RC"
grep -q 'not a clean point' out/e_cmp4.log && ok "explained why" || bad "no explanation"
fi

# ═══════════════════════════════════════════════════════════════════════════
printf '\n%s\n' '=============================================================='
printf ' %d passed, %d failed\n' "$PASS" "$FAIL"
printf '%s\n' '=============================================================='
[[ $FAIL -eq 0 ]] || exit 1
exit 0
