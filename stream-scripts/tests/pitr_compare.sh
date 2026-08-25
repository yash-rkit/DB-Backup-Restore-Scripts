#!/usr/bin/env bash
#
# stream-scripts/tests/pitr_compare.sh — diff two pitr_snapshot.sh files
#
# Answers one question: did the restored server end up holding exactly what
# the source held at the point the binlogs were collected to?
#
#   ./pitr_compare.sh expected.tsv restored.tsv
#   ./pitr_compare.sh expected.tsv restored.tsv --max-report 50
#
# Exit 0 = identical. Exit 1 = a real difference. Exit 2 = the files cannot be
# compared (different scope, or the expected file was not a clean point).
#
#   PART 1   configuration
#   PART 2   log engine
#   PART 3   arguments
#   PART 4   headers
#   PART 5   scope check
#   PART 6   table-level diff
#   PART 7   batch-level diff
#   PART 8   verdict
#
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# PART 1  CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

MAX_REPORT=25                     # differing lines printed per section

# ═══════════════════════════════════════════════════════════════════════════
# PART 2  LOG ENGINE
# ═══════════════════════════════════════════════════════════════════════════

LOG_RULE='=============================================================='
LOG_SUB='--------------------------------------------------------------'
LOG_DOTS='..............................................................'

emit()   { printf '%s\n' "$1"; }
banner() { emit "$LOG_RULE"; emit "$1"; emit "$LOG_RULE"; }
sub()    { emit "$LOG_SUB"; }
kv()     { emit "$(printf ' %-18s: %s' "$1" "$2")"; }

info() { emit "$(printf ' %-5s %s' 'INFO' "$1")"; }
warn() { emit "$(printf ' %-5s %s' 'WARN' "$1")"; }
erro() { emit "$(printf ' %-5s %s' 'ERROR' "$1")" >&2; }
cont() { emit "$(printf ' %-5s %s' '' "$1")"; }

leader() {
  local pad=$(( 44 - ${#1} - ${#2} ))
  (( pad < 3 )) && pad=3
  printf '%s %s %s' "$1" "${LOG_DOTS:0:$pad}" "$2"
}
ok()  { info "$(leader "$1" 'OK')"; }
val() { info "$(leader "$1" "$2")"; }
nok() { warn "$(leader "$1" "$2")"; }

die() { erro "$1"; shift; local l; for l in "$@"; do cont "$l"; done; exit 2; }

# ═══════════════════════════════════════════════════════════════════════════
# PART 3  ARGUMENTS
# ═══════════════════════════════════════════════════════════════════════════

EXPECTED=""
ACTUAL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-report) MAX_REPORT="${2:-25}"; shift 2 ;;
    -h|--help)    sed -n '3,13p' "$0" | cut -c3-; exit 0 ;;
    -*)           die "unknown argument: $1" "see --help" ;;
    *)            if   [[ -z "$EXPECTED" ]]; then EXPECTED="$1"
                  elif [[ -z "$ACTUAL"   ]]; then ACTUAL="$1"
                  else die "too many files: $1"; fi
                  shift ;;
  esac
done

[[ -n "$EXPECTED" && -n "$ACTUAL" ]] || die "usage: $0 <expected.tsv> <actual.tsv>"
[[ -f "$EXPECTED" ]] || die "no such file: $EXPECTED"
[[ -f "$ACTUAL"   ]] || die "no such file: $ACTUAL"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

meta() { grep -m1 "^# $2=" "$1" 2>/dev/null | cut -d= -f2- || true; }

# ═══════════════════════════════════════════════════════════════════════════
# PART 4  HEADERS
# ═══════════════════════════════════════════════════════════════════════════

