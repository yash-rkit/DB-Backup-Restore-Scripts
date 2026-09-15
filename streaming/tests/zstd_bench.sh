#!/usr/bin/env bash
#
# streaming/tests/zstd_bench.sh — pick a zstd level on real dump data
#
# Compresses a CORPUS of .sql dumps at every requested zstd level and reports
# the aggregate, because one database cannot answer the question. Ratio is
# data-dependent and size-dependent: a 5 GiB dump and a 50 KiB dump of the same
# schema compress very differently, and an estate of 400 databases is mostly
# the small ones. Time behaves the same way — a level that costs 40s more per
# database costs hours across the estate.
#
#   ./zstd_bench.sh --corpus=/tmp/bench            # a directory of .sql files
#   ./zstd_bench.sh /tmp/one.sql                   # single file, still works
#   ./zstd_bench.sh --corpus=/tmp/bench --levels=1,3,9,12,15,19
#   ./zstd_bench.sh --corpus=/tmp/bench --ultra    # adds 20,21,22
#   ./zstd_bench.sh --corpus=/tmp/bench --long     # adds --long=27 runs
#   ./zstd_bench.sh --corpus=/tmp/bench --dict     # adds trained-dictionary runs
#   ./zstd_bench.sh --corpus=/tmp/bench --estate=1.4T --dbs=400
#   ./zstd_bench.sh --corpus=/tmp/bench --parallel=3
#
# --estate and --dbs turn the sample into a projection of the real run: total
# archive size, and wall-clock time at --parallel workers.
#
# Every run is verified: the output is decompressed and checked against the
# input's sha256. A level that does not round-trip is reported, not scored.
#
# Nothing is written outside the work directory, and it is removed on exit.
#
#   PART 1   configuration
#   PART 2   log engine
#   PART 3   arguments
#   PART 4   pre-flight
#   PART 5   the corpus
#   PART 6   dictionary
#   PART 7   the runs
#   PART 8   aggregate results
#   PART 9   size buckets
#   PART 10  projection
#   PART 11  recommendation
#
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# PART 1  CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

DEFAULT_LEVELS="1,3,6,9,12,15,19"        # levels tested when --levels= is absent
ULTRA_LEVELS="20,21,22"                  # --ultra appends these
LONG_WINDOW=27                           # --long= window log, 128 MiB
THREADS=1                                # -T value; 1 keeps levels comparable
GZIP_LEVEL=6                             # tar -czf's default, today's baseline
PARALLEL=3                               # logical.sh PARALLEL, for the projection
DICT_SIZE=112640                         # 110 KiB, zstd's default dictionary size
SMALL_BUCKET=1048576                     # < 1 MiB
LARGE_BUCKET=104857600                   # > 100 MiB
WORK_DIR=""                              # mktemp -d, removed on exit

# ═══════════════════════════════════════════════════════════════════════════
# PART 2  LOG ENGINE
# ═══════════════════════════════════════════════════════════════════════════

LOG_RULE='=========================================================================='
LOG_SUB='--------------------------------------------------------------------------'
LOG_DOTS='..........................................................................'

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

die() { erro "$1"; shift; local l; for l in "$@"; do cont "$l"; done; exit 2; }

hsize() {
  numfmt --to=iec-i --suffix=B "$1" 2>/dev/null \
    || awk -v b="$1" 'BEGIN { printf "%.1fMiB", b/1048576 }'
}

# Milliseconds to something a human can compare to a backup window.
hms() {
  awk -v ms="$1" 'BEGIN {
    s = ms / 1000
    if (s < 90)   { printf "%.0fs", s; exit }
    if (s < 5400) { printf "%dm%02ds", int(s/60), int(s)%60; exit }
    printf "%dh%02dm", int(s/3600), int((s%3600)/60)
  }'
}

now_ms() { date +%s%3N; }

