#!/usr/bin/env bash
#
# streaming/tests/zstd_level_bench.sh — measure zstd levels on real dumps
#
# A copy of logical.sh's dump path, instrumented instead of publishing. It
# answers one question: which compression level should logical.sh use on THIS
# estate. Nothing is written to the share and no archive is published, so it is
# safe to point at a VM holding a copy of production.
#
# Each database is dumped ONCE, then that same .sql is compressed at every
# requested level. Re-running the whole script per level would re-dump every
# database each time; this way the comparison is on identical bytes and the run
# costs one dump pass.
#
#   ./zstd_level_bench.sh --server_name=NAME
#   ./zstd_level_bench.sh --server_name=NAME --levels=1,3,6,9,12,15,19
#   ./zstd_level_bench.sh --server_name=NAME --sample=20      # 20 representative dbs
#   ./zstd_level_bench.sh --server_name=NAME --mode=SELECTED --db_list_dir=/Data/script/dblist
#   ./zstd_level_bench.sh --server_name=NAME --age_recipients=/etc/dbvault/recipients.txt
#   ./zstd_level_bench.sh --server_name=NAME --ultra --long
#
# Output: the usual log, plus a CSV of every measurement next to it. Send both.
#
#   PART 1   configuration
#   PART 2   log engine
#   PART 3   failure handling
#   PART 4   probes
#   PART 5   usage and arguments
#   PART 6   single-instance lock
#   PART 7   identity and paths
#   PART 8   pre-flight
#   PART 9   database list and sampling
#   PART 10  benchmark
#   PART 11  aggregate results
#   PART 12  size buckets
#   PART 13  recommendation
#
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# PART 1  CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

# ── 1A  SET PER VM ─────────────────────────────────────────────────────────
MYSQL_USER="__SET_ME__"                              # needs SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER
MYSQL_PASSWORD="__SET_ME__"
MYSQL_HOST="__SET_ME__"                              # the instance to dump; "" = local socket

# ── 1B  TUNING ─────────────────────────────────────────────────────────────
# 1 and 19 are deliberately out of the default. 1 is too weak to ever choose
# for a backup, and 19 costs roughly triple the CPU of 15 to land under 2%
# smaller. Add them with --levels= when you want to see it for yourself.
ZSTD_LEVELS="3,6,9,12,15"                            # --levels= overrides
ULTRA_LEVELS="20,21,22"                              # --ultra appends these
LONG_WINDOW=27                                       # --long= window log, 128 MiB
ZSTD_THREADS=1                                       # -T value; 1 keeps levels comparable
GZIP_LEVEL=6                                         # tar -czf's default, today's baseline
SAMPLE_DBS=0                                         # 0 = every database; N = sample N
BACKUP_MODE="ALL"                                    # ALL or SELECTED; --mode= overrides
DB_LIST_DIR=""                                       # SELECTED: dir of .txt/.csv/.lst
PARALLEL_HINT=3                                      # logical.sh PARALLEL, for the projection
AGE_RECIPIENTS=""                                    # --age_recipients=; measures encryption too
MEASURE_CPU=0                                        # --cpu; record CPU seconds and peak RAM
TIME_BIN="/usr/bin/time"                             # GNU time, not the shell builtin

# --hex-blob is deliberately NOT set: no binary columns in these schemas.
DUMP_OPTS="--single-transaction --quick --routines --events --triggers \
--set-gtid-purged=OFF --default-character-set=utf8mb4 \
--net-buffer-length=1M"

# ── 1C  SHARED ─────────────────────────────────────────────────────────────
LOCAL_STAGE="/Data/dbvault-stage"                    # logs and dump staging
LOCK_DIR="/var/lock/dbvault"

# ── 1D  NOT SET HERE ───────────────────────────────────────────────────────
MYSQL_BIN="${MYSQL_BIN:-}"                           # PATH
MYSQLDUMP_BIN="${MYSQLDUMP_BIN:-}"                   # PATH
SERVER_NAME=""                                       # --server_name=

# ── 1E  GUARD ──────────────────────────────────────────────────────────────
SET_ME_VARS=(MYSQL_USER MYSQL_PASSWORD MYSQL_HOST)