banner " PITR COMPARE"
kv "expected" "$EXPECTED"
kv "  host"   "$(meta "$EXPECTED" host) at $(meta "$EXPECTED" taken_at)"
kv "  label"  "$(meta "$EXPECTED" label)"
kv "  binlog" "$(meta "$EXPECTED" binlog_after)"
kv "  rows"   "$(meta "$EXPECTED" total_rows) in $(meta "$EXPECTED" tables) tables"
sub
kv "actual"   "$ACTUAL"
kv "  host"   "$(meta "$ACTUAL" host) at $(meta "$ACTUAL" taken_at)"
kv "  label"  "$(meta "$ACTUAL" label)"
kv "  binlog" "$(meta "$ACTUAL" binlog_after)"
kv "  rows"   "$(meta "$ACTUAL" total_rows) in $(meta "$ACTUAL" tables) tables"
sub

# An expected file taken while writes were landing describes no single point in
# time, so any diff against it is noise. Refuse rather than report a fake result.
if [[ "$(meta "$EXPECTED" quiet_during_scan)" != "yes" ]]; then
  die "the expected snapshot is not a clean point (quiet_during_scan=no)" \
      "writes landed while it was taken, so it matches no restorable state" \
      "retake it: pause the writers, run binlog_collect.sh, then snapshot"
fi
ok "expected is a clean point"

# ═══════════════════════════════════════════════════════════════════════════
# PART 5  SCOPE CHECK
#
# Comparing different sets of databases produces a diff that says nothing about
# the restore. Checked before any value is looked at.
# ═══════════════════════════════════════════════════════════════════════════

grep '^T\b' "$EXPECTED" | cut -f2,3 | sort > "$TMP/scope_e" || true
grep '^T\b' "$ACTUAL"   | cut -f2,3 | sort > "$TMP/scope_a" || true

E_SCOPE=$(wc -l < "$TMP/scope_e")
A_SCOPE=$(wc -l < "$TMP/scope_a")
[[ "$E_SCOPE" -gt 0 ]] || die "the expected file holds no T records — is it a snapshot?"

MISSING=$(comm -23 "$TMP/scope_e" "$TMP/scope_a" | wc -l)
EXTRA=$(comm -13 "$TMP/scope_e" "$TMP/scope_a" | wc -l)

SCOPE_BAD=0
if [[ "$MISSING" -gt 0 ]]; then
  SCOPE_BAD=1
  nok "tables missing from actual" "$MISSING"
  cont "these existed on the source and are ABSENT after the restore:"
  comm -23 "$TMP/scope_e" "$TMP/scope_a" | head -"$MAX_REPORT" \
    | while IFS=$'\t' read -r d t; do cont "  $d.$t"; done
fi
if [[ "$EXTRA" -gt 0 ]]; then
  SCOPE_BAD=1
  nok "tables only in actual" "$EXTRA"
  cont "these exist after the restore but not in the expected snapshot:"
  comm -13 "$TMP/scope_e" "$TMP/scope_a" | head -"$MAX_REPORT" \
    | while IFS=$'\t' read -r d t; do cont "  $d.$t"; done
fi
[[ $SCOPE_BAD -eq 1 ]] || ok "same $E_SCOPE tables on both sides"

# ═══════════════════════════════════════════════════════════════════════════
# PART 6  TABLE-LEVEL DIFF
#
# Counts and MAX(pk) and the checksum, per table. The checksum is the one that
# catches contents diverging while the count happens to agree.
# ═══════════════════════════════════════════════════════════════════════════

sub
grep '^T\b' "$EXPECTED" | sort > "$TMP/t_e" || true
grep '^T\b' "$ACTUAL"   | sort > "$TMP/t_a" || true

# Both files carry checksums, or neither comparison is meaningful.
CK_E="$(meta "$EXPECTED" checksums)"
CK_A="$(meta "$ACTUAL" checksums)"
CK_BOTH=1
if [[ "$CK_E" != "yes" || "$CK_A" != "yes" ]]; then
  CK_BOTH=0
  nok "checksum comparison" "SKIPPED"
  cont "expected=$CK_E actual=$CK_A — one side ran with --no-checksum, so"
  cont "content divergence that preserves row counts would go unnoticed"
