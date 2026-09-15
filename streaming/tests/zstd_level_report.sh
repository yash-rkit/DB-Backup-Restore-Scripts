#!/usr/bin/env bash
#
# streaming/tests/zstd_level_report.sh — read zstd_level_bench.sh runs, decide a level
#
# Takes the CSV from one or more zstd_level_bench.sh runs and answers the whole
# question in one place: which zstd level to put in logical.sh, what it saves,
# what it costs the backup window, and whether the servers agree with each
# other. Also writes Excel-ready CSVs so the numbers can be charted.
#
#   ./zstd_level_report.sh run1.csv run2.csv
#   ./zstd_level_report.sh --out=results --parallel=3 --retention=30 *.csv
#   ./zstd_level_report.sh --bucket-case='zstd -9' *.csv
#
# Runs compared together must have used the same --levels. A level present in
# one run and missing from another is reported and left out of the combined
# figures rather than silently skewing them.
#
#   PART 1   configuration
#   PART 2   log engine
#   PART 3   arguments
#   PART 4   pre-flight
#   PART 5   load the runs
#   PART 6   per-server results
#   PART 7   combined results
#   PART 8   ratio by database size
#   PART 9   the backup window
#   PART 10  storage projection
#   PART 11  outliers
#   PART 12  recommendation
#   PART 13  excel export
#
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# PART 1  CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

# ── 1B  TUNING ─────────────────────────────────────────────────────────────
OUT_DIR="bench-report"                     # --out=; Excel-ready CSVs land here
PARALLEL=3                                 # logical.sh PARALLEL, for the window
RETENTION_DAYS=30                          # --retention=; days kept, for savings
BUCKET_CASE=""                             # --bucket-case=; default picks the knee
OUTLIER_N=8                                # databases listed at each end
BASELINE="gzip -6"                         # what logical.sh writes today
SMALL_BUCKET=1048576                       # < 1 MiB
LARGE_BUCKET=104857600                     # > 100 MiB

# ── 1D  NOT SET HERE ───────────────────────────────────────────────────────
CSV_FILES=()                               # the run CSVs, from the command line
WORK=""                                    # mktemp -d, removed on exit

# ═══════════════════════════════════════════════════════════════════════════
# PART 2  LOG ENGINE
# ═══════════════════════════════════════════════════════════════════════════

LOG_RULE='=============================================================================='
LOG_SUB='------------------------------------------------------------------------------'
LOG_DOTS='..............................................................................'

emit()   { printf '%s\n' "$1"; }
banner() { emit "$LOG_RULE"; emit "$1"; emit "$LOG_RULE"; }
sub()    { emit "$LOG_SUB"; }
kv()     { emit "$(printf ' %-20s: %s' "$1" "$2")"; }
note()   { emit "$(printf '   %s' "$1")"; }

info() { emit "$(printf ' %-5s %s' 'INFO' "$1")"; }
warn() { emit "$(printf ' %-5s %s' 'WARN' "$1")"; }
erro() { emit "$(printf ' %-5s %s' 'ERROR' "$1")" >&2; }