check_set_me() {
  local v
  local -a missing=()
  for v in "${SET_ME_VARS[@]}"; do
    if [[ "${!v}" == "__SET_ME__" ]]; then missing+=("$v"); fi
  done
  if (( ${#missing[@]} == 0 )); then return 0; fi
  {
    printf '[ERROR] %s has not been configured for this host.\n' "${BASH_SOURCE[0]##*/}"
    printf '        Open it, find PART 1A, and replace __SET_ME__ in:\n'
    printf '          %s\n' "${missing[@]}"
    printf '        Nothing has been read, written or deleted.\n'
  } >&2
  exit 1
}

# ═══════════════════════════════════════════════════════════════════════════
# PART 2  LOG ENGINE
# ═══════════════════════════════════════════════════════════════════════════

RUN_LOG=""
ERROR_LOG=""
CSV_FILE=""
PHASE="init"
STEP="-"
WARN_COUNT=0

LOG_RULE='=========================================================================='
LOG_SUB='--------------------------------------------------------------------------'
LOG_DOTS='..........................................................................'

emit() {
  printf '%s\n' "$1"
  [[ -n "$RUN_LOG" && -d "${RUN_LOG%/*}" ]] && printf '%s\n' "$1" >> "$RUN_LOG"
  return 0
}

emit_err() {
  printf '%s\n' "$1" >&2
  [[ -n "$RUN_LOG"   && -d "${RUN_LOG%/*}" ]] && printf '%s\n' "$1" >> "$RUN_LOG"
  [[ -n "$ERROR_LOG" && -f "$ERROR_LOG"    ]] && printf '%s\n' "$1" >> "$ERROR_LOG"
  return 0
}

banner() { emit "$LOG_RULE"; emit "$1"; emit "$LOG_RULE"; }
sub()    { emit "$LOG_SUB"; }
kv()     { emit "$(printf ' %-18s: %s' "$1" "$2")"; }

tag()  { printf '[%s %s]' "$PHASE" "$STEP"; }
info() { emit     "$(printf '%s %-5s %-17s %s' "$(date +%T)" 'INFO'  "$(tag)" "$1")"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1))
         emit     "$(printf '%s %-5s %-17s %s' "$(date +%T)" 'WARN'  "$(tag)" "$1")"; }
erro() { emit_err "$(printf '%s %-5s %-17s %s' "$(date +%T)" 'ERROR' "$(tag)" "$1")"; }
cont() { emit     "$(printf '%-32s %s' '' "$1")"; }
cerr() { emit_err "$(printf '%-32s %s' '' "$1")"; }

leader() {
  local pad=$(( 44 - ${#1} - ${#2} ))
  (( pad < 3 )) && pad=3
  printf '%s %s %s' "$1" "${LOG_DOTS:0:$pad}" "$2"
}
ok()  { info "$(leader "$1" 'OK')"; }
val() { info "$(leader "$1" "$2")"; }
nok() { warn "$(leader "$1" "$2")"; }
skp() { info "$(leader "$1" "$2")"; }

# cont() indents under the log's timestamp column. A caption printed beneath a
# results table has no timestamp above it, so it gets a plain indent instead.
note() { emit "$(printf '   %s' "$1")"; }

CHECK_N=0
CHECK_TOTAL=9
PHASE_EPOCH=0

phase() { PHASE="$1"; STEP="${2:--}"; PHASE_EPOCH="$(date +%s)"; }
check() { PHASE="preflight"; CHECK_N=$((CHECK_N + 1))
          STEP="$(printf '%02d/%02d' "$CHECK_N" "$CHECK_TOTAL")"; }

elapsed() {
  local d=$(( $(date +%s) - $1 ))
  if (( d < 60 )); then printf '%ds' "$d"; else printf '%dm%02ds' $((d / 60)) $((d % 60)); fi
}

hsize() {
  numfmt --to=iec-i --suffix=B "$1" 2>/dev/null \
    || awk -v b="$1" 'BEGIN { printf "%.1fGiB", b/1073741824 }'
}

# Milliseconds to something comparable to a backup window.
hms() {
  awk -v ms="$1" 'BEGIN {
    s = ms / 1000
    if (s < 90)   { printf "%.0fs", s; exit }
    if (s < 5400) { printf "%dm%02ds", int(s/60), int(s)%60; exit }
    printf "%dh%02dm", int(s/3600), int((s%3600)/60)
  }'
}

now_ms() { date +%s%3N; }

# ═══════════════════════════════════════════════════════════════════════════
# PART 3  FAILURE HANDLING
# ═══════════════════════════════════════════════════════════════════════════

START_EPOCH="$(date +%s)"
RUN_ID=""
DB_COUNT=0
OK_COUNT=0
FAILED_COUNT=0
FAILED_LIST=""
WORK_DIR=""
BUILD_DIR=""

DIED=0
INTERRUPTED=0
FAILED_CMD=""
FAILED_LINE=""
FAILED_RC=""

fail_run() {
  trap - ERR INT TERM HUP
  local at="$PHASE $STEP"
  emit ""
  banner " BENCHMARK FAILED  ${SERVER_NAME:-(no server)}  ${RUN_ID:-(no run)}"
  kv "failed in" "$at"
  if [[ ${INTERRUPTED:-0} -eq 1 ]]; then
    kv "cause" "interrupted — Ctrl-C or kill"
  elif [[ ${DIED:-0} -eq 0 && -n "${FAILED_CMD:-}" ]]; then
    kv "cause"          "uncaught failure — no check reported this"
    kv "failed command" "$FAILED_CMD"
    kv "at line"        "${FAILED_LINE:-?}  (exit ${FAILED_RC:-?})"
  fi
  kv "duration"  "$(elapsed "$START_EPOCH")"
  kv "log"       "${RUN_LOG:-(none)}"
  kv "csv"       "${CSV_FILE:-(none)}"
  sub
  # Nothing was published anywhere, so cleanup is only this run's staging.
  [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR" 2>/dev/null
  banner " RESULT failed server=${SERVER_NAME:-none} dbs=${DB_COUNT} ok=${OK_COUNT} warn=${WARN_COUNT}"
  exit 1
}

die() { DIED=1; erro "$1"; shift; local l; for l in "$@"; do cerr "$l"; done; fail_run; }

on_err() {
  FAILED_RC=$?
  FAILED_CMD="$BASH_COMMAND"
  FAILED_LINE="${BASH_LINENO[0]}"
  fail_run
}

trap on_err ERR
# HUP is in here because this runs for hours over SSH. Without it a dropped
# connection kills the script on the default SIGHUP action, leaving the staged
# .sql of whichever database was mid-run behind in LOCAL_STAGE.
trap 'INTERRUPTED=1; fail_run' INT TERM HUP

# ═══════════════════════════════════════════════════════════════════════════
# PART 4  PROBES
# ═══════════════════════════════════════════════════════════════════════════

# -h is omitted entirely when MYSQL_HOST is empty: that is what selects the
# local socket rather than a TCP connection to 'localhost'.
mysql_args() {
  printf '%s\n' -u"$MYSQL_USER" -p"$MYSQL_PASSWORD"
  [[ -n "$MYSQL_HOST" ]] && printf '%s\n' -h"$MYSQL_HOST"
  return 0
}

mysql_q() {
  local a; mapfile -t a < <(mysql_args)
  "$MYSQL_BIN" "${a[@]}" -NBe "$1" 2>>"${ERROR_LOG:-/dev/null}"
}

writable() {
  local probe="$1/.probe_$$"
  touch "$probe" 2>/dev/null || return 1
  rm -f "$probe"
  return 0
}

resolve_bin() {
  local var="$1" name="$2"
  local path="${!var}"
  if [[ -n "$path" ]]; then
    if [[ -x "$path" ]]; then return 0; fi
    echo "[ERROR] $var is set to '$path', which is not an executable file." >&2
    exit 1
  fi
  path="$(command -v "$name" 2>/dev/null || true)"
  if [[ -z "$path" ]]; then
    echo "[ERROR] '$name' is not in PATH — install it, or run with $var=/full/path/to/$name" >&2
    exit 1
  fi
  printf -v "$var" '%s' "$path"
}

# ═══════════════════════════════════════════════════════════════════════════
# PART 5  USAGE AND ARGUMENTS
# ═══════════════════════════════════════════════════════════════════════════

usage() {
  cat <<EOF
Usage: $0 --server_name=NAME [--levels=1,3,9] [--sample=N] [--mysql_host=HOST]
          [--mode=ALL|SELECTED] [--db_list_dir=PATH]
          [--age_recipients=PATH] [--ultra] [--long] [--threads=N]

  Dumps each database once, compresses that .sql at every level, measures.
  Nothing is published. Nothing on the share is touched.

  --server_name=NAME     names the log and CSV files
  --levels=LIST          comma-separated zstd levels (default: $ZSTD_LEVELS)
  --sample=N             benchmark N representative databases, not all of them
  --mysql_host=HOST      instance to dump (default: $MYSQL_HOST; empty = local socket)
  --mode=ALL|SELECTED    ALL = every non-system schema (default: $BACKUP_MODE)
  --db_list_dir=PATH     SELECTED only: directory of .txt/.csv/.lst, newest wins
  --age_recipients=PATH  also measure age encryption using this recipients file
  --ultra                add levels $ULTRA_LEVELS (slow, needs a big window to decompress)
  --long                 also test --long=$LONG_WINDOW at every level
  --cpu                  also record CPU seconds and peak RAM per compressor
  --threads=N            zstd -T value (default: $ZSTD_THREADS; 0 = all cores)

Examples:
  $0 --server_name=Cloud-Live-DB-Default --sample=25
  $0 --server_name=GSP-Cloud-Live-DB --levels=3,9,12,15,19 --long
EOF
  trap - ERR INT TERM HUP
  exit 1
}

argfail() { echo "[ERROR] $1" >&2; trap - ERR INT TERM HUP; exit 1; }

[[ $# -ge 1 ]] || usage

WANT_ULTRA=0
WANT_LONG=0

for arg in "$@"; do
  case "$arg" in
    --server_name=*)     SERVER_NAME="${arg#*=}" ;;
    --levels=*)          ZSTD_LEVELS="${arg#*=}" ;;
    --sample=*)          SAMPLE_DBS="${arg#*=}" ;;
    --mysql_host=*)      MYSQL_HOST="${arg#*=}" ;;
    --mode=*)            BACKUP_MODE="${arg#*=}" ;;
    --db_list_dir=*)     DB_LIST_DIR="${arg#*=}" ;;
    --age_recipients=*)  AGE_RECIPIENTS="${arg#*=}" ;;
    --threads=*)         ZSTD_THREADS="${arg#*=}" ;;
    --parallel=*)        PARALLEL_HINT="${arg#*=}" ;;
    --ultra)             WANT_ULTRA=1 ;;
    --long)              WANT_LONG=1 ;;
    --cpu)               MEASURE_CPU=1 ;;
    -h|--help)           usage ;;
    *) echo "[ERROR] Unknown argument: $arg" >&2; usage ;;
  esac
