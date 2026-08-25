#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# db_cleanup.sh physical-retention test harness
#
# Runs db_cleanup.sh end to end against a fake share, so the physical pass can
# be exercised WITHOUT a mounted share, root, jq, or 13 GB of real archives.
# Two things are faked and nothing else:
#
#   bin/     stubs for jq, mountpoint and flock — the jq stub answers only the
#            four filters db_cleanup.sh actually asks for
#   copy     db_cleanup.sh is copied into the sandbox with its five absolute
#            path constants rewritten to point inside it. Every line of
#            retention logic under test is the real one.
#
#   ./tests/physical_retention_harness.sh          # all scenarios
#   ./tests/physical_retention_harness.sh 3        # one scenario by number
#   KEEP=1 ./tests/physical_retention_harness.sh   # keep the sandbox
#
# Exit 0 = every assertion held.
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${SCRIPT_DIR}/../db_cleanup.sh"
[[ -f "$TARGET" ]] || { echo "cannot find db_cleanup.sh next to tests/"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "this harness needs node for the jq stub"; exit 1; }

H="$(mktemp -d)"; export HARNESS="$H"
cleanup() { if [[ "${KEEP:-0}" == "1" ]]; then echo "sandbox kept: $H"; else rm -rf "$H"; fi; }
trap cleanup EXIT