leader() {
  local pad=$(( 48 - ${#1} - ${#2} ))
  (( pad < 3 )) && pad=3
  printf '%s %s %s' "$1" "${LOG_DOTS:0:$pad}" "$2"
}
val() { info "$(leader "$1" "$2")"; }

die() { erro "$1"; shift; local l; for l in "$@"; do note "$l"; done; exit 2; }

cleanup() { [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════════
# PART 3  ARGUMENTS
# ═══════════════════════════════════════════════════════════════════════════

usage() { sed -n '3,31p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

[[ $# -ge 1 ]] || usage

for arg in "$@"; do
  case "$arg" in
    --out=*)         OUT_DIR="${arg#*=}" ;;
    --parallel=*)    PARALLEL="${arg#*=}" ;;
    --retention=*)   RETENTION_DAYS="${arg#*=}" ;;
    --bucket-case=*) BUCKET_CASE="${arg#*=}" ;;
    -h|--help)       usage ;;
    -*)              die "Unknown argument: $arg" ;;
    *)               CSV_FILES+=("$arg") ;;
  esac
done

(( ${#CSV_FILES[@]} > 0 )) || die "No CSV given" "pass one or more zstd_level_bench.sh .csv files"
[[ "$PARALLEL"       =~ ^[1-9][0-9]*$ ]] || die "--parallel must be a positive integer"
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]]      || die "--retention must be a number of days"

# ═══════════════════════════════════════════════════════════════════════════
# PART 4  PRE-FLIGHT
# ═══════════════════════════════════════════════════════════════════════════

banner " LOGICAL BACKUP COMPRESSION REPORT"

for cmd in awk sort numfmt mkdir; do
  command -v "$cmd" >/dev/null 2>&1 || die "Not in PATH: $cmd"
done

for f in "${CSV_FILES[@]}"; do
  [[ -f "$f" ]] || die "Not a file: $f"
  [[ -r "$f" ]] || die "Not readable: $f"
  # The CPU columns were added later. Both shapes are accepted so runs taken
  # before and after that change can still be compared in one report.
  head -1 "$f" | grep -qE '^database,raw_bytes,case,comp_bytes,comp_ms,decomp_ms,roundtrip(,user_s,sys_s,max_rss_kb)?$' \
    || die "Not a zstd_level_bench.sh CSV: $f" \
           "expected header: database,raw_bytes,case,comp_bytes,comp_ms,decomp_ms,roundtrip" \
           "optionally followed by: ,user_s,sys_s,max_rss_kb"
done

WORK="$(mktemp -d -t benchreport.XXXXXX)" || die "cannot create a work directory"
mkdir -p "$OUT_DIR" || die "cannot create $OUT_DIR"

hsize() { numfmt --to=iec-i --suffix=B "${1%.*}" 2>/dev/null || printf '%sB' "$1"; }

hms() {
  awk -v ms="$1" 'BEGIN {
    s = ms / 1000
    if (s < 90)   { printf "%.0fs", s; exit }
    if (s < 5400) { printf "%dm%02ds", int(s/60), int(s)%60; exit }
    printf "%dh%02dm", int(s/3600), int((s%3600)/60)
  }'
}

# ═══════════════════════════════════════════════════════════════════════════
# PART 5  LOAD THE RUNS
#
# Every row of every CSV is flattened into one table with a server column, so
# every later section is a single awk pass over one file.
# ═══════════════════════════════════════════════════════════════════════════

ALL="${WORK}/all.csv"
printf 'server,database,raw_bytes,case,comp_bytes,comp_ms,decomp_ms,roundtrip\n' > "$ALL"

SERVERS=()
for f in "${CSV_FILES[@]}"; do
  # <server>_bench_<stamp>.csv — the name zstd_level_bench.sh writes.
  base="$(basename "$f" .csv)"
  server="${base%%_bench_*}"
  [[ -n "$server" && "$server" != "$base" ]] || server="$base"
  SERVERS+=("$server")
  awk -F, -v s="$server" 'NR>1 && NF>=7 { print s "," $0 }' "$f" >> "$ALL"
done

ROWS="$(( $(wc -l < "$ALL") - 1 ))"
(( ROWS > 0 )) || die "No data rows in the given CSV(s)"

# Levels must match across runs or the combined totals compare different work.
MISMATCH="$(awk -F, 'NR>1 && $4!="dump" && $5!="" { seen[$1 SUBSEP $4]=1; cases[$4]=1; servers[$1]=1 }
END { for (c in cases) for (s in servers) if (!((s SUBSEP c) in seen)) print c " missing on " s }' "$ALL")"

val "runs loaded"   "${#CSV_FILES[@]}"
val "servers"       "$(printf '%s ' "${SERVERS[@]}")"
val "measurements"  "$ROWS"
if [[ -n "$MISMATCH" ]]; then
  warn "$(leader 'levels differ between runs' 'SEE BELOW')"
  while IFS= read -r l; do note "$l"; done <<< "$MISMATCH"
  note "those cases are excluded from the COMBINED figures below"
fi

# Any round-trip failure invalidates the level it belongs to.
FAILS="$(awk -F, 'NR>1 && $8!="ok" && $8!="not verified (no private key)" && $4!="dump" {print $1 " " $4 " " $2 " -> " $8}' "$ALL")"
if [[ -n "$FAILS" ]]; then
  warn "$(leader 'round-trip failures' 'PRESENT')"
  while IFS= read -r l; do note "$l"; done <<< "$FAILS"
  note "a level that cannot round-trip must not be adopted, whatever it compresses to"
else
  val "round-trip" "every measurement verified"
fi
sub

# ═══════════════════════════════════════════════════════════════════════════
# PART 6  PER-SERVER RESULTS
# ═══════════════════════════════════════════════════════════════════════════

# case ordering: baseline first, then zstd by level, then anything else
order_cases() {
  awk -F, 'NR>1 && $4!="dump" {print $4}' "$ALL" | sort -u | awk -v base="$BASELINE" '
    { c=$0
      if (c == base) { k=0; n=0 }
      else if (match(c, /^zstd -[0-9]+/)) { k=1; n=substr(c, RSTART+6, RLENGTH-6)+0 }
      else { k=2; n=0 }
      printf "%d\t%05d\t%s\n", k, n, c }' | sort -k1,1n -k2,2n | cut -f3
}
mapfile -t CASE_ORDER < <(order_cases)

server_table() {
  local s="$1"
  awk -F, -v S="$s" -v base="$BASELINE" '
    NR>1 && $1==S && $4=="dump" { raw+=$3; dbs++; dump_ms+=$6 }
    NR>1 && $1==S && $4!="dump" && $5!="" { b[$4]+=$5; c[$4]+=$6; d[$4]+=$7 }
    END {
      printf "RAW\t%d\t%d\t%d\n", raw, dbs, dump_ms
      for (k in b) printf "CASE\t%s\t%d\t%d\t%d\n", k, b[k], c[k], d[k]
    }' "$ALL"
}

declare -A S_RAW=() S_DBS=() S_DUMPMS=()
declare -A CB=() CC=() CD=()          # keyed "server|case"

for s in "${SERVERS[@]}"; do
  while IFS=$'\t' read -r tag a b c d; do
    case "$tag" in
      RAW)  S_RAW["$s"]="$a"; S_DBS["$s"]="$b"; S_DUMPMS["$s"]="$c" ;;
      CASE) CB["$s|$a"]="$b"; CC["$s|$a"]="$c"; CD["$s|$a"]="$d" ;;
    esac
  done < <(server_table "$s")