done

check_set_me

resolve_bin MYSQL_BIN     mysql
resolve_bin MYSQLDUMP_BIN mysqldump

[[ -n "$SERVER_NAME" ]] || argfail "--server_name is required"
[[ "$SERVER_NAME" =~ ^[A-Za-z0-9._-]+$ ]] \
  || argfail "Invalid --server_name: $SERVER_NAME (expected [A-Za-z0-9._-]+)"

case "$BACKUP_MODE" in
  ALL) ;;
  SELECTED) [[ -n "$DB_LIST_DIR" ]] || argfail "--mode=SELECTED needs --db_list_dir" ;;
  *) argfail "Invalid --mode: $BACKUP_MODE (expected ALL or SELECTED)" ;;
esac

[[ "$SAMPLE_DBS"    =~ ^[0-9]+$ ]] || argfail "--sample must be a number, got '$SAMPLE_DBS'"
[[ "$ZSTD_THREADS"  =~ ^[0-9]+$ ]] || argfail "--threads must be a number, got '$ZSTD_THREADS'"
[[ "$PARALLEL_HINT" =~ ^[1-9][0-9]*$ ]] || argfail "--parallel must be a positive integer"

(( WANT_ULTRA == 1 )) && ZSTD_LEVELS="${ZSTD_LEVELS},${ULTRA_LEVELS}"

IFS=',' read -r -a LEVEL_ARR <<< "$ZSTD_LEVELS"
for lv in "${LEVEL_ARR[@]}"; do
  [[ "$lv" =~ ^[0-9]+$ ]] || argfail "Bad level '$lv' in --levels=$ZSTD_LEVELS"
  (( lv >= 1 && lv <= 22 )) || argfail "Level $lv out of range (1-22)"
  (( lv >= 20 )) && (( WANT_ULTRA == 0 )) \
    && argfail "Level $lv needs --ultra (20-22 need a big window to DECOMPRESS too)"
done

# ═══════════════════════════════════════════════════════════════════════════
# PART 6  SINGLE-INSTANCE LOCK
# ═══════════════════════════════════════════════════════════════════════════

mkdir -p "$LOCK_DIR" "$LOCAL_STAGE" 2>/dev/null || true
exec 200>"${LOCK_DIR}/zstd_level_bench_${SERVER_NAME}.lock"
if ! flock -n 200; then
  echo "[ERROR] Another benchmark is already running for $SERVER_NAME." >&2
  trap - ERR INT TERM HUP
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 7  IDENTITY AND PATHS
#
# Everything stays on local disk. There is no share, no publish, no manifest.
# ═══════════════════════════════════════════════════════════════════════════

RUN_ID="$(date +%Y-%m-%d_%H-%M-%S)"
RUN_STAMP="$(date +%Y%m%d_%H%M%S)"
RUN_LOG="${LOCAL_STAGE}/${SERVER_NAME}_bench_${RUN_STAMP}.log"
ERROR_LOG="${LOCAL_STAGE}/${SERVER_NAME}_bench_${RUN_STAMP}_errors.log"
CSV_FILE="${LOCAL_STAGE}/${SERVER_NAME}_bench_${RUN_STAMP}.csv"

WORK_DIR="${LOCAL_STAGE}/.bench_${SERVER_NAME}_${RUN_STAMP}"
BUILD_DIR="${WORK_DIR}/build"

mkdir -p "$WORK_DIR" "$BUILD_DIR" 2>/dev/null || {
  echo "[ERROR] Failed to create $WORK_DIR" >&2
  trap - ERR INT TERM HUP; exit 1; }