cleanup() { [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"; return 0; }
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════════
# PART 3  ARGUMENTS
# ═══════════════════════════════════════════════════════════════════════════

usage() { sed -n '3,39p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

SRC=""
CORPUS=""
LEVELS="$DEFAULT_LEVELS"
WANT_ULTRA=0
WANT_LONG=0
WANT_DICT=0
ESTATE=""
DB_TOTAL=""

[[ $# -ge 1 ]] || usage

for arg in "$@"; do
  case "$arg" in
    --corpus=*)   CORPUS="${arg#*=}" ;;
    --levels=*)   LEVELS="${arg#*=}" ;;
    --threads=*)  THREADS="${arg#*=}" ;;
    --parallel=*) PARALLEL="${arg#*=}" ;;
    --estate=*)   ESTATE="${arg#*=}" ;;
    --dbs=*)      DB_TOTAL="${arg#*=}" ;;
    --ultra)      WANT_ULTRA=1 ;;
    --long)       WANT_LONG=1 ;;
    --dict)       WANT_DICT=1 ;;
    -h|--help)    usage ;;
    -*)           die "Unknown argument: $arg" ;;
    *)            [[ -z "$SRC" ]] || die "Only one input file, got '$SRC' and '$arg'"
                  SRC="$arg" ;;
  esac
done

[[ -n "$CORPUS" || -n "$SRC" ]] \
  || die "Nothing to test" "pass --corpus=DIR, or a single .sql file"
[[ -z "$CORPUS" || -z "$SRC" ]] \
  || die "Pass either --corpus=DIR or one file, not both"

[[ "$THREADS"  =~ ^[0-9]+$ ]]     || die "--threads must be a number, got '$THREADS'"
[[ "$PARALLEL" =~ ^[1-9][0-9]*$ ]] || die "--parallel must be a positive integer"
[[ -z "$DB_TOTAL" || "$DB_TOTAL" =~ ^[1-9][0-9]*$ ]] \
  || die "--dbs must be a positive integer, got '$DB_TOTAL'"

(( WANT_ULTRA == 1 )) && LEVELS="${LEVELS},${ULTRA_LEVELS}"

IFS=',' read -r -a LEVEL_ARR <<< "$LEVELS"
for lv in "${LEVEL_ARR[@]}"; do
  [[ "$lv" =~ ^[0-9]+$ ]] || die "Bad level '$lv' in --levels=$LEVELS"
  (( lv >= 1 && lv <= 22 )) || die "Level $lv out of range (1-22)"
  (( lv >= 20 )) && (( WANT_ULTRA == 0 )) \
    && die "Level $lv needs --ultra" \
           "levels 20-22 need a large window on BOTH compress and decompress"
done

ESTATE_BYTES=0
if [[ -n "$ESTATE" ]]; then
  ESTATE_BYTES="$(numfmt --from=iec "$ESTATE" 2>/dev/null)" \
    || die "Bad --estate=$ESTATE" "use a size like 800G or 1.4T"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 4  PRE-FLIGHT
# ═══════════════════════════════════════════════════════════════════════════

banner " ZSTD LEVEL BENCHMARK"

for cmd in zstd gzip sha256sum stat date awk numfmt df; do
  command -v "$cmd" >/dev/null 2>&1 || die "Not in PATH: $cmd" \
    "on Ubuntu: sudo apt install zstd coreutils"
done
ok "required binaries"

WORK_DIR="$(mktemp -d -t zstdbench.XXXXXX)" || die "cannot create a work directory"

# ═══════════════════════════════════════════════════════════════════════════
# PART 5  THE CORPUS
#
# Files are held as a parallel array of paths and sizes. Everything downstream
# iterates this, so single-file mode is just a corpus of one.
# ═══════════════════════════════════════════════════════════════════════════