done

print_case_table() {
  local scope="$1" rawb="$2"
  local -n B=$3; local -n C=$4; local -n D=$5; local key_prefix="$6"
  local gz="${B["${key_prefix}${BASELINE}"]:-0}"
  emit "$(printf ' %-12s %12s %8s %11s %11s %10s %12s' \
    'CASE' 'TOTAL' 'RATIO' 'COMPRESS' 'DECOMP' 'VS GZIP' 'SAVED')"
  sub
  local c b
  for c in "${CASE_ORDER[@]}"; do
    b="${B["${key_prefix}${c}"]:-}"
    [[ -n "$b" && "$b" != "0" ]] || continue
    emit "$(awk -v c="$c" -v b="$b" -v raw="$rawb" -v gz="$gz" \
                -v cm="${C["${key_prefix}${c}"]:-0}" -v dm="${D["${key_prefix}${c}"]:-0}" '
      function h(x,   u,i,a) { split("B KiB MiB GiB TiB", a, " "); i=1
        while (x >= 1024 && i < 5) { x/=1024; i++ }
        return sprintf("%.2f%s", x, a[i]) }
      function t(ms,   s) { s=ms/1000
        if (s < 90) return sprintf("%.0fs", s)
        if (s < 5400) return sprintf("%dm%02ds", int(s/60), int(s)%60)
        return sprintf("%dh%02dm", int(s/3600), int((s%3600)/60)) }
      BEGIN {
        printf " %-12s %12s %7.2fx %11s %11s %9.1f%% %12s",
          c, h(b), raw/b, t(cm), t(dm), (b-gz)*100.0/gz, (gz-b > 0 ? h(gz-b) : "-")
      }')"
  done
  sub
}

for s in "${SERVERS[@]}"; do
  emit ""
  banner " $s"
  kv "databases"  "${S_DBS[$s]}"
  kv "raw SQL"    "$(awk -v b="${S_RAW[$s]}" 'BEGIN{printf "%.2f GiB", b/1073741824}')"
  kv "dump time"  "$(hms "${S_DUMPMS[$s]}") of mysqldump, serial"
  sub
  print_case_table "$s" "${S_RAW[$s]}" CB CC CD "$s|"
done

# ═══════════════════════════════════════════════════════════════════════════
# PART 7  COMBINED RESULTS
#
# Only cases present on every server are summed; a case measured on one run
# and not another would otherwise read as a smaller total rather than a
# narrower sample.
# ═══════════════════════════════════════════════════════════════════════════