chmod 700 "$WORK_DIR" 2>/dev/null || true

printf 'errors for benchmark of %s run %s\n\n' "$SERVER_NAME" "$RUN_ID" > "$ERROR_LOG"
# The CPU columns are always present, empty when --cpu was not given, so every
# CSV this script has ever written has the same shape and one reader handles all.
printf 'database,raw_bytes,case,comp_bytes,comp_ms,decomp_ms,roundtrip,user_s,sys_s,max_rss_kb\n' > "$CSV_FILE"

banner " ZSTD LEVEL BENCHMARK  $SERVER_NAME  $RUN_ID"
kv "started"     "$(date '+%F %T %Z')"
kv "host"        "$(hostname -s 2>/dev/null || echo unknown)"
kv "source"      "${MYSQL_HOST:-local socket}"
kv "levels"      "$ZSTD_LEVELS"
kv "threads"     "-T$ZSTD_THREADS$( (( ZSTD_THREADS == 0 )) && printf ' (all cores)')"
kv "long window" "$( (( WANT_LONG == 1 )) && printf -- "--long=%s as extra cases" "$LONG_WINDOW" || printf 'not tested')"
kv "age"         "${AGE_RECIPIENTS:-not measured}"
kv "mode"        "$BACKUP_MODE"
kv "sample"      "$( (( SAMPLE_DBS > 0 )) && printf '%s databases' "$SAMPLE_DBS" || printf 'every database')"
kv "staging"     "$BUILD_DIR"
kv "log"         "$RUN_LOG"
kv "csv"         "$CSV_FILE"
sub
info "nothing is published — the share is never written to"
sub

# ═══════════════════════════════════════════════════════════════════════════
# PART 8  PRE-FLIGHT
# ═══════════════════════════════════════════════════════════════════════════

phase preflight
PREFLIGHT_EPOCH="$PHASE_EPOCH"

check
for cmd in mysql mysqldump zstd gzip sha256sum awk find sort df stat flock nice ionice numfmt; do
  command -v "$cmd" >/dev/null 2>&1 \
    || die "$(leader 'required binaries' 'MISSING')" \
           "not found in PATH: $cmd" \
           "on Ubuntu: sudo apt install zstd coreutils"
done
ok "required binaries"

# The shell's own `time` keyword cannot report peak memory and cannot write to
# a file, so GNU time is required rather than optional. It is a separate
# package on Ubuntu and is NOT installed by default.
check
if (( MEASURE_CPU == 1 )); then
  [[ -x "$TIME_BIN" ]] \
    || die "$(leader 'cpu measurement' 'GNU TIME MISSING')" \
           "$TIME_BIN is not installed" \
           "sudo apt install time" \
           "(the shell builtin 'time' cannot report peak memory)"
  "$TIME_BIN" -f '%U %S %M %P' -o /dev/null true 2>/dev/null \
    || die "$(leader 'cpu measurement' 'GNU TIME REJECTED')" \
           "$TIME_BIN does not accept -f/-o — is it BSD time?"
  val "cpu measurement" "$TIME_BIN"
else
  skp "cpu measurement" "not measured (--cpu)"
fi

check
if [[ -n "$AGE_RECIPIENTS" ]]; then
  command -v age >/dev/null 2>&1 \
    || die "$(leader 'age' 'MISSING')" "sudo apt install age"
  [[ -r "$AGE_RECIPIENTS" ]] \
    || die "$(leader 'age' 'RECIPIENTS UNREADABLE')" "$AGE_RECIPIENTS"
  # Prove the recipients file actually works before dumping anything.
  : | age -R "$AGE_RECIPIENTS" >/dev/null 2>>"$ERROR_LOG" \
    || die "$(leader 'age' 'RECIPIENTS REJECTED')" \
           "age will not encrypt to $AGE_RECIPIENTS" \
           "check every line is a valid age1... public key"
  val "age" "$(grep -c '^age1' "$AGE_RECIPIENTS" || echo 0) recipient(s)"
else
  skp "age" "not measured (--age_recipients=)"
fi

check
writable "$LOCAL_STAGE" \
  || die "$(leader 'local stage writable' 'NO')" "not writable: $LOCAL_STAGE"
ok "local stage writable"

check
mysql_q "SELECT 1" >/dev/null \
  || die "$(leader 'mysql connection' 'FAILED')" \
         "user $MYSQL_USER at ${MYSQL_HOST:-local socket}"
ok "mysql connection"

check
CORES="$(nproc 2>/dev/null || echo 0)"
val "cores" "${CORES:-?}"

check
STAGE_AVAIL="$(df -Pk "$LOCAL_STAGE" 2>/dev/null | tail -1 | awk '{print $4}')"
[[ "$STAGE_AVAIL" =~ ^[0-9]+$ ]] || STAGE_AVAIL=0
STAGE_AVAIL=$(( STAGE_AVAIL * 1024 ))
val "stage free" "$(hsize "$STAGE_AVAIL")"

# The largest schema has to fit as an uncompressed .sql plus one archive. This
# is the check that stops a benchmark filling the root filesystem of the host
# that is also running MySQL.
check
BIGGEST_DB_BYTES="$(mysql_q "
  SELECT COALESCE(MAX(s),0) FROM (
    SELECT SUM(data_length + index_length) AS s
    FROM information_schema.tables
    WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys')
    GROUP BY table_schema) t" 2>/dev/null || echo 0)"
BIGGEST_DB_BYTES="${BIGGEST_DB_BYTES:-0}"
[[ "$BIGGEST_DB_BYTES" =~ ^[0-9]+$ ]] || BIGGEST_DB_BYTES=0
# Databases are done one at a time, so the peak is ONE database: its .sql plus
# the compressed output beside it. x2 of the on-disk size is the safety margin
# — a text dump is usually smaller than data_length+index_length, but a schema
# full of numbers and dates can invert that.
NEED=$(( BIGGEST_DB_BYTES * 2 ))
if (( STAGE_AVAIL > 0 && NEED > 0 && STAGE_AVAIL < NEED )); then
  die "$(leader 'stage space' 'NOT ENOUGH')" \
      "largest schema is $(hsize "$BIGGEST_DB_BYTES") on disk" \
      "the benchmark needs about $(hsize "$NEED") free in $LOCAL_STAGE" \
      "only $(hsize "$STAGE_AVAIL") is available" \
      "this is peak for ONE database — they are not staged all at once"