fi

# Keyed on FILENAME rather than NR == FNR throughout: an empty first file is
# never opened by awk, and NR == FNR would then be true for the SECOND file and
# silently invert the comparison.
awk -F'\t' -v ck="$CK_BOTH" -v maxr="$MAX_REPORT" -v efile="$TMP/t_e" '
  FILENAME == efile {
    key = $2 "\t" $3
    rows[key] = $4; pk[key] = $5; sum[key] = $6
    next
  }
  {
    key = $2 "\t" $3
    if (!(key in rows)) next            # scope already reported it
    compared++
    bad = ""
    if ($4 != rows[key]) bad = bad sprintf("rows %s vs %s  ", rows[key], $4)
    if ($5 != pk[key])   bad = bad sprintf("max_pk %s vs %s  ", pk[key], $5)
    if (ck == 1 && $6 != sum[key]) bad = bad sprintf("checksum %s vs %s", sum[key], $6)
    if (bad != "") {
      n++
      # $2.$3 rather than the tab-separated key: a literal tab in a %-*s field
      # renders wide and throws every following column out of line.
      if (n <= maxr) printf "         %-40s %s\n", $2 "." $3, bad
      if ($4 != rows[key]) { rowdiff++; delta += ($4 - rows[key]) }
    }
  }
  END {
    printf "TOTALS\t%d\t%d\t%d\t%d\n", n+0, rowdiff+0, delta+0, compared+0 > "/dev/stderr"
  }
' "$TMP/t_e" "$TMP/t_a" > "$TMP/t_report" 2> "$TMP/t_totals"

read -r _ T_BAD T_ROWDIFF T_DELTA T_COMPARED < "$TMP/t_totals"

if [[ "${T_BAD:-0}" -gt 0 ]]; then
  nok "table comparison" "$T_BAD of $T_COMPARED DIFFER"
  cat "$TMP/t_report"
  [[ "$T_BAD" -le "$MAX_REPORT" ]] || cont "... $((T_BAD - MAX_REPORT)) more not shown (--max-report)"
  cont ""
  cont "$T_ROWDIFF table(s) differ in row count, net $T_DELTA rows"
  if [[ "${T_DELTA:-0}" -lt 0 ]]; then
    cont "the restore is BEHIND the expected state — the replay did not reach"
    cont "the end of the collected binlogs, or a binlog was never collected"
  elif [[ "${T_DELTA:-0}" -gt 0 ]]; then
    cont "the restore is AHEAD of the expected state — events were applied"
    cont "twice, or the expected snapshot was taken too early"
  fi
elif [[ "${T_COMPARED:-0}" -lt "$E_SCOPE" ]]; then
  # Values agree on every table that exists on both sides, but some do not, and
  # calling that "OK" over a broken scope reads as a pass it has not earned.
  nok "table comparison" "$T_COMPARED of $E_SCOPE compared"
  cont "the values matched wherever both sides had the table, but"
  cont "$(( E_SCOPE - T_COMPARED )) table(s) were missing — see the scope report above"
else
  ok "table comparison ($T_COMPARED tables)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 7  BATCH-LEVEL DIFF
#
# Which writer batches landed, per table. This is what localises a shortfall to
# a point in the binlog stream instead of just a row count that is wrong.
# ═══════════════════════════════════════════════════════════════════════════

sub
grep '^B\b' "$EXPECTED" | sort > "$TMP/b_e" || true
grep '^B\b' "$ACTUAL"   | sort > "$TMP/b_a" || true

B_E=$(wc -l < "$TMP/b_e")
B_A=$(wc -l < "$TMP/b_a")

if [[ "$B_E" -eq 0 && "$B_A" -eq 0 ]]; then
  nok "batch comparison" "NO BATCH DATA"
  cont "neither snapshot carries B records — either the writer never ran or"
  cont "both snapshots used --no-batches"
  B_BAD=0
  B_MISSING_IDS=""