declare -A TB=() TC=() TD=()
TOTAL_RAW=0; TOTAL_DBS=0; TOTAL_DUMPMS=0
for s in "${SERVERS[@]}"; do
  TOTAL_RAW=$(( TOTAL_RAW + ${S_RAW[$s]} ))
  TOTAL_DBS=$(( TOTAL_DBS + ${S_DBS[$s]} ))
  TOTAL_DUMPMS=$(( TOTAL_DUMPMS + ${S_DUMPMS[$s]} ))
done

for c in "${CASE_ORDER[@]}"; do
  present=1
  for s in "${SERVERS[@]}"; do
    [[ -n "${CB["$s|$c"]:-}" ]] || present=0
  done
  (( present == 1 )) || continue
  tb=0; tc=0; td=0
  for s in "${SERVERS[@]}"; do
    tb=$(( tb + ${CB["$s|$c"]} )); tc=$(( tc + ${CC["$s|$c"]} )); td=$(( td + ${CD["$s|$c"]} ))
  done
  TB["|$c"]="$tb"; TC["|$c"]="$tc"; TD["|$c"]="$td"
done

if (( ${#SERVERS[@]} > 1 )); then
  emit ""
  banner " COMBINED   ${#SERVERS[@]} servers, $TOTAL_DBS databases"
  kv "raw SQL"   "$(awk -v b="$TOTAL_RAW" 'BEGIN{printf "%.2f GiB", b/1073741824}')"
  kv "dump time" "$(hms "$TOTAL_DUMPMS") of mysqldump, serial"
  sub
  print_case_table "combined" "$TOTAL_RAW" TB TC TD "|"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 8  RATIO BY DATABASE SIZE
#
# Whether the headline ratio belongs to the whole estate or only to part of it.
# ═══════════════════════════════════════════════════════════════════════════

# Default to the knee — most bytes saved per second of CPU — rather than a
# hard-coded level, so this still reads correctly on a different --levels set.
GZ_TOTAL="${TB["|$BASELINE"]:-0}"
if [[ -z "$BUCKET_CASE" ]]; then
  BUCKET_CASE="$(for c in "${CASE_ORDER[@]}"; do
      [[ "$c" == "$BASELINE" ]] && continue
      b="${TB["|$c"]:-}"; [[ -n "$b" ]] || continue
      awk -v c="$c" -v g="$GZ_TOTAL" -v b="$b" -v t="${TC["|$c"]:-1}" \
        'BEGIN{ if(t<1)t=1; printf "%d\t%s\n", (g-b)*1000/t, c }'
    done | sort -rn | head -1 | cut -f2)"
fi
[[ -n "$BUCKET_CASE" ]] || BUCKET_CASE="$BASELINE"

emit ""
banner " RATIO BY DATABASE SIZE   ($BUCKET_CASE)"
emit "$(printf ' %-26s %7s %12s %12s %9s %9s' \
  'SERVER / BUCKET' 'DBS' 'RAW SQL' 'COMPRESSED' 'RATIO' 'SHARE')"
sub
awk -F, -v C="$BUCKET_CASE" -v SB="$SMALL_BUCKET" -v LB="$LARGE_BUCKET" '
  function h(x,   u,i,a) { split("B KiB MiB GiB TiB", a, " "); i=1
    while (x >= 1024 && i < 5) { x/=1024; i++ }
    return sprintf("%.2f%s", x, a[i]) }
  NR>1 && $4==C && $5!="" {
    raw=$3+0; comp=$5+0
    b = (raw < SB) ? "1 < 1 MiB" : (raw < LB ? "2 1-100 MiB" : "3 > 100 MiB")
    key = $1 SUBSEP b
    R[key]+=raw; K[key]+=comp; N[key]++
    SR[$1]+=raw; servers[$1]=1; buckets[b]=1
  }
  END {
    n=0; for (s in servers) order[++n]=s
    for (i=1; i<=n; i++) for (j=i+1; j<=n; j++) if (order[i] > order[j]) { t=order[i]; order[i]=order[j]; order[j]=t }
    for (i=1; i<=n; i++) { s=order[i]
      m=0; for (b in buckets) blist[++m]=b
      for (x=1; x<=m; x++) for (y=x+1; y<=m; y++) if (blist[x] > blist[y]) { t=blist[x]; blist[x]=blist[y]; blist[y]=t }
      for (x=1; x<=m; x++) { b=blist[x]; key=s SUBSEP b
        if (!(key in N)) continue
        printf " %-26s %7d %12s %12s %8.2fx %8.1f%%\n",
          substr(s,1,17) " / " substr(b,3), N[key], h(R[key]), h(K[key]),
          R[key]/K[key], R[key]*100.0/SR[s]
      }
    }
  }' "$ALL"
sub
note "SHARE is how much of that server's raw SQL sits in the bucket."
note "The bucket holding most of the bytes is the one that sets your real ratio."

# ═══════════════════════════════════════════════════════════════════════════
# PART 9  THE BACKUP WINDOW
#
# The number that decides whether a level is affordable: dump plus compression,
# divided by PARALLEL, because logical.sh runs that many databases at once.
# ═══════════════════════════════════════════════════════════════════════════

emit ""
banner " BACKUP WINDOW AT PARALLEL=$PARALLEL   (dump + compress)"
emit "$(printf ' %-12s %14s %14s %14s %12s' \
  'CASE' 'DUMP' 'COMPRESS' 'WINDOW' 'VS TODAY')"
sub
BASE_WINDOW="$(awk -v d="$TOTAL_DUMPMS" -v c="${TC["|$BASELINE"]:-0}" -v p="$PARALLEL" \
  'BEGIN{printf "%d", (d+c)/p}')"
for c in "${CASE_ORDER[@]}"; do
  cm="${TC["|$c"]:-}"; [[ -n "$cm" ]] || continue
  emit "$(awk -v c="$c" -v d="$TOTAL_DUMPMS" -v cm="$cm" -v p="$PARALLEL" -v bw="$BASE_WINDOW" '
    function t(ms,   s) { s=ms/1000
      if (s < 90) return sprintf("%.0fs", s)
      if (s < 5400) return sprintf("%dm%02ds", int(s/60), int(s)%60)
      return sprintf("%dh%02dm", int(s/3600), int((s%3600)/60)) }
    BEGIN { w=(d+cm)/p
      printf " %-12s %14s %14s %14s %11s", c, t(d/p), t(cm/p), t(w),
        (bw>0 ? sprintf("%+.0f%%", (w-bw)*100.0/bw) : "n/a") }')"
done
sub
note "DUMP is the same for every case — it is the mysqldump cost, unavoidable."
note "Only the COMPRESS column changes when you change level."

# ═══════════════════════════════════════════════════════════════════════════
# PART 10  STORAGE PROJECTION
# ═══════════════════════════════════════════════════════════════════════════

emit ""
banner " STORAGE AT ${RETENTION_DAYS}-DAY RETENTION   (one run per day, both shares)"
emit "$(printf ' %-12s %14s %16s %16s' \
  'CASE' 'PER RUN' "ON DISK (${RETENTION_DAYS}d)" 'SAVED VS GZIP')"
sub
for c in "${CASE_ORDER[@]}"; do
  b="${TB["|$c"]:-}"; [[ -n "$b" ]] || continue
  emit "$(awk -v c="$c" -v b="$b" -v g="$GZ_TOTAL" -v r="$RETENTION_DAYS" '
    function h(x,   i,a) { split("B KiB MiB GiB TiB", a, " "); i=1
      while (x >= 1024 && i < 5) { x/=1024; i++ }
      return sprintf("%.2f%s", x, a[i]) }
    BEGIN { printf " %-12s %14s %16s %16s", c, h(b), h(b*r),
      (g-b > 0 ? h((g-b)*r) : "-") }')"
done
sub
note "Doubled again if backup_sync.sh mirrors the tree to the second share."

# ═══════════════════════════════════════════════════════════════════════════
# PART 11  OUTLIERS
#
# The databases that behave unlike the rest. A schema that barely compresses is
# usually one holding already-compressed or high-entropy columns.
# ═══════════════════════════════════════════════════════════════════════════

emit ""
banner " DATABASES THAT COMPRESS WORST   ($BUCKET_CASE, over 10 MiB)"
emit "$(printf ' %-30s %-22s %12s %12s %9s' 'DATABASE' 'SERVER' 'RAW SQL' 'COMPRESSED' 'RATIO')"
sub
awk -F, -v C="$BUCKET_CASE" '
  function h(x,   i,a) { split("B KiB MiB GiB TiB", a, " "); i=1
    while (x >= 1024 && i < 5) { x/=1024; i++ }
    return sprintf("%.2f%s", x, a[i]) }
  NR>1 && $4==C && $5!="" && $3+0 > 10485760 {
    printf "%.4f\t%s\t%s\t%s\t%s\n", $3/$5, $2, $1, h($3), h($5) }' "$ALL" \
  | sort -n | head -"$OUTLIER_N" \
  | awk -F'\t' '{ printf " %-30s %-22s %12s %12s %8.2fx\n", substr($2,1,30), substr($3,1,22), $4, $5, $1 }'
sub
note "These set the floor. If they are large, they dominate the estate ratio."

# ═══════════════════════════════════════════════════════════════════════════
# PART 12  RECOMMENDATION
# ═══════════════════════════════════════════════════════════════════════════

emit ""
banner " RECOMMENDATION"

SMALLEST=""; SMALLEST_B=0
KNEE=""; KNEE_SCORE=-1
for c in "${CASE_ORDER[@]}"; do
  [[ "$c" == "$BASELINE" ]] && continue
  b="${TB["|$c"]:-}"; [[ -n "$b" ]] || continue
  if (( SMALLEST_B == 0 )) || (( b < SMALLEST_B )); then SMALLEST_B="$b"; SMALLEST="$c"; fi
  score="$(awk -v g="$GZ_TOTAL" -v b="$b" -v t="${TC["|$c"]:-1}" \
           'BEGIN{ if(t<1)t=1; printf "%d", (g-b)*1000/t }')"
  if (( score > KNEE_SCORE )); then KNEE_SCORE="$score"; KNEE="$c"; fi
done

if [[ -n "$KNEE" ]]; then
  kv "best value"  "$KNEE"
  kv "smallest"    "$SMALLEST"
  sub
  awk -v k="$KNEE" -v sm="$SMALLEST" \
      -v kb="${TB["|$KNEE"]:-0}" -v sb="$SMALLEST_B" -v g="$GZ_TOTAL" \
      -v kc="${TC["|$KNEE"]:-0}" -v sc="${TC["|$SMALLEST"]:-0}" \
      -v gc="${TC["|$BASELINE"]:-0}" -v d="$TOTAL_DUMPMS" -v p="$PARALLEL" -v r="$RETENTION_DAYS" '
    function h(x,   i,a) { split("B KiB MiB GiB TiB", a, " "); i=1
      while (x >= 1024 && i < 5) { x/=1024; i++ }
      return sprintf("%.2f%s", x, a[i]) }
    function t(ms,   s) { s=ms/1000
      if (s < 90) return sprintf("%.0fs", s)
      if (s < 5400) return sprintf("%dm%02ds", int(s/60), int(s)%60)
      return sprintf("%dh%02dm", int(s/3600), int((s%3600)/60)) }
    BEGIN {
      printf "   %s is %.1f%% smaller than %s and its window is %s (today %s).\n",
        k, (g-kb)*100.0/g, "gzip -6", t((d+kc)/p), t((d+gc)/p)
      printf "   It saves %s per run, %s across %d days of retention.\n", h(g-kb), h((g-kb)*r), r
      if (sm != k) {
        printf "\n   %s is smaller still, by %s per run (%.1f%% more than %s),\n",
          sm, h(kb-sb), (kb-sb)*100.0/kb, k
        printf "   but costs %s of window instead of %s — %.1fx the compression time.\n",
          t((d+sc)/p), t((d+kc)/p), sc/(kc>0?kc:1)
      }
    }'
  sub
  note "Adopt the best-value level unless the window has room to spare."
  note "Whatever you pick, it must be recorded in the manifest: an archive that"
  note "does not say how it was compressed is one guess away from unreadable."
else
  warn "no case could be scored — check the input CSVs"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 13  EXCEL EXPORT
#
# Flat CSVs, one fact per row, no merged headers — the shape a pivot table
# wants. Sizes are given in bytes AND GiB so a chart can use either.
# ═══════════════════════════════════════════════════════════════════════════

SUMMARY="${OUT_DIR}/1_summary_by_server.csv"
COMBINED="${OUT_DIR}/2_summary_combined.csv"
BUCKETS="${OUT_DIR}/3_ratio_by_size.csv"
WINDOW="${OUT_DIR}/4_backup_window.csv"
DETAIL="${OUT_DIR}/5_per_database.csv"

{
  printf 'server,case,databases,raw_bytes,raw_gib,compressed_bytes,compressed_gib,ratio,compress_ms,decompress_ms,vs_gzip_pct,saved_bytes\n'
  for s in "${SERVERS[@]}"; do
    gz="${CB["$s|$BASELINE"]:-0}"
    for c in "${CASE_ORDER[@]}"; do
      b="${CB["$s|$c"]:-}"; [[ -n "$b" ]] || continue
      awk -v s="$s" -v c="$c" -v n="${S_DBS[$s]}" -v raw="${S_RAW[$s]}" -v b="$b" \
          -v cm="${CC["$s|$c"]:-0}" -v dm="${CD["$s|$c"]:-0}" -v g="$gz" 'BEGIN{
        printf "%s,%s,%d,%d,%.4f,%d,%.4f,%.4f,%d,%d,%.2f,%d\n",
          s, c, n, raw, raw/1073741824, b, b/1073741824, raw/b, cm, dm,
          (g>0 ? (b-g)*100.0/g : 0), (g-b) }'
    done
  done
} > "$SUMMARY"

{
  printf 'case,servers,databases,raw_bytes,raw_gib,compressed_bytes,compressed_gib,ratio,compress_ms,decompress_ms,vs_gzip_pct,saved_per_run_bytes,saved_retention_bytes\n'
  for c in "${CASE_ORDER[@]}"; do
    b="${TB["|$c"]:-}"; [[ -n "$b" ]] || continue
    awk -v c="$c" -v ns="${#SERVERS[@]}" -v n="$TOTAL_DBS" -v raw="$TOTAL_RAW" -v b="$b" \
        -v cm="${TC["|$c"]:-0}" -v dm="${TD["|$c"]:-0}" -v g="$GZ_TOTAL" -v r="$RETENTION_DAYS" 'BEGIN{
      printf "%s,%d,%d,%d,%.4f,%d,%.4f,%.4f,%d,%d,%.2f,%d,%d\n",
        c, ns, n, raw, raw/1073741824, b, b/1073741824, raw/b, cm, dm,
        (g>0 ? (b-g)*100.0/g : 0), (g-b), (g-b)*r }'
  done
} > "$COMBINED"