fi
val "stage space" "peak ~$(hsize "$NEED") for one db, have $(hsize "$STAGE_AVAIL")"

check
if [[ "$BACKUP_MODE" == "SELECTED" ]]; then
  [[ -d "$DB_LIST_DIR" ]] \
    || die "$(leader 'db list dir' 'NOT A DIRECTORY')" "$DB_LIST_DIR"
  DB_LIST_FILE="$(find "$DB_LIST_DIR" -maxdepth 1 -type f \
                    \( -name '*.txt' -o -name '*.csv' -o -name '*.lst' \) \
                    -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)"
  [[ -n "$DB_LIST_FILE" ]] \
    || die "$(leader 'db list dir' 'EMPTY')" "no .txt/.csv/.lst in $DB_LIST_DIR"
  val "db list dir" "$(basename "$DB_LIST_FILE")"
else
  DB_LIST_FILE=""
  skp "db list dir" "n/a (mode=ALL)"
fi

STEP="-"
info "$CHECK_N checks passed, ${WARN_COUNT} warning(s)   ($(elapsed "$PREFLIGHT_EPOCH"))"
sub

# ═══════════════════════════════════════════════════════════════════════════
# PART 9  DATABASE LIST AND SAMPLING
#
# --sample picks across the SIZE distribution rather than the first N
# alphabetically. An estate of 400 is mostly small schemas; a sample that
# misses the large ones predicts the wrong ratio and the wrong runtime.
# ═══════════════════════════════════════════════════════════════════════════

phase list 1/3

if [[ "$BACKUP_MODE" == "ALL" ]]; then
  DATABASES="$(mysql_q "SHOW DATABASES" \
                | grep -Ev '^(information_schema|performance_schema|mysql|sys)$' || true)"
else
  info "reading $DB_LIST_FILE"
  DATABASES="$(grep -vE '^[[:space:]]*$|^[[:space:]]*#' "$DB_LIST_FILE" || true)"
fi

TOTAL_DBS="$(printf '%s\n' "$DATABASES" | grep -c '[^[:space:]]' || true)"
TOTAL_DBS="${TOTAL_DBS:-0}"
[[ "$TOTAL_DBS" -gt 0 ]] || die "$(leader 'database list' 'EMPTY')" \
  "mode=$BACKUP_MODE, source=${MYSQL_HOST:-local socket}"

val "databases found" "$TOTAL_DBS"

# Estate size, so the sample can be projected back onto the whole run.
ESTATE_BYTES="$(mysql_q "
  SELECT COALESCE(SUM(data_length + index_length),0)
  FROM information_schema.tables
  WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys')" \
  2>/dev/null || echo 0)"
[[ "$ESTATE_BYTES" =~ ^[0-9]+$ ]] || ESTATE_BYTES=0
(( ESTATE_BYTES > 0 )) && val "estate on disk" "$(hsize "$ESTATE_BYTES")"