FILES=()
if [[ -n "$CORPUS" ]]; then
  [[ -d "$CORPUS" ]] || die "Not a directory: $CORPUS"
  while IFS= read -r f; do
    [[ -s "$f" ]] && FILES+=("$f")
  done < <(find "$CORPUS" -maxdepth 1 -type f \( -name '*.sql' -o -name '*.dump' \) \
             2>/dev/null | LC_ALL=C sort)
  (( ${#FILES[@]} > 0 )) || die "No non-empty .sql files in $CORPUS" \
    "dump a representative sample first — see the README"
else
  [[ -f "$SRC" ]] || die "Not a file: $SRC"
  [[ -r "$SRC" ]] || die "Not readable: $SRC"
  [[ -s "$SRC" ]] || die "File is empty: $SRC"
  FILES=("$SRC")
  warn "$(leader 'single file' 'NOT REPRESENTATIVE')"
  cont "one database cannot predict an estate of hundreds — small dumps"
  cont "compress far worse than large ones. Use --corpus=DIR for a real answer."
fi

RAW_TOTAL=0
SIZES=()
SHAS=()
BIGGEST=0
info "hashing ${#FILES[@]} file(s)..."
for f in "${FILES[@]}"; do
  b="$(stat -c%s "$f")"
  SIZES+=("$b")
  SHAS+=("$(sha256sum "$f" | awk '{print $1}')")
  RAW_TOTAL=$(( RAW_TOTAL + b ))
  (( b > BIGGEST )) && BIGGEST="$b"
done

AVAIL="$(df -Pk "$WORK_DIR" 2>/dev/null | tail -1 | awk '{print $4}')"
[[ "$AVAIL" =~ ^[0-9]+$ ]] || AVAIL=0
AVAIL=$(( AVAIL * 1024 ))
if (( AVAIL > 0 && AVAIL < BIGGEST * 2 )); then
  warn "$(leader 'work space' 'TIGHT')"
  cont "$(hsize "$AVAIL") free, largest file needs $(hsize $((BIGGEST * 2)))"
fi

sub
kv "corpus"       "${CORPUS:-$SRC}"
kv "files"        "${#FILES[@]}"
kv "total bytes"  "$(hsize "$RAW_TOTAL")"
kv "levels"       "$LEVELS"
kv "threads"      "-T$THREADS$( (( THREADS == 0 )) && printf ' (all cores)')"
kv "long window"  "$( (( WANT_LONG == 1 )) && printf -- "--long=%s as extra runs" "$LONG_WINDOW" || printf 'not tested')"
kv "dictionary"   "$( (( WANT_DICT == 1 )) && printf 'trained, as extra runs' || printf 'not tested')"
kv "zstd"         "$(zstd --version 2>&1 | head -1)"
sub

# ═══════════════════════════════════════════════════════════════════════════
# PART 6  DICTIONARY
#
# 400 tenant databases usually share one schema, so every dump repeats the same
# CREATE TABLE text. A trained dictionary gives the compressor that text up
# front, which is worth a great deal on the small dumps and nothing on the
# large ones. It is opt-in because the dictionary becomes a restore dependency:
# lose it and every archive built with it is unreadable.
# ═══════════════════════════════════════════════════════════════════════════

DICT=""
if (( WANT_DICT == 1 )); then
  if (( ${#FILES[@]} < 4 )); then
    warn "$(leader 'dictionary' 'TOO FEW SAMPLES')"
    cont "zstd --train wants several files; skipping the dictionary runs"
    WANT_DICT=0
  else
    DICT="${WORK_DIR}/dict.bin"
    info "training a dictionary on ${#FILES[@]} sample(s)..."
    if zstd --train "${FILES[@]}" --maxdict="$DICT_SIZE" -o "$DICT" >/dev/null 2>&1 \
       && [[ -s "$DICT" ]]; then
      val "dictionary trained" "$(hsize "$(stat -c%s "$DICT")")"
    else
      warn "$(leader 'dictionary' 'TRAINING FAILED')"
      cont "skipping the dictionary runs"
      WANT_DICT=0; DICT=""
    fi
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 7  THE RUNS
#
# One case = one level over the WHOLE corpus. Per-file numbers are kept only
# for the size-bucket breakdown in PART 9.
# ═══════════════════════════════════════════════════════════════════════════

RESULTS=()          # "label|bytes|ratio|comp_ms|decomp_ms|failures"
BUCKET_LABEL=""     # the case whose per-file numbers PER_FILE holds
PER_FILE=()         # "raw_bytes|comp_bytes" for BUCKET_LABEL

run_case() {
  local label="$1"; shift
  local out="${WORK_DIR}/out.bin"
  local back="${WORK_DIR}/back.sql"
  local total_out=0 total_c=0 total_d=0 failures=0
  local i f raw t0 t1 b
  local -a per=()

  for i in "${!FILES[@]}"; do
    f="${FILES[$i]}"; raw="${SIZES[$i]}"
    rm -f "$out" "$back"

    t0="$(now_ms)"
    if ! "$@" < "$f" > "$out" 2>/dev/null; then
      failures=$(( failures + 1 )); continue
    fi
    t1="$(now_ms)"; total_c=$(( total_c + t1 - t0 ))

    b="$(stat -c%s "$out")"
    total_out=$(( total_out + b ))
    per+=("${raw}|${b}")

    t0="$(now_ms)"
    if [[ "$label" == gzip* ]]; then
      gzip -dc < "$out" > "$back" 2>/dev/null || true
    elif [[ "$label" == *dict* && -n "$DICT" ]]; then
      zstd -dc -D "$DICT" < "$out" > "$back" 2>/dev/null || true
    else
      zstd -dc --long="$LONG_WINDOW" < "$out" > "$back" 2>/dev/null || true
    fi
    t1="$(now_ms)"; total_d=$(( total_d + t1 - t0 ))

    if [[ "$(sha256sum "$back" | awk '{print $1}')" != "${SHAS[$i]}" ]]; then
      failures=$(( failures + 1 ))
    fi
  done
  rm -f "$out" "$back"

  if (( total_out == 0 )); then
    warn "$(leader "$label" 'ALL RUNS FAILED')"
    RESULTS+=("${label}|0|0|0|0|${#FILES[@]}")
    return 0
  fi

  local ratio
  ratio="$(awk -v r="$RAW_TOTAL" -v b="$total_out" 'BEGIN { printf "%.2f", r/b }')"
  RESULTS+=("${label}|${total_out}|${ratio}|${total_c}|${total_d}|${failures}")

  if (( failures > 0 )); then
    warn "$(leader "$label" "$(hsize "$total_out")  ${ratio}x  ${failures} FAILED")"
  else
    val "$label" "$(hsize "$total_out")  ${ratio}x  $(hms "$total_c")"
  fi

  # Keep the per-file detail for whichever mid-range level we bucket on.
  if [[ -z "$BUCKET_LABEL" && "$label" != gzip* ]]; then
    BUCKET_LABEL="$label"; PER_FILE=("${per[@]}")
  fi
  return 0
}

info "baseline — what logical.sh writes today"
run_case "gzip -${GZIP_LEVEL}" gzip -"${GZIP_LEVEL}" -c
GZIP_BYTES="$(printf '%s\n' "${RESULTS[0]}" | cut -d'|' -f2)"
GZIP_MS="$(printf '%s\n' "${RESULTS[0]}" | cut -d'|' -f4)"

sub
info "zstd levels"
for lv in "${LEVEL_ARR[@]}"; do
  if (( lv >= 20 )); then
    run_case "zstd -${lv}" zstd --ultra -"$lv" -T"$THREADS" -c
  else
    run_case "zstd -${lv}" zstd -"$lv" -T"$THREADS" -c
  fi
done

if (( WANT_LONG == 1 )); then
  sub
  info "zstd with --long=${LONG_WINDOW}"
  for lv in "${LEVEL_ARR[@]}"; do
    if (( lv >= 20 )); then
      run_case "zstd -${lv} long" zstd --ultra -"$lv" --long="$LONG_WINDOW" -T"$THREADS" -c
    else
      run_case "zstd -${lv} long" zstd -"$lv" --long="$LONG_WINDOW" -T"$THREADS" -c
    fi
  done
fi

if (( WANT_DICT == 1 )); then
  sub
  info "zstd with a trained dictionary"
  for lv in "${LEVEL_ARR[@]}"; do
    (( lv >= 20 )) && continue          # --ultra plus -D is rarely worth the time
    run_case "zstd -${lv} dict" zstd -"$lv" -D "$DICT" -T"$THREADS" -c
  done
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 8  AGGREGATE RESULTS
# ═══════════════════════════════════════════════════════════════════════════

emit ""
banner " RESULTS   ${#FILES[@]} file(s), $(hsize "$RAW_TOTAL") raw   baseline gzip -${GZIP_LEVEL} = $(hsize "$GZIP_BYTES")"

printf ' %-18s %12s %8s %11s %10s %10s  %s\n' \
  'CASE' 'TOTAL SIZE' 'RATIO' 'COMPRESS' 'DECOMP' 'VS GZIP' 'ROUND-TRIP'
emit "$LOG_SUB"

for r in "${RESULTS[@]}"; do
  IFS='|' read -r label bytes ratio cms dms failures <<< "$r"
  if [[ "$bytes" == "0" ]]; then
    printf ' %-18s %12s %8s %11s %10s %10s  %s\n' \
      "$label" '-' '-' '-' '-' '-' 'all failed'
    continue
  fi
  vs="$(awk -v g="$GZIP_BYTES" -v b="$bytes" \
        'BEGIN { if (g > 0) printf "%+.1f%%", (b-g)*100.0/g; else printf "n/a" }')"
  rt="ok"; (( failures > 0 )) && rt="${failures} FAILED"
  printf ' %-18s %12s %7sx %11s %10s %10s  %s\n' \
    "$label" "$(hsize "$bytes")" "$ratio" "$(hms "$cms")" "$(hms "$dms")" "$vs" "$rt"
done

emit "$LOG_SUB"
cont "VS GZIP: negative is smaller than today's archives."

# ═══════════════════════════════════════════════════════════════════════════
# PART 9  SIZE BUCKETS
#
# The answer to "does one database predict four hundred": ratio by file size.
# If the small bucket is much worse than the large one, an estate dominated by
# small databases will not see the headline number.
# ═══════════════════════════════════════════════════════════════════════════

if (( ${#PER_FILE[@]} > 1 )); then
  emit ""
  banner " RATIO BY FILE SIZE   ($BUCKET_LABEL)"
  printf ' %-16s %7s %14s %14s %8s\n' 'BUCKET' 'FILES' 'RAW' 'COMPRESSED' 'RATIO'
  emit "$LOG_SUB"

  for bucket in small mid large; do
    case "$bucket" in
      small) lo=0;             hi=$SMALL_BUCKET; name="< 1 MiB" ;;
      mid)   lo=$SMALL_BUCKET; hi=$LARGE_BUCKET; name="1 - 100 MiB" ;;
      large) lo=$LARGE_BUCKET; hi=0;             name="> 100 MiB" ;;
    esac
    n=0; braw=0; bcomp=0
    for p in "${PER_FILE[@]}"; do
      IFS='|' read -r raw comp <<< "$p"
      if (( hi == 0 )); then (( raw >= lo )) || continue
      else (( raw >= lo && raw < hi )) || continue; fi
      n=$(( n + 1 )); braw=$(( braw + raw )); bcomp=$(( bcomp + comp ))
    done
    (( n == 0 )) && continue
    br="$(awk -v r="$braw" -v c="$bcomp" 'BEGIN { printf "%.2f", r/c }')"
    printf ' %-16s %7s %14s %14s %7sx\n' \
      "$name" "$n" "$(hsize "$braw")" "$(hsize "$bcomp")" "$br"
  done
  emit "$LOG_SUB"
  cont "A big gap between the small and large rows means your estate-wide"
  cont "ratio will track whichever bucket holds most of your bytes."
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 10  PROJECTION
#
# The sample scaled to the real estate. Compression time is divided by
# PARALLEL because logical.sh runs that many dumps at once.
# ═══════════════════════════════════════════════════════════════════════════

if (( ESTATE_BYTES > 0 )); then
  SCALE="$(awk -v e="$ESTATE_BYTES" -v s="$RAW_TOTAL" 'BEGIN { printf "%.4f", e/s }')"
  emit ""
  banner " PROJECTED ONTO $(hsize "$ESTATE_BYTES")${DB_TOTAL:+ across $DB_TOTAL databases}"
  printf ' %-18s %14s %14s  %s\n' 'CASE' 'ARCHIVE SIZE' 'COMPRESS' 'SAVED VS GZIP'
  emit "$LOG_SUB"
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r label bytes ratio cms dms failures <<< "$r"
    (( bytes > 0 )) || continue
    pb="$(awk -v b="$bytes" -v s="$SCALE" 'BEGIN { printf "%d", b*s }')"
    pm="$(awk -v m="$cms" -v s="$SCALE" -v p="$PARALLEL" 'BEGIN { printf "%d", m*s/p }')"
    sv="$(awk -v g="$GZIP_BYTES" -v b="$bytes" -v s="$SCALE" \
          'BEGIN { printf "%d", (g-b)*s }')"
    svh="$( (( sv > 0 )) && printf '%s saved' "$(hsize "$sv")" || printf '%s BIGGER' "$(hsize $((-sv)))" )"
    printf ' %-18s %14s %14s  %s\n' "$label" "$(hsize "$pb")" "$(hms "$pm")" "$svh"
  done
  emit "$LOG_SUB"
  cont "COMPRESS is wall clock at --parallel=$PARALLEL, compression only."
  cont "The real run also spends time in mysqldump, age and the network copy."
else
  emit ""
  info "pass --estate=SIZE (and --dbs=N) to project this onto the real estate"
  cont "e.g. --estate=1.4T --dbs=400 --parallel=$PARALLEL"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 11  RECOMMENDATION
# ═══════════════════════════════════════════════════════════════════════════

emit ""
banner " READING THIS"

BEST_SIZE=""; BEST_SIZE_BYTES=0
BEST_KNEE=""; BEST_KNEE_SCORE=-1

for r in "${RESULTS[@]}"; do
  IFS='|' read -r label bytes ratio cms dms failures <<< "$r"
  (( failures == 0 && bytes > 0 )) || continue
  [[ "$label" == gzip* ]] && continue

  if (( BEST_SIZE_BYTES == 0 )) || (( bytes < BEST_SIZE_BYTES )); then
    BEST_SIZE_BYTES="$bytes"; BEST_SIZE="$label"
  fi
  score="$(awk -v g="$GZIP_BYTES" -v b="$bytes" -v t="$cms" \
           'BEGIN { if (t < 1) t = 1; printf "%d", (g-b)*1000/t }')"
  if (( score > BEST_KNEE_SCORE )); then
    BEST_KNEE_SCORE="$score"; BEST_KNEE="$label"
  fi
done

if [[ -n "$BEST_SIZE" ]]; then
  kv "smallest"   "$BEST_SIZE — $(hsize "$BEST_SIZE_BYTES")"
  kv "best value" "${BEST_KNEE:-none} — most bytes saved per second of CPU"
  sub
  cont "logical.sh runs PARALLEL=$PARALLEL dumps at once on a host also running"
  cont "MySQL, so compression time is shared, not free. If your window has room,"
  cont "take the smallest. If it does not, take the best-value level — the size"
  cont "difference between them is usually under 3%."
  if (( WANT_DICT == 1 )); then
    sub
    cont "Dictionary rows: only adopt one if it clearly beats the plain rows on"
    cont "your small files. The dictionary then becomes a restore dependency and"
    cont "must be published and retained beside the archives, for ever."
  fi
else
  warn "no case round-tripped cleanly — do not change logical.sh on this data"
fi

emit ""
exit 0