{
  printf 'server,bucket,case,databases,raw_bytes,compressed_bytes,ratio\n'
  awk -F, -v SB="$SMALL_BUCKET" -v LB="$LARGE_BUCKET" '
    NR>1 && $4!="dump" && $5!="" {
      raw=$3+0
      b = (raw < SB) ? "< 1 MiB" : (raw < LB ? "1-100 MiB" : "> 100 MiB")
      key=$1 SUBSEP b SUBSEP $4
      R[key]+=raw; K[key]+=$5; N[key]++
    }
    END { for (k in R) { split(k, p, SUBSEP)
      printf "%s,%s,%s,%d,%d,%d,%.4f\n", p[1], p[2], p[3], N[k], R[k], K[k], R[k]/K[k] } }' "$ALL" \
    | sort -t, -k1,1 -k3,3 -k2,2
} > "$BUCKETS"

{
  printf 'case,parallel,dump_ms,compress_ms,window_ms,window_minutes,vs_today_pct\n'
  for c in "${CASE_ORDER[@]}"; do
    cm="${TC["|$c"]:-}"; [[ -n "$cm" ]] || continue
    awk -v c="$c" -v p="$PARALLEL" -v d="$TOTAL_DUMPMS" -v cm="$cm" -v bw="$BASE_WINDOW" 'BEGIN{
      w=(d+cm)/p
      printf "%s,%d,%d,%d,%d,%.2f,%.2f\n", c, p, d/p, cm/p, w, w/60000,
        (bw>0 ? (w-bw)*100.0/bw : 0) }'
  done
} > "$WINDOW"

{
  printf 'server,database,case,raw_bytes,compressed_bytes,ratio,compress_ms,decompress_ms,roundtrip\n'
  awk -F, 'NR>1 && $4!="dump" && $5!="" {
    printf "%s,%s,%s,%s,%s,%.4f,%s,%s,%s\n", $1,$2,$4,$3,$5,$3/$5,$6,$7,$8 }' "$ALL"
} > "$DETAIL"

emit ""
banner " EXCEL-READY FILES"
for f in "$SUMMARY" "$COMBINED" "$BUCKETS" "$WINDOW" "$DETAIL"; do
  val "$(basename "$f")" "$(( $(wc -l < "$f") - 1 )) rows"
done
sub
note "Open the folder in Excel, or: Data > From Text/CSV on each file."
note "5_per_database.csv is the one to pivot — every database at every level."

emit ""
exit 0