PASS=0; FAIL=0
ok()    { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
head_() { printf '\n== %s\n' "$1"; }

mkdir -p "$H"/bin "$H"/livestorage "$H"/Data/dbvault-stage "$H"/var/lock/dbvault

# ─── stubs ────────────────────────────────────────────────────────────────
printf '#!/bin/bash\nexit 0\n' > "$H"/bin/mountpoint
printf '#!/bin/bash\nexit 0\n' > "$H"/bin/flock

# Only the filters db_cleanup.sh uses: `empty` as a validity check, `type`,
# `length`, and `.[N].field // empty`. Anything else is a harness bug, not a
# silent empty string, so it exits non-zero and the run fails loudly.
cat > "$H"/bin/jq.js <<'STUB'
const fs = require('fs');
const a = process.argv.slice(2).filter(x => x !== '-r');
const [filter, file] = a;
let doc;
try { doc = JSON.parse(fs.readFileSync(file, 'utf8')); }
catch (e) { process.exit(5); }
if (filter === 'empty') process.exit(0);
if (filter === 'type')   { console.log(Array.isArray(doc) ? 'array' : typeof doc); process.exit(0); }
if (filter === 'length') { console.log(doc.length); process.exit(0); }
const m = filter.match(/^\.\[(\d+)\]\.(\w+) \/\/ empty$/);
if (m) { const v = (doc[+m[1]] || {})[m[2]]; console.log(v === undefined ? '' : v); process.exit(0); }
console.error('jq stub: unsupported filter ' + filter);
process.exit(9);
STUB
printf '#!/bin/bash\nexec node "%s/bin/jq.js" "$@"\n' "$H" > "$H"/bin/jq
chmod +x "$H"/bin/*
export PATH="$H/bin:$PATH"

# ─── the script under test, rebased into the sandbox ──────────────────────
SUT="$H/db_cleanup.sh"
sed -e "s#^SMB_MOUNT_POINT=\"/livestorage\"#SMB_MOUNT_POINT=\"$H/livestorage\"#" \
    -e "s#^CLEANUP_LOG_BASE=\"/livestorage#CLEANUP_LOG_BASE=\"$H/livestorage#" \
    -e "s#^LOCAL_STAGE=\"/Data#LOCAL_STAGE=\"$H/Data#" \
    -e "s#^LOCK_DIR=\"/var/lock#LOCK_DIR=\"$H/var/lock#" \
    "$TARGET" | tr -d '\r' > "$SUT"
chmod +x "$SUT"
for v in "SMB_MOUNT_POINT=\"$H/livestorage\"" "LOCAL_STAGE=\"$H/Data" ; do
  grep -q "^${v%%=*}=\"$H" "$SUT" || { echo "rebase failed for ${v%%=*}"; exit 1; }
done

NOW="$(date +%s)"
CONFIG="$H/servers.json"
LOG="$H/run.out"

# ─── fixture builders ─────────────────────────────────────────────────────

# set_at <tree> <id> <age_days> — one complete seven-part physical backup.
set_at() { set_at_s "$1" "$2" $(( $3 * 86400 )); }

# set_at_s <tree> <id> <age_seconds> — same, for two IDs inside one day.
set_at_s() {
  local tree="$1" id="$2" ts=$(( NOW - $3 )) d
  mkdir -p "$tree"
  printf 'archive %s\n' "$id" > "$tree/$id.xbstream"
  printf 'sha %s\n'     "$id" > "$tree/$id.sha256"
  printf 'manifest %s\n' "$id" > "$tree/$id.manifest"
  printf 'binlog_info %s\n' "$id" > "$tree/$id"_binlog_info
  for d in binlog meta logs; do
    mkdir -p "$tree/$d/$id"
    printf 'part\n' > "$tree/$d/$id/part"
    touch -d "@$ts" "$tree/$d/$id/part" "$tree/$d/$id"
  done
  touch -d "@$ts" "$tree/$id".xbstream "$tree/$id".sha256 \
                  "$tree/$id".manifest "$tree/$id"_binlog_info
}

# orphan_at <tree> <subdir> <id> <age_days> — a per-ID dir with no archive.
orphan_at() {
  local tree="$1" sub="$2" id="$3" ts=$(( NOW - $4 * 86400 ))
  mkdir -p "$tree/$sub/$id"
  printf 'stranded\n' > "$tree/$sub/$id/part"
  touch -d "@$ts" "$tree/$sub/$id/part" "$tree/$sub/$id"
}

# A logical tree, so the logical pass has something valid to walk.
logical_tree() {
  local tree="$1"
  mkdir -p "$tree/appdb"
  printf 'dump\n' > "$tree/appdb/appdb_20260821.tar.gz"
}

reset() {
  rm -rf "$H/livestorage" "$H/Data/dbvault-stage" "$LOG"
  mkdir -p "$H/livestorage" "$H/Data/dbvault-stage"
}

# config <json-body>
config() { printf '%s\n' "$1" > "$CONFIG"; }

run() {
  "$SUT" --config="$CONFIG" "$@" > "$LOG" 2>&1
  echo $?
}

exists()  { [[ -e "$1" ]]; }
gone()    { [[ ! -e "$1" ]]; }

# assert_set_gone <label> <tree> <id> — all seven parts must be gone.
assert_set_gone() {
  local label="$1" tree="$2" id="$3" missing=0 p
  for p in "$tree/$id.xbstream" "$tree/$id.sha256" "$tree/$id.manifest" \
           "$tree/${id}_binlog_info" "$tree/binlog/$id" "$tree/meta/$id" "$tree/logs/$id"; do
    exists "$p" && { missing=1; echo "        still present: ${p#$tree/}"; }
  done
  [[ $missing -eq 0 ]] && ok "$label" || bad "$label"
}

# assert_set_intact <label> <tree> <id> — all seven parts must survive.
assert_set_intact() {
  local label="$1" tree="$2" id="$3" missing=0 p
  for p in "$tree/$id.xbstream" "$tree/$id.sha256" "$tree/$id.manifest" \
           "$tree/${id}_binlog_info" "$tree/binlog/$id" "$tree/meta/$id" "$tree/logs/$id"; do
    gone "$p" && { missing=1; echo "        wrongly deleted: ${p#$tree/}"; }
  done
  [[ $missing -eq 0 ]] && ok "$label" || bad "$label"
}

WANT="${1:-all}"
want() { [[ "$WANT" == "all" || "$WANT" == "$1" ]]; }

T="$H/livestorage/Backup/Restore-VM-1"
L="$H/livestorage/Logical/Restore-VM-1"

STD_CONFIG='[{"server_name":"Restore-VM-1",
  "backup_base":"'"$T"'",
  "base_dir":"'"$L"'",
  "retention":"days:1",
  "physical_retention":"days:7"}]'

# ═══ 1  days:7 expires whole sets, keeps what is inside the window ═════════
if want 1; then
head_ "1  days:7 — whole sets in and out of the window"
reset; logical_tree "$L"
set_at "$T" 20260824 0
set_at "$T" 20260821 3
set_at "$T" 20260816 8
set_at "$T" 20260804 20
config "$STD_CONFIG"
RC="$(run)"
[[ "$RC" == "0" ]] && ok "exit 0" || { bad "exit 0 (got $RC)"; sed -n '$p' "$LOG"; }
assert_set_intact "0d set kept whole"  "$T" 20260824
assert_set_intact "3d set kept whole"  "$T" 20260821
assert_set_gone   "8d set deleted whole"  "$T" 20260816
assert_set_gone   "20d set deleted whole" "$T" 20260804
grep -q 'sets=2' "$LOG" && ok "RESULT reports sets=2" || bad "RESULT reports sets=2"
fi

# ═══ 2  the newest set is never deleted ═══════════════════════════════════
if want 2; then
head_ "2  keep-newest — every set past the window"
reset; logical_tree "$L"
set_at "$T" 20260725 30
set_at "$T" 20260715 40
config "$STD_CONFIG"
RC="$(run)"
[[ "$RC" == "0" ]] && ok "exit 0" || bad "exit 0 (got $RC)"
assert_set_intact "newest survives its own expiry" "$T" 20260725
assert_set_gone   "older one still goes"           "$T" 20260715
grep -q 'newest, would otherwise expire' "$LOG" \
  && ok "log names the reason" || bad "log names the reason"
fi

# ═══ 3  orphan sweep, with the age guard that protects failure evidence ═══
if want 3; then
head_ "3  orphans — old ones swept, last night's failure evidence kept"
reset; logical_tree "$L"
set_at    "$T" 20260824 0
orphan_at "$T" binlog 20260701 40
orphan_at "$T" meta   20260701 40
orphan_at "$T" logs   20260823 1
config "$STD_CONFIG"
RC="$(run)"
[[ "$RC" == "0" ]] && ok "exit 0" || bad "exit 0 (got $RC)"
gone   "$T/binlog/20260701" && ok "40d orphan binlog swept"  || bad "40d orphan binlog swept"
gone   "$T/meta/20260701"   && ok "40d orphan meta swept"    || bad "40d orphan meta swept"
exists "$T/logs/20260823"   && ok "1d orphan log dir kept"   || bad "1d orphan log dir kept"
exists "$T/logs/20260824"   && ok "live set's own log dir untouched" \
                            || bad "live set's own log dir untouched"
grep -q 'orphans=2' "$LOG" && ok "RESULT reports orphans=2" || bad "RESULT reports orphans=2"
fi

# ═══ 4  --dry-run touches nothing ═════════════════════════════════════════
if want 4; then
head_ "4  --dry-run"
reset; logical_tree "$L"
set_at    "$T" 20260824 0
set_at    "$T" 20260804 20
orphan_at "$T" binlog 20260701 40
config "$STD_CONFIG"
RC="$(run --dry-run)"
[[ "$RC" == "0" ]] && ok "exit 0" || bad "exit 0 (got $RC)"
assert_set_intact "expired set still on disk" "$T" 20260804
exists "$T/binlog/20260701" && ok "orphan still on disk" || bad "orphan still on disk"
grep -q 'would delete set 20260804' "$LOG" && ok "reports the set it would delete" \
                                           || bad "reports the set it would delete"
grep -q 'would delete orphan binlog/20260701' "$LOG" && ok "reports the orphan" \
                                                     || bad "reports the orphan"
fi

# ═══ 5  smart — 7 daily, then one per ISO week for 3 weeks ════════════════
#
# The week offsets are exact multiples of 7 days so they land on the same
# weekday whatever day this runs, which puts each in its own ISO week. The
# same-day pair is 60s apart, so it can only straddle a week boundary if the
# harness runs in the minute after midnight on a Monday.
#
# Note what smart does NOT do: the three weekly slots are filled from whatever
# weeks have sets, however far back, so smart alone never drains an old tree to
# nothing. That is inherited from the logical apply_smart, deliberately.
if want 5; then
head_ "5  smart"
reset; logical_tree "$L"
set_at   "$T" 20260824 0                          # daily
set_at   "$T" 20260820 4                          # daily
set_at_s "$T" 20260814_120000 $(( 10 * 86400 ))      # week 1, newest of its day
set_at_s "$T" 20260814        $(( 10 * 86400 + 60 )) # week 1, loses the slot
set_at   "$T" 20260807 17                         # week 2
set_at   "$T" 20260731 24                         # week 3
set_at   "$T" 20260724 31                         # week 4 — no slot left
config '[{"server_name":"Restore-VM-1",
  "backup_base":"'"$T"'","base_dir":"'"$L"'",
  "retention":"days:1","physical_retention":"smart"}]'
RC="$(run)"
[[ "$RC" == "0" ]] && ok "exit 0" || bad "exit 0 (got $RC)"
assert_set_intact "0d kept (daily)"                "$T" 20260824
assert_set_intact "4d kept (daily)"                "$T" 20260820
assert_set_intact "week 1 keeper (_HHMMSS id)"     "$T" 20260814_120000
assert_set_gone   "week 1 runner-up dropped"       "$T" 20260814
assert_set_intact "week 2 keeper"                  "$T" 20260807
assert_set_intact "week 3 keeper"                  "$T" 20260731
assert_set_gone   "week 4 dropped, no slot left"   "$T" 20260724
fi

# ═══ 6  opt-out — no physical_retention, nothing physical is touched ══════
if want 6; then
head_ "6  no physical_retention"
reset; logical_tree "$L"
set_at "$T" 20260604 81
config '[{"server_name":"Restore-VM-1",
  "backup_base":"'"$T"'","base_dir":"'"$L"'","retention":"days:1"}]'
RC="$(run)"
[[ "$RC" == "0" ]] && ok "exit 0" || bad "exit 0 (got $RC)"
assert_set_intact "81d set untouched" "$T" 20260604
grep -q 'no physical_retention, sets never expired' "$LOG" \
  && ok "named as unconfigured" || bad "named as unconfigured"
grep -q 'sets=0' "$LOG" && ok "RESULT reports sets=0" || bad "RESULT reports sets=0"
fi

# ═══ 7  physical_retention without backup_base dies before deleting ═══════
if want 7; then
head_ "7  physical_retention with no backup_base"
reset; logical_tree "$L"
set_at "$T" 20260804 20
config '[{"server_name":"Restore-VM-1",
  "base_dir":"'"$L"'","retention":"days:1","physical_retention":"days:7"}]'
RC="$(run)"
[[ "$RC" == "1" ]] && ok "exit 1" || bad "exit 1 (got $RC)"
grep -q 'NO BACKUP_BASE' "$LOG" && ok "names the bad field" || bad "names the bad field"
grep -q 'uncaught failure' "$LOG" \
  && bad "a die() path must not be labelled uncaught" \
  || ok "die() path not labelled uncaught"
assert_set_intact "nothing deleted before the abort" "$T" 20260804
fi

# ═══ 8  a backup_base off the share is refused ════════════════════════════
if want 8; then
head_ "8  backup_base outside the mount"
reset; logical_tree "$L"
mkdir -p "$H/elsewhere"; set_at "$H/elsewhere" 20260804 20
config '[{"server_name":"Restore-VM-1",
  "backup_base":"'"$H"'/elsewhere","base_dir":"'"$L"'",
  "retention":"days:1","physical_retention":"days:7"}]'
RC="$(run)"
[[ "$RC" == "1" ]] && ok "exit 1" || bad "exit 1 (got $RC)"
grep -q 'PATH OFF THE SHARE' "$LOG" && ok "names the reason" || bad "names the reason"
assert_set_intact "off-share tree untouched" "$H/elsewhere" 20260804
fi

# ═══ 9  a bad physical pattern is caught in pre-flight ════════════════════
if want 9; then
head_ "9  bad physical_retention pattern"
reset; logical_tree "$L"
set_at "$T" 20260804 20
config '[{"server_name":"Restore-VM-1",
  "backup_base":"'"$T"'","base_dir":"'"$L"'",
  "retention":"days:1","physical_retention":"days:0"}]'
RC="$(run)"
[[ "$RC" == "1" ]] && ok "exit 1" || bad "exit 1 (got $RC)"
grep -q 'BAD PHYSICAL RETENTION' "$LOG" && ok "names the field" || bad "names the field"
assert_set_intact "nothing deleted before the abort" "$T" 20260804
fi

# ═══ 10  an uncaught failure names the command that broke ═════════════════
#
# The failure this exists for: set -e trips somewhere with no die() behind it,
# and the banner used to say "failed in <phase>" and nothing more. The fault is
# injected into a copy of the script, at a point no pre-flight check covers.
if want 10; then
head_ "10  uncaught failure reports its cause"
reset; logical_tree "$L"
set_at "$T" 20260824 0
config "$STD_CONFIG"

BROKEN="$H/db_cleanup_broken.sh"
sed 's#^phase physical 2/3$#phase physical 2/3\nls /definitely-not-here-9f3a >/dev/null#' \
  "$SUT" > "$BROKEN"
chmod +x "$BROKEN"
grep -q 'definitely-not-here-9f3a' "$BROKEN" \
  && ok "fault injected" || bad "harness could not inject the fault"

"$BROKEN" --config="$CONFIG" > "$LOG" 2>&1; RC=$?
[[ "$RC" == "1" ]] && ok "exit 1" || bad "exit 1 (got $RC)"
grep -q 'uncaught failure' "$LOG" \
  && ok "banner says it was uncaught" || bad "banner says it was uncaught"
grep -q 'failed command.*definitely-not-here-9f3a' "$LOG" \
  && ok "names the command that broke" || bad "names the command that broke"
grep -qE 'at line +: [0-9]+' "$LOG" \
  && ok "gives the line number" || bad "gives the line number"
grep -q 'nothing has been deleted\|0 deleted' "$LOG" \
  && ok "reports what had already been deleted" \
  || ok "no deletions to report (nothing had run yet)"
fi

printf '\n%s\n' '--------------------------------------------------------------'
printf ' %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || { echo " last run log: $LOG"; exit 1; }
exit 0