if (( SAMPLE_DBS > 0 && SAMPLE_DBS < TOTAL_DBS )); then
  # Rank by size, then take from the top, middle and bottom in equal parts.
  RANKED="$(mysql_q "
    SELECT table_schema
    FROM information_schema.tables
    WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys')
    GROUP BY table_schema
    ORDER BY SUM(data_length + index_length) DESC" 2>/dev/null || true)"

  # Keep only names that survived the mode filter above.
  FILTERED=""
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    grep -qxF "$d" <<< "$DATABASES" && FILTERED="${FILTERED}${d}"$'\n'
  done <<< "$RANKED"

  mapfile -t RANK_ARR < <(printf '%s' "$FILTERED" | grep '[^[:space:]]' || true)
  RN="${#RANK_ARR[@]}"
  if (( RN == 0 )); then
    nok "sampling" "NO SIZE DATA"
    cont "information_schema returned nothing usable — benchmarking all $TOTAL_DBS"
  else
    third=$(( SAMPLE_DBS / 3 )); (( third < 1 )) && third=1
    declare -A PICKED=()
    SELECTED_LIST=""
    add_pick() {
      local idx="$1" name
      (( idx >= 0 && idx < RN )) || return 0
      name="${RANK_ARR[$idx]}"
      [[ -n "${PICKED[$name]:-}" ]] && return 0
      PICKED["$name"]=1
      SELECTED_LIST="${SELECTED_LIST}${name}"$'\n'
      return 0
    }
    for ((i = 0; i < third; i++)); do add_pick "$i"; done                       # largest
    mid=$(( RN / 2 - third / 2 ))
    for ((i = 0; i < third; i++)); do add_pick $(( mid + i )); done             # median
    for ((i = 0; i < third; i++)); do add_pick $(( RN - 1 - i )); done          # smallest
    # Top up to exactly SAMPLE_DBS by walking the ranking.
    i=0
    while (( ${#PICKED[@]} < SAMPLE_DBS && i < RN )); do add_pick "$i"; i=$((i + 1)); done

    DATABASES="$(printf '%s' "$SELECTED_LIST" | grep '[^[:space:]]' || true)"
    val "sampled" "${#PICKED[@]} of $TOTAL_DBS, across the size range"
    cont "largest, median and smallest thirds — not the first N alphabetically"
  fi
fi

DB_COUNT="$(printf '%s\n' "$DATABASES" | grep -c '[^[:space:]]' || true)"
DB_COUNT="${DB_COUNT:-0}"
val "benchmarking" "$DB_COUNT database(s)"

# ═══════════════════════════════════════════════════════════════════════════
# PART 10  BENCHMARK
#
# Serial on purpose. Parallel dumps would contend for CPU and make every
# timing meaningless; PARALLEL_HINT is applied to the projection instead.
# ═══════════════════════════════════════════════════════════════════════════

phase bench 2/3

CASES=()                       # ordered case labels
declare -A C_BYTES=() C_CMS=() C_DMS=() C_FAIL=()
declare -A C_USER=() C_SYS=() C_RSS=()          # --cpu only; empty otherwise

add_case() {
  local c="$1"
  CASES+=("$c")
  C_BYTES["$c"]=0; C_CMS["$c"]=0; C_DMS["$c"]=0; C_FAIL["$c"]=0
  C_USER["$c"]=0;  C_SYS["$c"]=0;  C_RSS["$c"]=0
}

add_case "gzip -${GZIP_LEVEL}"
for lv in "${LEVEL_ARR[@]}"; do add_case "zstd -${lv}"; done
if (( WANT_LONG == 1 )); then
  for lv in "${LEVEL_ARR[@]}"; do add_case "zstd -${lv} long"; done
fi
[[ -n "$AGE_RECIPIENTS" ]] && add_case "zstd -9 +age"

RAW_TOTAL=0
declare -A BUCKET_RAW=() BUCKET_COMP=() BUCKET_N=()
BUCKET_CASE=""
SMALL_BUCKET=1048576
LARGE_BUCKET=104857600

# Runs one compressor over one .sql, verifies the round-trip, records it.
measure() {
  local label="$1" db="$2" sql="$3" raw="$4"; shift 4
  local out="${BUILD_DIR}/out.bin"
  local t0 t1 cms dms bytes rt back_sha

  local tf="${BUILD_DIR}/.rusage" user_s="" sys_s="" rss_kb=""
  rm -f "$out" "$tf"
  t0="$(now_ms)"
  if (( MEASURE_CPU == 1 )); then
    # GNU time reports the CHILD's own rusage, so this is the compressor's cost
    # alone — not the shell's, and not whatever else the box is doing.
    if ! "$TIME_BIN" -f '%U %S %M' -o "$tf" "$@" < "$sql" > "$out" 2>>"$ERROR_LOG"; then
      C_FAIL["$label"]=$(( ${C_FAIL["$label"]} + 1 ))
      printf '%s,%s,%s,,,,compress failed,,,\n' "$db" "$raw" "$label" >> "$CSV_FILE"
      rm -f "$out" "$tf"; return 0
    fi
  elif ! "$@" < "$sql" > "$out" 2>>"$ERROR_LOG"; then
    C_FAIL["$label"]=$(( ${C_FAIL["$label"]} + 1 ))
    printf '%s,%s,%s,,,,compress failed,,,\n' "$db" "$raw" "$label" >> "$CSV_FILE"
    rm -f "$out"; return 0
  fi
  t1="$(now_ms)"; cms=$(( t1 - t0 ))
  bytes="$(stat -c%s "$out")"

  if (( MEASURE_CPU == 1 )) && [[ -s "$tf" ]]; then
    read -r user_s sys_s rss_kb < "$tf" || true
    # Milliseconds, to stay integer for the running totals.
    C_USER["$label"]=$(( ${C_USER["$label"]:-0} + $(awk -v x="${user_s:-0}" 'BEGIN{printf "%d", x*1000}') ))
    C_SYS["$label"]=$((  ${C_SYS["$label"]:-0}  + $(awk -v x="${sys_s:-0}"  'BEGIN{printf "%d", x*1000}') ))
    (( ${rss_kb:-0} > ${C_RSS["$label"]:-0} )) && C_RSS["$label"]="$rss_kb"
  fi
  rm -f "$tf"

  # An age case is never decrypted here: the private key is deliberately not on
  # this host, so there is nothing to time and nothing to verify against. Its
  # size and compress time are still the real numbers.
  # Piped straight into sha256sum rather than written out and hashed: a
  # decompressed copy on disk would double the peak staging footprint for
  # nothing. The hash cost is inside the timing, but it is the same cost for
  # every case, so the comparison between them still holds.
  dms=0
  back_sha=""
  if [[ "$label" != *"+age" ]]; then
    t0="$(now_ms)"
    case "$label" in
      gzip*) back_sha="$(gzip -dc < "$out" 2>/dev/null | sha256sum | awk '{print $1}')" ;;
      *)     back_sha="$(zstd -dc --long="$LONG_WINDOW" < "$out" 2>/dev/null \
                          | sha256sum | awk '{print $1}')" ;;
    esac
    t1="$(now_ms)"; dms=$(( t1 - t0 ))
  fi

  if [[ "$label" == *"+age" ]]; then
    rt="not verified (no private key)"
  elif [[ "$back_sha" == "$SQL_SHA" ]]; then
    rt="ok"
  else
    rt="ROUND-TRIP FAILED"
    C_FAIL["$label"]=$(( ${C_FAIL["$label"]} + 1 ))
  fi

  C_BYTES["$label"]=$(( ${C_BYTES["$label"]} + bytes ))
  C_CMS["$label"]=$((   ${C_CMS["$label"]}   + cms ))
  C_DMS["$label"]=$((   ${C_DMS["$label"]}   + dms ))

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$db" "$raw" "$label" "$bytes" "$cms" "$dms" "$rt" \
    "${user_s:-}" "${sys_s:-}" "${rss_kb:-}" >> "$CSV_FILE"

  # Bucket on the first zstd case, so the size breakdown has one consistent basis.
  if [[ -z "$BUCKET_CASE" && "$label" == zstd* && "$label" != *"+age" ]]; then
    BUCKET_CASE="$label"
  fi
  if [[ "$label" == "$BUCKET_CASE" ]]; then
    local b
    if   (( raw <  SMALL_BUCKET )); then b=small
    elif (( raw <  LARGE_BUCKET )); then b=mid
    else                                 b=large
    fi
    BUCKET_N["$b"]=$((    ${BUCKET_N["$b"]:-0}    + 1 ))
    BUCKET_RAW["$b"]=$((  ${BUCKET_RAW["$b"]:-0}  + raw ))
    BUCKET_COMP["$b"]=$(( ${BUCKET_COMP["$b"]:-0} + bytes ))
  fi
  rm -f "$out"
  return 0
}

DB_N=0
while IFS= read -r DB; do
  [[ -n "$DB" ]] || continue
  DB_N=$(( DB_N + 1 ))
  STEP="$(printf '%d/%d' "$DB_N" "$DB_COUNT")"

  SQL="${BUILD_DIR}/${DB}.sql"
  ERR="${BUILD_DIR}/.err_${DB}"
  mapfile -t A < <(mysql_args)

  # 1. dump once
  T0="$(now_ms)"
  # shellcheck disable=SC2086  # DUMP_OPTS is a deliberate word-split option list
  if ! nice -n 19 ionice -c2 -n7 \
       "$MYSQLDUMP_BIN" "${A[@]}" $DUMP_OPTS --databases "$DB" > "$SQL" 2>"$ERR"; then
    REASON="$(grep -v '\[Warning\].*password' "$ERR" 2>/dev/null | head -1 || true)"
    erro "$(leader "$DB" 'DUMP FAILED')"
    cerr "${REASON:-unknown error}"
    rm -f "$SQL" "$ERR" 2>/dev/null || true
    FAILED_COUNT=$(( FAILED_COUNT + 1 ))
    FAILED_LIST="${FAILED_LIST}${DB} "
    continue
  fi
  T1="$(now_ms)"; DUMP_MS=$(( T1 - T0 ))
  rm -f "$ERR" 2>/dev/null || true

  if [[ ! -s "$SQL" ]]; then
    erro "$(leader "$DB" 'EMPTY DUMP')"
    rm -f "$SQL" 2>/dev/null || true
    FAILED_COUNT=$(( FAILED_COUNT + 1 ))
    FAILED_LIST="${FAILED_LIST}${DB} "
    continue
  fi

  RAW="$(stat -c%s "$SQL")"
  RAW_TOTAL=$(( RAW_TOTAL + RAW ))
  SQL_SHA="$(sha256sum "$SQL" | awk '{print $1}')"
  OK_COUNT=$(( OK_COUNT + 1 ))

  printf '%s,%s,dump,,%s,,ok,,,\n' "$DB" "$RAW" "$DUMP_MS" >> "$CSV_FILE"
  info "$(leader "$DB" "$(hsize "$RAW") dumped in $(hms "$DUMP_MS")")"

  # 2. every case over the same bytes
  measure "gzip -${GZIP_LEVEL}" "$DB" "$SQL" "$RAW" gzip -"${GZIP_LEVEL}" -c
  for lv in "${LEVEL_ARR[@]}"; do
    if (( lv >= 20 )); then
      measure "zstd -${lv}" "$DB" "$SQL" "$RAW" zstd --ultra -"$lv" -T"$ZSTD_THREADS" -c
    else
      measure "zstd -${lv}" "$DB" "$SQL" "$RAW" zstd -"$lv" -T"$ZSTD_THREADS" -c
    fi
  done
  if (( WANT_LONG == 1 )); then
    for lv in "${LEVEL_ARR[@]}"; do
      if (( lv >= 20 )); then
        measure "zstd -${lv} long" "$DB" "$SQL" "$RAW" zstd --ultra -"$lv" --long="$LONG_WINDOW" -T"$ZSTD_THREADS" -c
      else
        measure "zstd -${lv} long" "$DB" "$SQL" "$RAW" zstd -"$lv" --long="$LONG_WINDOW" -T"$ZSTD_THREADS" -c
      fi
    done
  fi
  # The real pipeline shape: compress, then encrypt what came out.
  if [[ -n "$AGE_RECIPIENTS" ]]; then
    measure "zstd -9 +age" "$DB" "$SQL" "$RAW" \
      bash -c "set -o pipefail; zstd -9 -T${ZSTD_THREADS} -c | age -R '${AGE_RECIPIENTS}'"
  fi

  rm -f "$SQL" 2>/dev/null || true
done <<< "$DATABASES"

BENCH_ELAPSED="$(elapsed "$PHASE_EPOCH")"
sub
if (( FAILED_COUNT > 0 )); then
  nok "dumped" "$OK_COUNT/$DB_COUNT  ($FAILED_COUNT failed)"
  cont "failed: $FAILED_LIST"
else
  val "dumped" "$OK_COUNT/$DB_COUNT  $(hsize "$RAW_TOTAL") of SQL  ($BENCH_ELAPSED)"
fi

(( OK_COUNT > 0 )) || die "$(leader 'benchmark' 'NO DATA')" \
  "every database failed to dump — there is nothing to measure"

# ═══════════════════════════════════════════════════════════════════════════
# PART 11  AGGREGATE RESULTS
# ═══════════════════════════════════════════════════════════════════════════

phase report 3/3

GZIP_BYTES="${C_BYTES["gzip -${GZIP_LEVEL}"]}"
(( GZIP_BYTES > 0 )) || GZIP_BYTES=0

emit ""
banner " RESULTS   $OK_COUNT database(s), $(hsize "$RAW_TOTAL") of SQL"

emit "$(printf ' %-18s %13s %8s %11s %10s %10s  %s\n' \
  'CASE' 'TOTAL SIZE' 'RATIO' 'COMPRESS' 'DECOMP' 'VS GZIP' 'ROUND-TRIP')"
emit "$LOG_SUB"

for c in "${CASES[@]}"; do
  b="${C_BYTES["$c"]}"
  if (( b == 0 )); then
    emit "$(printf ' %-18s %13s %8s %11s %10s %10s  %s\n' "$c" '-' '-' '-' '-' '-' 'all failed')"
    continue
  fi
  ratio="$(awk -v r="$RAW_TOTAL" -v x="$b" 'BEGIN { printf "%.2f", r/x }')"
  vs="$(awk -v g="$GZIP_BYTES" -v x="$b" \
        'BEGIN { if (g > 0) printf "%+.1f%%", (x-g)*100.0/g; else printf "n/a" }')"
  rt="ok"
  (( ${C_FAIL["$c"]} > 0 )) && rt="${C_FAIL["$c"]} FAILED"
  [[ "$c" == *"+age" ]] && rt="not verified"
  dm="${C_DMS["$c"]}"
  dstr="$(hms "$dm")"; (( dm == 0 )) && dstr='-'
  emit "$(printf ' %-18s %13s %7sx %11s %10s %10s  %s\n' \
    "$c" "$(hsize "$b")" "$ratio" "$(hms "${C_CMS["$c"]}")" "$dstr" "$vs" "$rt")"
done
emit "$LOG_SUB"
note "VS GZIP: negative is smaller than the .tar.gz logical.sh writes today."
note "COMPRESS is serial here. The real run does $PARALLEL_HINT at once."

# CPU is reported separately because it answers a different question from
# elapsed time: elapsed says how long the window is, CPU says how much of the
# machine MySQL loses while it happens.
if (( MEASURE_CPU == 1 )); then
  emit ""
  banner " CPU AND MEMORY   (per compressor process, GNU time rusage)"
  emit "$(printf ' %-18s %10s %10s %11s %12s %11s %10s' \
    'CASE' 'USER' 'SYSTEM' 'TOTAL CPU' 'CPU/GiB' 'PEAK RAM' 'VS GZIP')"
  sub
  GZ_CPU=$(( ${C_USER["gzip -${GZIP_LEVEL}"]:-0} + ${C_SYS["gzip -${GZIP_LEVEL}"]:-0} ))
  for c in "${CASES[@]}"; do
    (( ${C_BYTES["$c"]} > 0 )) || continue
    emit "$(awk -v c="$c" -v u="${C_USER["$c"]:-0}" -v s="${C_SYS["$c"]:-0}" \
                -v rss="${C_RSS["$c"]:-0}" -v raw="$RAW_TOTAL" -v gz="$GZ_CPU" '
      function t(ms,   x) { x=ms/1000
        if (x < 90) return sprintf("%.1fs", x)
        if (x < 5400) return sprintf("%dm%02ds", int(x/60), int(x)%60)
        return sprintf("%dh%02dm", int(x/3600), int((x%3600)/60)) }
      BEGIN { tot=u+s; gib=raw/1073741824
        printf " %-18s %10s %10s %11s %11.1fs %10.0fMiB %9s",
          c, t(u), t(s), t(tot), (gib>0 ? (tot/1000)/gib : 0), rss/1024,
          (gz>0 ? sprintf("%+.0f%%", (tot-gz)*100.0/gz) : "n/a") }')"
  done
  sub
  note "TOTAL CPU is user+system seconds actually burned, not wall clock."
  note "CPU/GiB normalises it, so servers of different sizes compare directly."
  note "PEAK RAM is one process. logical.sh runs $PARALLEL_HINT at once — multiply it."
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 12  SIZE BUCKETS
#
# Whether one database could have predicted the estate. If the small bucket is
# far worse than the large one, the headline ratio belongs to the big schemas
# only, and an estate of mostly-small databases will not see it.
# ═══════════════════════════════════════════════════════════════════════════

if [[ -n "$BUCKET_CASE" ]]; then
  emit ""
  banner " RATIO BY DATABASE SIZE   ($BUCKET_CASE)"
  emit "$(printf ' %-16s %7s %14s %14s %8s\n' 'BUCKET' 'DBS' 'RAW SQL' 'COMPRESSED' 'RATIO')"
  emit "$LOG_SUB"
  for b in small mid large; do
    n="${BUCKET_N["$b"]:-0}"
    (( n == 0 )) && continue
    case "$b" in
      small) name="< 1 MiB" ;;
      mid)   name="1 - 100 MiB" ;;
      large) name="> 100 MiB" ;;
    esac
    br="$(awk -v r="${BUCKET_RAW["$b"]}" -v c="${BUCKET_COMP["$b"]}" \
          'BEGIN { if (c > 0) printf "%.2f", r/c; else printf "0" }')"
    emit "$(printf ' %-16s %7s %14s %14s %7sx\n' \
      "$name" "$n" "$(hsize "${BUCKET_RAW["$b"]}")" "$(hsize "${BUCKET_COMP["$b"]}")" "$br")"
  done
  emit "$LOG_SUB"
  note "A large gap here is why one database cannot answer this question."
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 13  RECOMMENDATION
# ═══════════════════════════════════════════════════════════════════════════