else
  # Keys are held tab-separated for lookup but printed as "db.table batch", so
  # a literal tab never lands inside a padded field and skews the columns.
  awk -F'\t' -v maxr="$MAX_REPORT" -v efile="$TMP/b_e" '
    function show(k) { split(k, p, "\t"); return sprintf("%-34s %s", p[1] "." p[2], p[3]) }
    FILENAME == efile { key = $2 "\t" $3 "\t" $4; rows[key] = $5; ids[$4] = 1; next }
    { key = $2 "\t" $3 "\t" $4
      seen_ids[$4] = 1
      if (!(key in rows)) { extra++; if (extra <= maxr) printf "         EXTRA   %s  %s rows\n", show(key), $5; next }
      if ($5 != rows[key]) { short++; if (short <= maxr) printf "         SHORT   %s  %s of %s rows\n", show(key), $5, rows[key] }
      delete rows[key]
    }
    END {
      n = 0
      for (k in rows) { n++; if (n <= maxr) printf "         MISSING %s  %s rows expected\n", show(k), rows[k] }
      missing_ids = ""
      for (i in ids) if (!(i in seen_ids)) missing_ids = missing_ids " " i
      printf "TOTALS\t%d\t%d\t%d\t%s\n", n+0, short+0, extra+0, missing_ids > "/dev/stderr"
    }
  ' "$TMP/b_e" "$TMP/b_a" > "$TMP/b_report" 2> "$TMP/b_totals"

  read -r _ B_MISS B_SHORT B_EXTRA B_MISSING_IDS < "$TMP/b_totals"
  B_BAD=$(( B_MISS + B_SHORT + B_EXTRA ))

  if [[ "$B_BAD" -gt 0 ]]; then
    nok "batch comparison" "$B_BAD PROBLEM(S)"
    cat "$TMP/b_report"
    cont ""
    cont "$B_MISS missing, $B_SHORT short, $B_EXTRA unexpected (of $B_E expected records)"
    if [[ -n "${B_MISSING_IDS// /}" ]]; then
      cont "batch ids absent from the restore entirely: ${B_MISSING_IDS}"
      cont "the replay stopped before these were written — check the collector"
      cont "log for the binlog covering them, and for a sequence gap"
    fi
  else
    ok "batch comparison ($B_E records)"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 8  VERDICT
# ═══════════════════════════════════════════════════════════════════════════

emit ""
FAILURES=$(( SCOPE_BAD + ${T_BAD:-0} + ${B_BAD:-0} ))
if [[ "$FAILURES" -eq 0 ]]; then
  banner " MATCH — the restore reproduced the expected state exactly"
  kv "tables compared"  "$E_SCOPE"
  kv "batch records"    "$B_E"
  kv "rows"             "$(meta "$EXPECTED" total_rows)"
  kv "binlog reached"   "$(meta "$EXPECTED" binlog_after)"
  if [[ "$CK_BOTH" -eq 0 ]]; then
    sub
    emit " NOTE: checksums were not compared. Row counts match, but contents"
    emit " were not verified. Re-run both snapshots without --no-checksum for"
    emit " a result you can rely on."
  fi
  sub
  exit 0
fi

banner " MISMATCH — the restore does NOT match the expected state"
kv "scope problems"   "$SCOPE_BAD"
kv "tables differing" "${T_BAD:-0} of $E_SCOPE"
kv "batch problems"   "${B_BAD:-0}"
kv "net row delta"    "${T_DELTA:-0}"
sub
emit " Before blaming the restore, rule out the two things that fake a"
emit " mismatch: writes continuing on the source after the freeze, and a"
emit " binlog MySQL purged before binlog_collect.sh copied it (the collector"
emit " log reports that as a sequence gap)."
sub
exit 1