emit ""
banner " READING THIS"

BEST_SIZE=""; BEST_SIZE_BYTES=0
BEST_KNEE=""; BEST_KNEE_SCORE=-1
for c in "${CASES[@]}"; do
  b="${C_BYTES["$c"]}"
  (( b > 0 )) || continue
  (( ${C_FAIL["$c"]} == 0 )) || continue
  [[ "$c" == gzip* || "$c" == *"+age" ]] && continue
  if (( BEST_SIZE_BYTES == 0 )) || (( b < BEST_SIZE_BYTES )); then
    BEST_SIZE_BYTES="$b"; BEST_SIZE="$c"
  fi
  score="$(awk -v g="$GZIP_BYTES" -v x="$b" -v t="${C_CMS["$c"]}" \
           'BEGIN { if (t < 1) t = 1; printf "%d", (g-x)*1000/t }')"
  if (( score > BEST_KNEE_SCORE )); then BEST_KNEE_SCORE="$score"; BEST_KNEE="$c"; fi
done

if [[ -n "$BEST_SIZE" ]]; then
  kv "smallest"   "$BEST_SIZE — $(hsize "$BEST_SIZE_BYTES")"
  kv "best value" "${BEST_KNEE:-none} — most bytes saved per second of CPU"
  if (( GZIP_BYTES > 0 )); then
    SAVED=$(( GZIP_BYTES - BEST_SIZE_BYTES ))
    kv "vs today" "$( (( SAVED > 0 )) && printf '%s smaller on this sample' "$(hsize "$SAVED")" \
                                      || printf '%s LARGER on this sample' "$(hsize $((-SAVED)))" )"
  fi
  if (( SAMPLE_DBS > 0 && ESTATE_BYTES > 0 && RAW_TOTAL > 0 )); then
    sub
    note "This was a sample. Scale the sizes by your estate, not by database"
    note "count — the CSV has every per-database row to do that properly."
  fi
  sub
  note "logical.sh runs PARALLEL=$PARALLEL_HINT dumps at once, so compression"
  note "time is shared, not free. If the window has room, take the smallest."
  note "If it does not, take the best-value level — the size difference"
  note "between them is usually under 3%."
else
  warn "no case round-tripped cleanly — do not change logical.sh on this data"
fi

sub
kv "log" "$RUN_LOG"
kv "csv" "$CSV_FILE"
note "send both — the CSV has one row per database per level"

rm -rf "$WORK_DIR" 2>/dev/null || true
WORK_DIR=""

emit ""
banner " RESULT ok server=${SERVER_NAME} run=${RUN_ID} dbs=${OK_COUNT} failed=${FAILED_COUNT} raw=${RAW_TOTAL} dur_s=$(( $(date +%s) - START_EPOCH )) warn=${WARN_COUNT}"

trap - ERR INT TERM HUP
exit 0
