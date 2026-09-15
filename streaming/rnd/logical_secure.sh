#!/usr/bin/env bash
#
# streaming/rnd/logical_secure.sh — per-database logical backup, compressed
# and encrypted (mysqldump | zstd | age)
#
# Dumps the instance restore_vm.sh just rebuilt and publishes one verified
# .sql.zst.age per database to the share. Per-database consistency only: there
# is no cross-database point in time here, and no PITR.
#
# Differs from logical.sh in three things, and nothing else:
#   compression   zstd -9 instead of gzip, and no tar wrapper around one file
#   encryption    age, to the PUBLIC keys in AGE_RECIPIENTS_FILE
#   artifact      <db>_<run>.sql.zst.age instead of <db>_<run>.tar.gz
#
# The private keys are deliberately NOT on this host, so this script can
# encrypt and can never decrypt. That is the point: whoever takes the VM, or
# either filer, gets nothing readable. It also means the verify step checks the
# published CIPHERTEXT against its checksum — proving the bytes arrived intact
# — and cannot prove decryptability. That is proven on the restore host, where
# the key legitimately lives. Docs: streaming/rnd/encrypted-logical.md
#
#   PART 1   configuration        1A set per VM / 1B tune / 1C shared
#   PART 2   log engine
#   PART 3   failure handling
#   PART 4   probes
#   PART 5   usage and arguments
#   PART 6   single-instance lock
#   PART 7   identity and paths
#   PART 8   pre-flight            13 checks
#   PART 9   database list         step 1/4
#   PART 10  dump                  step 2/4
#   PART 11  verify                step 3/4
#   PART 12  manifest              step 4/4
#   PART 13  summary
#
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# PART 1  CONFIGURATION
#
#   1A  SET PER VM    __SET_ME__ until filled in; the script refuses to start
#   1B  TUNING        working defaults
#   1C  SHARED        must match the other scripts on this host
#   1D  NOT SET HERE  detected at run time, or passed as arguments
#
# What each one means, and what breaks when it is wrong: docs/README-dr.md §11
# ═══════════════════════════════════════════════════════════════════════════

# ── 1A  SET PER VM ─────────────────────────────────────────────────────────
MYSQL_USER="Admin"                              # needs SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER
MYSQL_PASSWORD=""
MYSQL_HOST="10.10.0.4"                              # the LOCAL restored instance; "" = local socket
SMB_MOUNT_POINT="/livestorage"                         # the mount point itself, e.g. /livestorage
EXTRA_MOUNTS=""                                      # other mounts that may hold server paths, space separated
AGE_RECIPIENTS_FILE="/etc/dbvault/recipients.txt"                     # PUBLIC keys only, one per line, e.g. /etc/dbvault/recipients.txt

# ── 1B  TUNING ─────────────────────────────────────────────────────────────
KEEP_LOCAL_DAYS=14                                   # prune logs stranded here
PARALLEL=3                                           # databases dumped at once
SOURCE_CHECK=1                                       # refuse if the newest marker is another server
DUMP_ATTEMPTS=3                                      # tries per database, on a lock error only
DUMP_RETRY_WAIT=5                                    # seconds between those tries
ZSTD_LEVEL=9                                         # 1-19; 9 chosen by benchmark, see docs/compression-benchmark.md
ZSTD_THREADS=1                                       # -T per worker; PARALLEL is the concurrency knob
MIN_RECIPIENTS=2                                     # below this the run warns: one lost key loses every archive

# --hex-blob is deliberately NOT set: no binary columns in these schemas.
DUMP_OPTS="--single-transaction --quick --routines --events --triggers \
--set-gtid-purged=OFF --default-character-set=utf8mb4 \
--net-buffer-length=1M"

# ── 1C  SHARED ─────────────────────────────────────────────────────────────
LOCAL_STAGE="/Data/dbvault-stage"                    # logs and dump staging
LOCK_DIR="/var/lock/dbvault"
STATE_DIR="/var/lib/dbvault"                         # restore_vm.sh markers

# ── 1D  NOT SET HERE ───────────────────────────────────────────────────────
# Binaries resolved in PART 5, right after the guard. An env var still wins.
MYSQL_BIN="${MYSQL_BIN:-}"                           # PATH
MYSQLDUMP_BIN="${MYSQLDUMP_BIN:-}"                   # PATH
ZSTD_BIN="${ZSTD_BIN:-}"                             # PATH
AGE_BIN="${AGE_BIN:-}"                               # PATH

SERVER_NAME=""                                       # --server_name=
BASE_DIR=""                                          # --base_dir=, this server's dump root

# A servers.json entry may carry mysql_user / mysql_password for a server whose
# credentials differ from this host's. final.sh exports them for the one child
# it is running; unset, both fall through to the 1A values above. Environment
# rather than an argument, so the password never reaches anyone's ps output.
MYSQL_USER="${DBVAULT_MYSQL_USER:-$MYSQL_USER}"
MYSQL_PASSWORD="${DBVAULT_MYSQL_PASSWORD:-$MYSQL_PASSWORD}"

# ── 1E  GUARD ──────────────────────────────────────────────────────────────
# Refuses to start while any 1A value is still __SET_ME__. Called in PART 5, so
# the servers.json credential override gets its chance first.

SET_ME_VARS=(MYSQL_USER MYSQL_PASSWORD MYSQL_HOST SMB_MOUNT_POINT AGE_RECIPIENTS_FILE)

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
#
#   HH:MM:SS LEVEL [phase     nn/nn] message
# ═══════════════════════════════════════════════════════════════════════════

RUN_LOG=""
ERROR_LOG=""
PHASE="init"
STEP="-"
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
  [[ -n "$RUN_LOG"   && -d "${RUN_LOG%/*}" ]] && printf '%s\n' "$1" >> "$RUN_LOG"
  [[ -n "$ERROR_LOG" && -f "$ERROR_LOG"    ]] && printf '%s\n' "$1" >> "$ERROR_LOG"
  return 0
}

banner() { emit "$LOG_RULE"; emit "$1"; emit "$LOG_RULE"; }
sub()    { emit "$LOG_SUB"; }
kv()     { emit "$(printf ' %-16s: %s' "$1" "$2")"; }

tag()  { printf '[%s %s]' "$PHASE" "$STEP"; }
info() { emit     "$(printf '%s %-5s %-17s %s' "$(date +%T)" 'INFO'  "$(tag)" "$1")"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1))
         emit     "$(printf '%s %-5s %-17s %s' "$(date +%T)" 'WARN'  "$(tag)" "$1")"; }
erro() { emit_err "$(printf '%s %-5s %-17s %s' "$(date +%T)" 'ERROR' "$(tag)" "$1")"; }
cont() { emit     "$(printf '%-32s %s' '' "$1")"; }
cerr() { emit_err "$(printf '%-32s %s' '' "$1")"; }

# "label ............... value"
leader() {
  local pad=$(( 40 - ${#1} - ${#2} ))
  (( pad < 3 )) && pad=3
  printf '%s %s %s' "$1" "${LOG_DOTS:0:$pad}" "$2"
}
ok()  { info "$(leader "$1" 'OK')"; }
val() { info "$(leader "$1" "$2")"; }
nok() { warn "$(leader "$1" "$2")"; }
skp() { info "$(leader "$1" "$2")"; }

CHECK_N=0
CHECK_TOTAL=13
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

# ═══════════════════════════════════════════════════════════════════════════
# PART 3  FAILURE HANDLING
#
# One exit path. `exit 1` does NOT fire an ERR trap, so every failure calls
# die() explicitly rather than relying on the trap to notice.
# ═══════════════════════════════════════════════════════════════════════════

START_EPOCH="$(date +%s)"
RUN_ID=""
DB_COUNT=0
OK_COUNT=0
FAILED_COUNT=0
FAILED_LIST=""
TOTAL_BYTES=0
VERIFIED=0
PUBLISHED_LOGS=0
WORK_DIR=""

publish_logs() {
  [[ "$PUBLISHED_LOGS" == "1" ]] && return 0
  PUBLISHED_LOGS=1
  [[ -n "${SECONDARY_LOG_DIR:-}" ]] || return 0

  # Without this, an unmounted share lets `mkdir -p` succeed against a plain
  # LOCAL directory and the logs are moved onto the root filesystem, out of
  # sight, with the staging copies deleted.
  if ! mountpoint -q "$SMB_MOUNT_POINT" 2>/dev/null; then
    printf '%s\n' " [WARN] share not mounted — logs kept in $LOCAL_STAGE:" >&2
    printf '%s\n' "        $RUN_LOG" >&2
    return 0
  fi

  mkdir -p "$SECONDARY_LOG_DIR" 2>/dev/null || {
    printf '%s\n' " [WARN] cannot create $SECONDARY_LOG_DIR — logs kept in $LOCAL_STAGE" >&2
    return 0
  }

  # Copy, confirm the destination is non-empty, then drop the local file.
  local pair src dst kept=0
  for pair in "${RUN_LOG}:logical.log" \
              "${ERROR_LOG}:errors.log"; do
    src="${pair%:*}"; dst="${pair##*:}"
    [[ -n "$src" && -f "$src" ]] || continue
    if cp "$src" "${SECONDARY_LOG_DIR}/${dst}" 2>/dev/null \
       && [[ -s "${SECONDARY_LOG_DIR}/${dst}" ]]; then
      rm -f "$src" 2>/dev/null || true
    else
      kept=$((kept + 1))
    fi
  done

  if [[ $kept -gt 0 ]]; then
    printf '%s\n' " [WARN] $kept log(s) could not be published — kept in $LOCAL_STAGE" >&2
  fi
  printf '%s\n' " logs published to $SECONDARY_LOG_DIR"
}

# Safety net only. A successful run leaves nothing in LOCAL_STAGE: the log is
# published to the share and the local copy dropped. This clears only what an
# earlier run kept BECAUSE the share was unreachable.
# Never touches this run's files: -mtime is in whole days.
prune_local() {
  local f n=0
  while IFS= read -r f; do
    rm -f "$f" 2>/dev/null && n=$((n + 1))
  done < <(find "$LOCAL_STAGE" -maxdepth 1 -type f -name '*_logical_*.log' \
             -mtime "+${KEEP_LOCAL_DAYS}" 2>/dev/null || true)
  [[ $n -gt 0 ]] && info "pruned $n stranded log file(s) older than ${KEEP_LOCAL_DAYS} days"
  return 0
}

# What actually broke. A die() names its own cause; an uncaught non-zero does
# not, and used to produce a failure banner with no reason in it at all. These
# carry what bash knows about that case: the command, its line, its exit code.
DIED=0
INTERRUPTED=0
FAILED_CMD=""
FAILED_LINE=""
FAILED_RC=""

fail_run() {
  trap - ERR INT TERM                              # no re-entry
  local at="$PHASE $STEP"

  emit ""
  banner " LOGICAL BACKUP FAILED  ${SERVER_NAME:-(no server)}  ${RUN_ID:-(no run)}"
  kv "failed in" "$at"
  if [[ ${INTERRUPTED:-0} -eq 1 ]]; then
    kv "cause" "interrupted — Ctrl-C or kill"
  elif [[ ${DIED:-0} -eq 0 && -n "${FAILED_CMD:-}" ]]; then
    kv "cause"          "uncaught failure — no check reported this"
    kv "failed command" "$FAILED_CMD"
    kv "at line"        "${FAILED_LINE:-?}  (exit ${FAILED_RC:-?})"
  fi
  kv "duration"  "$(elapsed "$START_EPOCH")"
  sub

  PHASE="cleanup"; STEP="-"

  # Published archives are left alone: each one was verified and named
  # individually, so a run that failed halfway still leaves usable dumps. Only
  # this run's unfinished intermediates go.
  if [[ -n "${BACKUP_DIR:-}" && -n "$RUN_ID" ]] && mountpoint -q "$SMB_MOUNT_POINT" 2>/dev/null; then
    local f n=0
    while IFS= read -r f; do
      rm -f "$f" 2>/dev/null && n=$((n + 1))
    done < <(find "$BACKUP_DIR" -mindepth 2 -maxdepth 2 -type f \
               -name "*_${RUN_ID}.sql.zst.age.part" 2>/dev/null || true)
    [[ $n -gt 0 ]] && info "removed $n unfinished file(s) from this run"
  fi
  [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR" 2>/dev/null

  if [[ $OK_COUNT -gt 0 ]]; then
    warn "$OK_COUNT database(s) WERE published before this failure"
    cont "those archives are complete and restorable; the run is not"
  fi

  sub
  kv "error log" "${ERROR_LOG:-(none)}"
  banner " RESULT failed server=${SERVER_NAME:-none} run=${RUN_ID:-none} phase=${at% *} step=${at#* } dbs=${DB_COUNT} ok=${OK_COUNT} failed=${FAILED_COUNT} dur_s=$(( $(date +%s) - START_EPOCH )) warn=${WARN_COUNT}"

  publish_logs
  exit 1
}

# die <message> [detail...]
die() {
  DIED=1
  erro "$1"; shift
  local l; for l in "$@"; do cerr "$l"; done
  fail_run
}

# Captured inside the trap, not in fail_run: fail_run's own commands overwrite
# BASH_COMMAND, so by the time it runs the failing command is already gone.
on_err() {
  FAILED_RC=$?
  FAILED_CMD="$BASH_COMMAND"
  FAILED_LINE="${BASH_LINENO[0]}"
  fail_run
}

trap on_err ERR
trap 'INTERRUPTED=1; fail_run' INT TERM

# ═══════════════════════════════════════════════════════════════════════════
# PART 4  PROBES
# ═══════════════════════════════════════════════════════════════════════════

# The mount a configured path sits under — SMB_MOUNT_POINT, or one of
# EXTRA_MOUNTS when the backups are spread over more than one filer. Empty
# means the path is on none of them: an ordinary local directory that would
# accept writes and deletes on the root filesystem.
mount_for() {
  local p="$1" m
  for m in $SMB_MOUNT_POINT $EXTRA_MOUNTS; do
    [[ "$p" == "$m"/* ]] && { printf '%s' "$m"; return 0; }
  done
  return 1
}

# -h is omitted entirely when MYSQL_HOST is empty: that is what selects the
# local socket rather than a TCP connection to 'localhost'.
mysql_args() {
  printf '%s\n' -u"$MYSQL_USER" -p"$MYSQL_PASSWORD"
  [[ -n "$MYSQL_HOST" ]] && printf '%s\n' -h"$MYSQL_HOST"
  return 0
}

# 1213 deadlock, 1205 lock wait timeout. Both clear on their own, and both are
# worth another try; every other mysqldump error is not.
is_lock_error() {
  grep -qE '\((1213|1205)\)|Deadlock found|Lock wait timeout exceeded' "$1" 2>/dev/null
}

# stderr goes to the error log, not /dev/null: an empty result must be
# distinguishable from a failed connection.
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

# PART 1D: looked up in PATH, unless the environment named one.
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

kf() { [[ -f "$2" ]] && awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$2"; return 0; }

# ═══════════════════════════════════════════════════════════════════════════
# PART 5  USAGE AND ARGUMENTS
# ═══════════════════════════════════════════════════════════════════════════

usage() {
  cat <<EOF
Usage: $0 --server_name=NAME --base_dir=PATH [--no-source-check]

  Step 1  list      resolve the database list
  Step 2  dump      mysqldump, zstd -$ZSTD_LEVEL, age-encrypt, checksum
  Step 3  verify    re-read every published archive off the share
  Step 4  manifest  describe the run

  --server_name=NAME    the server this data came from; names the dump tree
  --base_dir=PATH       dump root on the share, e.g. /livestorage/Logical/NAME
  --no-source-check     dump whatever the instance holds, even when the newest
                        restore marker on this host is for a different server

Archives are <database>_<run id>.sql.zst.age, encrypted to the PUBLIC keys in
$AGE_RECIPIENTS_FILE. This host holds no private key and cannot decrypt them.

Every non-system schema on the instance is dumped. Credentials come from PART
1A, unless DBVAULT_MYSQL_USER / DBVAULT_MYSQL_PASSWORD are set in the
environment — which is how final.sh passes per-server credentials through.

Example:
  $0 --server_name=Cloud-Live-DB-Default --base_dir=/livestorage/Backup/Cloud-Live-DB-Default
EOF
  trap - ERR INT TERM
  exit 1
}

argfail() { echo "[ERROR] $1" >&2; trap - ERR INT TERM; exit 1; }

[[ $# -ge 1 ]] || usage

for arg in "$@"; do
  case "$arg" in
    --server_name=*)   SERVER_NAME="${arg#*=}" ;;
    --base_dir=*)      BASE_DIR="${arg#*=}" ;;
    --no-source-check) SOURCE_CHECK=0 ;;
    -h|--help)         usage ;;
    *) echo "[ERROR] Unknown argument: $arg" >&2; usage ;;
  esac
done

# PART 1E, deferred to here: the credential override above has now had its
# chance to supply the values the guard insists on.
check_set_me

resolve_bin MYSQL_BIN     mysql
resolve_bin MYSQLDUMP_BIN mysqldump
resolve_bin ZSTD_BIN      zstd
resolve_bin AGE_BIN       age

[[ -n "$SERVER_NAME" ]] || argfail "--server_name is required"
[[ -n "$BASE_DIR" ]]    || argfail "--base_dir is required"

# It becomes part of file names, so hold it to one harmless path component.
[[ "$SERVER_NAME" =~ ^[A-Za-z0-9._-]+$ ]] \
  || argfail "Invalid --server_name: $SERVER_NAME (expected [A-Za-z0-9._-]+)"
[[ "$BASE_DIR" == /* ]] \
  || argfail "--base_dir must be an absolute path: $BASE_DIR"
BASE_DIR="${BASE_DIR%/}"

[[ "$PARALLEL" =~ ^[1-9][0-9]*$ ]] \
  || argfail "PARALLEL must be a positive integer, got '$PARALLEL'"

[[ "$DUMP_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] \
  || argfail "DUMP_ATTEMPTS must be a positive integer, got '$DUMP_ATTEMPTS'"
[[ "$DUMP_RETRY_WAIT" =~ ^[0-9]+$ ]] \
  || argfail "DUMP_RETRY_WAIT must be a non-negative integer, got '$DUMP_RETRY_WAIT'"

# 20-22 are excluded deliberately: they need --ultra to compress AND a large
# memory window to DECOMPRESS, which would commit every future restore host.
[[ "$ZSTD_LEVEL" =~ ^[0-9]+$ ]] && (( ZSTD_LEVEL >= 1 && ZSTD_LEVEL <= 19 )) \
  || argfail "ZSTD_LEVEL must be 1-19, got '$ZSTD_LEVEL'"
[[ "$ZSTD_THREADS" =~ ^[0-9]+$ ]] \
  || argfail "ZSTD_THREADS must be a non-negative integer, got '$ZSTD_THREADS'"

# ═══════════════════════════════════════════════════════════════════════════
# PART 6  SINGLE-INSTANCE LOCK
#
# Per-destination, not global: two BASE_DIR targets on one host need not block
# each other, but two runs against the SAME tree would fight over one set of
# archive names.
# ═══════════════════════════════════════════════════════════════════════════

mkdir -p "$LOCK_DIR" "$LOCAL_STAGE" 2>/dev/null || true
exec 200>"${LOCK_DIR}/logical_$(basename "$BASE_DIR").lock"
if ! flock -n 200; then
  echo "[ERROR] Another logical backup is already running for $BASE_DIR." >&2
  trap - ERR INT TERM
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 7  IDENTITY AND PATHS
#
# Full date and time, always: <database>_YYYY-MM-DD_HH-MM-SS.sql.zst.age. Every run
# is therefore distinct, so a second run on the same day cannot collide with
# the first and no rerun suffix is needed.
# ═══════════════════════════════════════════════════════════════════════════

BACKUP_DIR="$BASE_DIR"
MANIFEST_DIR="${BASE_DIR}/manifests"

RUN_ID="$(date +%Y-%m-%d_%H-%M-%S)"

RUN_STAMP="$(date +%Y%m%d_%H%M%S)"
RUN_LOG="${LOCAL_STAGE}/${SERVER_NAME}_logical_${RUN_STAMP}.log"
ERROR_LOG="${LOCAL_STAGE}/${SERVER_NAME}_logical_${RUN_STAMP}_errors.log"
SECONDARY_LOG_DIR="${BASE_DIR}/logs/${RUN_ID}"
MANIFEST_FILE="${MANIFEST_DIR}/${RUN_ID}.manifest"

# Per-database status files. A worker runs under xargs in its own subshell, so
# any variable it sets dies with it — the parent tallies these files instead.
WORK_DIR="${LOCAL_STAGE}/.logical_${SERVER_NAME}_${RUN_STAMP}"

# Where each database is dumped, archived and checksummed before it is moved to
# the share. Local disk, deliberately: dumping straight to CIFS means zstd reads
# the .sql back over the network, age reads the .zst back to encrypt it, and
# sha256sum reads the result again — four network passes over the data to
# publish one archive. Built here, it is one pass.
BUILD_DIR="${WORK_DIR}/build"

RESTORE_MARKER=""
SOURCE_BACKUP_ID=""
SOURCE_DATA_OPT=""

mkdir -p "$LOCAL_STAGE" "$WORK_DIR" "$BUILD_DIR" 2>/dev/null || {
  echo "[ERROR] Failed to create $WORK_DIR" >&2
  trap - ERR INT TERM; exit 1; }

printf 'errors for logical backup of %s run %s\n\n' "$SERVER_NAME" "$RUN_ID" > "$ERROR_LOG"

banner " LOGICAL BACKUP RUN  $SERVER_NAME  $RUN_ID"
kv "started"     "$(date '+%F %T %Z')"
kv "host"        "$(hostname -s 2>/dev/null || echo unknown)"
kv "server"      "$SERVER_NAME"
kv "run id"      "$RUN_ID"
kv "source"      "${MYSQL_HOST:-local socket}"
kv "destination" "$BACKUP_DIR"
kv "staging"     "$BUILD_DIR (dump, compress, encrypt, checksum — then moved)"
kv "compression" "zstd -$ZSTD_LEVEL"
kv "encryption"  "age -R $AGE_RECIPIENTS_FILE (recipients counted in pre-flight)"
kv "parallel"    "$PARALLEL"
kv "logs"        "$LOCAL_STAGE during the run, moved to the share at the end"
sub
prune_local

# ═══════════════════════════════════════════════════════════════════════════
# PART 8  PRE-FLIGHT
# ═══════════════════════════════════════════════════════════════════════════

phase preflight
PREFLIGHT_EPOCH="$PHASE_EPOCH"

check
if [[ $EUID -ne 0 ]]; then
  nok "user privileges" "NOT ROOT"
  cont "the share is usually mounted for root only — writes may fail"
else
  ok "user privileges"
fi

check
for cmd in mysql mysqldump zstd age sha256sum awk find sort df du stat mountpoint flock xargs nice ionice; do
  command -v "$cmd" >/dev/null 2>&1 \
    || die "$(leader 'required binaries' 'MISSING')" "not found in PATH: $cmd"
done
for bin in "$MYSQL_BIN" "$MYSQLDUMP_BIN" "$ZSTD_BIN" "$AGE_BIN"; do
  [[ -x "$bin" ]] || die "$(leader 'required binaries' 'MISSING')" "not executable: $bin"
done
ok "required binaries"

# --base_dir is an argument, so a typo is a plausible daily event — and a path
# OUTSIDE the mount is a perfectly writable local directory: the dumps land on
# the root filesystem and fill it, reporting success the whole way.
check
BASE_MOUNT="$(mount_for "$BASE_DIR")" \
  || die "$(leader 'base dir' 'OFF THE SHARE')" \
         "--base_dir is $BASE_DIR" \
         "which is under neither $SMB_MOUNT_POINT nor EXTRA_MOUNTS (${EXTRA_MOUNTS:-none})" \
         "dumps written there would fill the root filesystem instead of the NAS"
mountpoint -q "$BASE_MOUNT" \
  || die "$(leader 'base dir' 'NOT MOUNTED')" \
         "$BASE_MOUNT holds --base_dir but is not a mount point"
val "base dir" "under $BASE_MOUNT"

check
mountpoint -q "$SMB_MOUNT_POINT" \
  || die "$(leader 'smb share' 'NOT MOUNTED')" \
         "expected a mount at $SMB_MOUNT_POINT" \
         "the path may exist as an empty local directory — writing there" \
         "would fill the root filesystem instead of the NAS"
mkdir -p "$BACKUP_DIR" "$MANIFEST_DIR" 2>/dev/null \
  || die "$(leader 'smb share' 'MKDIR FAILED')" "cannot create $BACKUP_DIR"
writable "$BACKUP_DIR" \
  || die "$(leader 'smb share' 'NOT WRITABLE')" \
         "mounted but not writable: $BACKUP_DIR" \
         "stale handle, auth failure, or uid=/gid=/file_mode= mount options"
ok "smb share"

check
writable "$LOCAL_STAGE" \
  || die "$(leader 'local stage writable' 'NO')" "not writable: $LOCAL_STAGE"
ok "local stage writable"

check
mysql_q "SELECT 1" >/dev/null \
  || die "$(leader 'mysql connection' 'FAILED')" \
         "user $MYSQL_USER at ${MYSQL_HOST:-local socket}" \
         "in the pipeline this runs after restore_vm.sh has started MySQL"
ok "mysql connection"

# The check that catches the multi-server accident. Every server's daily
# archive is named for the date, the datadir is wiped and rebuilt per server,
# and this script is only TOLD which server it is dumping. So if the restore of
# THIS server failed and the previous server's data is still in place, the dumps
# would be published, checksummed and verified — and completely wrong. Nothing
# downstream could tell.
check
if [[ "$SOURCE_CHECK" != "1" ]]; then
  skp "restored source" "not checked (--no-source-check)"
elif [[ ! -d "$STATE_DIR" ]]; then
  nok "restored source" "NO MARKERS"
  cont "$STATE_DIR does not exist — no restore has been recorded on this host"
  cont "if this instance is not a restore of $SERVER_NAME, the dumps are wrong"
else
  NEWEST_MARKER="$(find "$STATE_DIR" -maxdepth 1 -type f -name '*_restore_state' \
                     -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)"
  if [[ -z "$NEWEST_MARKER" ]]; then
    nok "restored source" "NO MARKERS"
    cont "no *_restore_state in $STATE_DIR"
    cont "if this instance is not a restore of $SERVER_NAME, the dumps are wrong"
  else
    MARKER_SERVER="$(basename "$NEWEST_MARKER" _restore_state)"
    MARKER_SERVER="${MARKER_SERVER%_[0-9]*}"
    if [[ "$MARKER_SERVER" != "$SERVER_NAME" ]]; then
      die "$(leader 'restored source' 'WRONG SERVER')" \
          "the newest restore on this host is $MARKER_SERVER, not $SERVER_NAME" \
          "marker: $NEWEST_MARKER" \
          "" \
          "this instance therefore holds ${MARKER_SERVER}'s data. Dumping it as" \
          "$SERVER_NAME would publish verified, checksummed, WRONG archives that" \
          "nothing downstream can distinguish from real ones." \
          "" \
          "restore $SERVER_NAME first, or pass --no-source-check if this instance" \
          "genuinely holds $SERVER_NAME by some other route."
    fi
    RESTORE_MARKER="$NEWEST_MARKER"
    SOURCE_BACKUP_ID="$(kf backup_id "$RESTORE_MARKER")"
    val "restored source" "$MARKER_SERVER ${SOURCE_BACKUP_ID:-(no id)}"
    cont "restored_at $(kf restored_at "$RESTORE_MARKER"), binlogs_applied=$(kf binlogs_applied "$RESTORE_MARKER")"
  fi
fi

# MySQL renamed --master-data to --source-data in 8.0.26.
check
if "$MYSQLDUMP_BIN" --help 2>/dev/null | grep -q -- '--source-data'; then
  SOURCE_DATA_OPT="--source-data=2"
elif "$MYSQLDUMP_BIN" --help 2>/dev/null | grep -q -- '--master-data'; then
  SOURCE_DATA_OPT="--master-data=2"
else
  SOURCE_DATA_OPT=""
fi

# The option needs REPLICATION CLIENT (or BINLOG MONITOR). Tested once here
# rather than discovered as a per-database failure deep into the run.
if [[ -z "$SOURCE_DATA_OPT" ]]; then
  nok "binlog coordinate" "UNSUPPORTED"
  cont "mysqldump supports neither --source-data nor --master-data"
  cont "the dumps carry NO binlog coordinate and cannot anchor a PITR"
elif mysql_q "SHOW BINARY LOG STATUS" >/dev/null 2>/dev/null \
     || mysql_q "SHOW MASTER STATUS" >/dev/null 2>/dev/null; then
  val "binlog coordinate" "$SOURCE_DATA_OPT"
else
  SOURCE_DATA_OPT=""
  nok "binlog coordinate" "NO PRIVILEGE"
  cont "$MYSQL_USER lacks REPLICATION CLIENT (or BINLOG MONITOR)"
  cont "dropped rather than failing every database; dumps carry no coordinate"
fi

# Proven here, once, against the real recipients file — not discovered as a
# per-database failure after 40 GB has already been dumped. A typo'd or empty
# recipients file would otherwise produce a full set of archives that NOBODY,
# including the key holders, can ever open.
check
[[ -f "$AGE_RECIPIENTS_FILE" ]] \
  || die "$(leader 'age recipients' 'MISSING')" \
         "$AGE_RECIPIENTS_FILE does not exist" \
         "it holds the PUBLIC keys, one per line — see streaming/rnd/encrypted-logical.md"
[[ -r "$AGE_RECIPIENTS_FILE" ]] \
  || die "$(leader 'age recipients' 'UNREADABLE')" "$AGE_RECIPIENTS_FILE"

RECIPIENT_COUNT="$(grep -c '^[[:space:]]*age1' "$AGE_RECIPIENTS_FILE" 2>/dev/null || true)"
RECIPIENT_COUNT="${RECIPIENT_COUNT:-0}"
(( RECIPIENT_COUNT > 0 )) \
  || die "$(leader 'age recipients' 'NO KEYS')" \
         "no age1... public key found in $AGE_RECIPIENTS_FILE"

# A private key must never reach this host: it would let anyone who takes the
# VM read every archive it has ever written, which is the whole threat this
# design exists to close.
if grep -q 'AGE-SECRET-KEY-' "$AGE_RECIPIENTS_FILE" 2>/dev/null; then
  die "$(leader 'age recipients' 'PRIVATE KEY PRESENT')" \
      "$AGE_RECIPIENTS_FILE contains an AGE-SECRET-KEY- line" \
      "" \
      "that is a PRIVATE key and it must not be on the backup host. Anyone who" \
      "reaches this VM could decrypt every archive it has written." \
      "" \
      "put only the age1... public keys in this file, and keep the private keys" \
      "on the restore host and offline."
fi

# The real test: encrypt an empty input to these recipients.
: | "$AGE_BIN" -R "$AGE_RECIPIENTS_FILE" >/dev/null 2>>"$ERROR_LOG" \
  || die "$(leader 'age recipients' 'REJECTED')" \
         "age will not encrypt to $AGE_RECIPIENTS_FILE" \
         "every line must be a valid age1... public key"

# Recorded in the manifest so an archive found years later says which key opens
# it. Public keys, so there is nothing secret to leak here.
AGE_RECIPIENTS="$(grep -o 'age1[0-9a-z]*' "$AGE_RECIPIENTS_FILE" | paste -sd';' - || true)"

if (( RECIPIENT_COUNT < MIN_RECIPIENTS )); then
  nok "age recipients" "$RECIPIENT_COUNT (want $MIN_RECIPIENTS)"
  cont "only one key can open these archives. If it is lost, every backup"
  cont "ever written with it is unreadable — add a break-glass recipient"
else
  val "age recipients" "$RECIPIENT_COUNT keys, any one can decrypt"
fi

check
CORES="$(nproc 2>/dev/null || echo 0)"
if [[ "$CORES" -gt 0 && "$PARALLEL" -gt "$CORES" ]]; then
  nok "parallel setting" "OVERSUBSCRIBED"
  cont "$PARALLEL concurrent dumps on ${CORES} core(s)"
else
  val "parallel setting" "$PARALLEL on ${CORES:-?} core(s)"
fi

check
PROBE_FILE="${BACKUP_DIR}/.sha256_probe_$$"
echo probe > "$PROBE_FILE" 2>/dev/null \
  || die "$(leader 'sha256 utility' 'WRITE FAILED')" "cannot write to $BACKUP_DIR"
sha256sum "$PROBE_FILE" >/dev/null 2>&1 \
  || { rm -f "$PROBE_FILE"; die "$(leader 'sha256 utility' 'FAILED')" \
         "sha256sum cannot hash a file on $BACKUP_DIR"; }
rm -f "$PROBE_FILE"
ok "sha256 utility"

# Second-level guard. PART 7 already appends a time when the day is taken, so a
# collision here means a rerun inside the same second.
check
if find "$BACKUP_DIR" -mindepth 2 -maxdepth 2 -type f -name "*_${RUN_ID}.sql.zst.age" \
        -print -quit 2>/dev/null | grep -q .; then
  die "$(leader 'run id free' 'NO')" \
      "archives named *_${RUN_ID}.sql.zst.age already exist under $BACKUP_DIR" \
      "a run started in this same second — try again in a moment"
fi
ok "run id free"

check
{ [[ -d "$WORK_DIR" ]] && writable "$WORK_DIR"; } \
  || die "$(leader 'work dir' 'UNUSABLE')" "$WORK_DIR"
{ [[ -d "$BUILD_DIR" ]] && writable "$BUILD_DIR"; } \
  || die "$(leader 'work dir' 'STAGING UNUSABLE')" "$BUILD_DIR"
ok "work dir"

STEP="-"
info "$CHECK_N checks passed, ${WARN_COUNT} warning(s)   ($(elapsed "$PREFLIGHT_EPOCH"))"
sub

# ═══════════════════════════════════════════════════════════════════════════
# PART 9  DATABASE LIST  1/4
# ═══════════════════════════════════════════════════════════════════════════

phase list 1/4

# A grep that matches nothing exits 1, which pipefail turns into a failed
# assignment — hence `|| true` on every list-building substitution here.
DATABASES="$(mysql_q "SHOW DATABASES" \
              | grep -Ev '^(information_schema|performance_schema|mysql|sys)$' || true)"

# Count non-blank lines: `wc -l` on an empty string returns 1, not 0.
DB_COUNT="$(printf '%s\n' "$DATABASES" | grep -c '[^[:space:]]' || true)"
DB_COUNT="${DB_COUNT:-0}"

[[ "$DB_COUNT" -gt 0 ]] \
  || die "$(leader 'database list' 'EMPTY')" \
         "nothing would be dumped, and a run that dumps nothing must not be" \
         "allowed to report success" \
         "source=${MYSQL_HOST:-local socket}"

val "database list" "$DB_COUNT database(s)"

while IFS= read -r db; do
  [[ -n "$db" ]] && cont "$db"
done <<< "$DATABASES"

# ═══════════════════════════════════════════════════════════════════════════
# PART 10  DUMP  2/4
#
# PARALLEL databases at a time. Each one is dumped, compressed, integrity
# tested and checksummed on LOCAL disk, and only the finished archive crosses
# the network — one pass over the data instead of three. The local copies are
# deleted as soon as the archive is on the share, so the staging area only ever
# holds PARALLEL databases at once.
#
# A failure is recorded and the run continues: one unreadable schema must not
# cost the other sixteen.
# ═══════════════════════════════════════════════════════════════════════════

phase dump 2/4

dump_one() {
  local DB="$1"
  local SQL="${BUILD_DIR}/${DB}_${RUN_ID}.sql"
  local ZST="${BUILD_DIR}/${DB}_${RUN_ID}.sql.zst"
  local ARC="${BUILD_DIR}/${DB}_${RUN_ID}.sql.zst.age"
  local ERR="${BUILD_DIR}/.dump_err_${DB}_$$"
  local STATUS="${WORK_DIR}/${DB}.status"
  local DB_DIR="${BACKUP_DIR}/${DB}"
  local DEST="${DB_DIR}/${DB}_${RUN_ID}.sql.zst.age"
  local a; mapfile -t a < <(mysql_args)

  # Written first, so a worker killed outright still reads as a failure rather
  # than as a database nobody looked at.
  printf 'fail killed\n' > "$STATUS"

  # Steps 1-6 are entirely local. Only step 7 touches the network.
  # 1. dump. A lock error is retried; every other error fails on the first try.
  local attempt=1
  local reason=""
  while :; do
    # shellcheck disable=SC2086  # DUMP_OPTS is a deliberate word-split option list
    if nice -n 19 ionice -c2 -n7 \
         "$MYSQLDUMP_BIN" "${a[@]}" $DUMP_OPTS $SOURCE_DATA_OPT \
         --databases "$DB" > "$SQL" 2>"$ERR"; then
      break
    fi

    reason="$(grep -v '\[Warning\].*password' "$ERR" 2>/dev/null | head -1 || true)"
    rm -f "$SQL" 2>/dev/null || true          # a partial dump is never retried into

    if ! is_lock_error "$ERR" || (( attempt >= DUMP_ATTEMPTS )); then
      erro "$(leader "$DB" 'DUMP FAILED')"
      cerr "${reason:-unknown error}"
      (( attempt > 1 )) && cerr "gave up after ${attempt} lock retries"
      rm -f "$ERR" 2>/dev/null || true
      printf 'fail mysqldump\n' > "$STATUS"
      return 0
    fi

    warn "$(leader "$DB" "LOCK RETRY ${attempt}/${DUMP_ATTEMPTS}")"
    cont "${reason:-lock error}"
    : > "${WORK_DIR}/${DB}.retried"           # the parent counts these
    sleep "$DUMP_RETRY_WAIT"
    attempt=$((attempt + 1))
  done
  rm -f "$ERR" 2>/dev/null || true

  if [[ ! -s "$SQL" ]]; then
    erro "$(leader "$DB" 'EMPTY DUMP')"
    cerr "mysqldump reported success but wrote nothing — refusing to archive it"
    rm -f "$SQL" 2>/dev/null || true
    printf 'fail empty\n' > "$STATUS"
    return 0
  fi

  # 2. compress. --rm drops the .sql as the .zst is written, so the slot holds
  # both copies for the shortest time it can. No tar: it is one file, and a tar
  # header around it would only add a layer to every restore.
  if ! nice -n 19 ionice -c2 -n7 \
       "$ZSTD_BIN" -"$ZSTD_LEVEL" -T"$ZSTD_THREADS" -q --rm "$SQL" -o "$ZST" 2>>"$ERROR_LOG"; then
    erro "$(leader "$DB" 'COMPRESS FAILED')"
    rm -f "$ZST" "$SQL" 2>/dev/null || true
    printf 'fail zstd\n' > "$STATUS"
    return 0
  fi

  # 3. read it back. This is the LAST point at which the content can be checked
  # on this host: once encrypted there is no key here to open it again.
  # -t writes its success line to stderr, so it is held and logged only on failure.
  local ZTEST
  if ! ZTEST="$("$ZSTD_BIN" -t "$ZST" 2>&1)"; then
    printf '%s\n' "$ZTEST" >> "$ERROR_LOG"
    erro "$(leader "$DB" 'COMPRESSED STREAM UNREADABLE')"
    rm -f "$ZST" 2>/dev/null || true
    printf 'fail zstd_test\n' > "$STATUS"
    return 0
  fi

  # 4. encrypt to every recipient. age wraps one random file key per recipient,
  # so any single private key opens the archive and the others are unaffected.
  if ! "$AGE_BIN" -R "$AGE_RECIPIENTS_FILE" -o "$ARC" "$ZST" 2>>"$ERROR_LOG"; then
    erro "$(leader "$DB" 'ENCRYPT FAILED')"
    rm -f "$ARC" "$ZST" 2>/dev/null || true
    printf 'fail age\n' > "$STATUS"
    return 0
  fi
  rm -f "$ZST" 2>/dev/null || true

  # The archive must actually BE encrypted. Without this, an age that somehow
  # passed its input through would publish readable dumps to the NAS and every
  # later step — checksum, transfer, verify — would report success.
  if [[ "$(head -c 21 "$ARC" 2>/dev/null)" != "age-encryption.org/v1" ]]; then
    erro "$(leader "$DB" 'NOT ENCRYPTED')"
    cerr "the output carries no age header — refusing to publish it"
    rm -f "$ARC" 2>/dev/null || true
    printf 'fail not_encrypted\n' > "$STATUS"
    return 0
  fi

  # 6. checksum the local archive. This is the reference the copy on the share
  # is verified against in PART 11 — hashing after the transfer instead would
  # only prove the share agrees with itself.
  # Bare filename rather than sha256sum's default path, so `sha256sum -c` works
  # from inside the directory wherever the tree is later mounted.
  if ! sha256sum "$ARC" 2>>"$ERROR_LOG" \
       | awk -v f="${DB}_${RUN_ID}.sql.zst.age" '{print $1"  "f}' > "${ARC}.sha256"; then
    erro "$(leader "$DB" 'CHECKSUM FAILED')"
    rm -f "$ARC" "${ARC}.sha256" 2>/dev/null || true
    printf 'fail sha256\n' > "$STATUS"
    return 0
  fi
  if [[ ! -s "${ARC}.sha256" ]]; then
    erro "$(leader "$DB" 'CHECKSUM EMPTY')"
    rm -f "$ARC" "${ARC}.sha256" 2>/dev/null || true
    printf 'fail sha256\n' > "$STATUS"
    return 0
  fi

  local bytes
  bytes="$(stat -c%s "$ARC" 2>/dev/null || echo 0)"

  # 7. publish: the archive crosses the network exactly once. .part until the
  # rename, so no glob and no sync job can see a half-written archive.
  if ! mkdir -p "$DB_DIR" 2>/dev/null; then
    erro "$(leader "$DB" 'MKDIR FAILED')"
    cerr "$DB_DIR"
    rm -f "$ARC" "${ARC}.sha256" 2>/dev/null || true
    printf 'fail mkdir\n' > "$STATUS"
    return 0
  fi

  rm -f "${DEST}.part" 2>/dev/null || true
  if ! cp "$ARC" "${DEST}.part" 2>>"$ERROR_LOG"; then
    erro "$(leader "$DB" 'COPY TO SHARE FAILED')"
    cerr "$ARC -> ${DEST}.part"
    rm -f "${DEST}.part" "$ARC" "${ARC}.sha256" 2>/dev/null || true
    printf 'fail publish\n' > "$STATUS"
    return 0
  fi
  sync "${DEST}.part" 2>/dev/null || true

  if ! mv "${DEST}.part" "$DEST" 2>>"$ERROR_LOG"; then
    erro "$(leader "$DB" 'RENAME FAILED')"
    rm -f "${DEST}.part" "$ARC" "${ARC}.sha256" 2>/dev/null || true
    printf 'fail rename\n' > "$STATUS"
    return 0
  fi

  if ! cp "${ARC}.sha256" "${DEST}.sha256" 2>>"$ERROR_LOG"; then
    erro "$(leader "$DB" 'SIDECAR COPY FAILED')"
    cerr "the archive is published but has no checksum beside it — removing it"
    rm -f "$DEST" "${DEST}.sha256" "$ARC" "${ARC}.sha256" 2>/dev/null || true
    printf 'fail sidecar\n' > "$STATUS"
    return 0
  fi

  # The local copies have served their purpose; the slot is freed for the next
  # database before this worker returns.
  rm -f "$ARC" "${ARC}.sha256" 2>/dev/null || true

  printf 'ok %s\n' "$bytes" > "$STATUS"
  if (( attempt > 1 )); then
    info "$(leader "$DB" "$(hsize "$bytes")  (attempt ${attempt})")"
  else
    info "$(leader "$DB" "$(hsize "$bytes")")"
  fi
  return 0
}

export -f dump_one emit emit_err info warn erro cont cerr leader tag hsize mysql_args
export -f is_lock_error
export BACKUP_DIR BUILD_DIR RUN_ID WORK_DIR RUN_LOG ERROR_LOG PHASE STEP LOG_DOTS
export DUMP_OPTS SOURCE_DATA_OPT MYSQL_USER MYSQL_PASSWORD MYSQL_HOST MYSQLDUMP_BIN
export ZSTD_BIN AGE_BIN ZSTD_LEVEL ZSTD_THREADS AGE_RECIPIENTS_FILE
export DUMP_ATTEMPTS DUMP_RETRY_WAIT

# -d '\n' so a database name is never split on whitespace. `|| true` because a
# worker's exit status must not abort the run — each one records its own
# outcome in WORK_DIR, and the tally below is what decides.
printf '%s\n' "$DATABASES" | grep '[^[:space:]]' \
  | xargs -r -d '\n' -n1 -P "$PARALLEL" bash -c 'dump_one "$@"' _ || true

DUMP_ELAPSED="$(elapsed "$PHASE_EPOCH")"

# Workers cannot reach WARN_COUNT — they run in their own shells — so a retry
# leaves a marker behind and is counted here instead.
RETRIED_COUNT=$(find "$WORK_DIR" -maxdepth 1 -type f -name '*.retried' 2>/dev/null | wc -l)
RETRIED_COUNT=${RETRIED_COUNT// /}

while IFS= read -r db; do
  [[ -n "$db" ]] || continue
  STATUS_FILE="${WORK_DIR}/${db}.status"
  if [[ ! -f "$STATUS_FILE" ]]; then
    FAILED_COUNT=$((FAILED_COUNT + 1))
    FAILED_LIST="${FAILED_LIST}${db}(no status) "
    continue
  fi
  RESULT=""; DETAIL=""
  read -r RESULT DETAIL < "$STATUS_FILE" || true
  if [[ "$RESULT" == "ok" ]]; then
    OK_COUNT=$((OK_COUNT + 1))
    TOTAL_BYTES=$(( TOTAL_BYTES + ${DETAIL:-0} ))
  else
    FAILED_COUNT=$((FAILED_COUNT + 1))
    FAILED_LIST="${FAILED_LIST}${db}(${DETAIL:-unknown}) "
  fi
done <<< "$DATABASES"

sub
if [[ "$FAILED_COUNT" -gt 0 ]]; then
  nok "dumped" "$OK_COUNT/$DB_COUNT  ($FAILED_COUNT failed)"
  cont "failed: $FAILED_LIST"
else
  val "dumped" "$OK_COUNT/$DB_COUNT  $(hsize "$TOTAL_BYTES")  ($DUMP_ELAPSED)"
fi
[[ "$RETRIED_COUNT" -gt 0 ]] \
  && cont "$RETRIED_COUNT database(s) hit a lock and were retried"

[[ "$OK_COUNT" -gt 0 ]] \
  || die "$(leader 'dump' 'NOTHING PUBLISHED')" \
         "every database failed — there is no dump of $SERVER_NAME for $RUN_ID" \
         "failed: $FAILED_LIST"

# ═══════════════════════════════════════════════════════════════════════════
# PART 11  VERIFY  3/4
#
# Re-reads every archive off the share. The dump-time test could be served from
# the page cache; this is the only thing that catches an archive which reached
# CIFS wrong.
# ═══════════════════════════════════════════════════════════════════════════

phase verify 3/4

CORRUPT_LIST=""
while IFS= read -r db; do
  [[ -n "$db" ]] || continue
  RESULT=""
  read -r RESULT _ < "${WORK_DIR}/${db}.status" || true
  [[ "$RESULT" == "ok" ]] || continue

  DB_DIR="${BACKUP_DIR}/${db}"
  if ( cd "$DB_DIR" && sha256sum -c --quiet "${db}_${RUN_ID}.sql.zst.age.sha256" ) 2>>"$ERROR_LOG"; then
    VERIFIED=$((VERIFIED + 1))
  else
    CORRUPT_LIST="${CORRUPT_LIST}${db} "
    erro "$(leader "$db" 'CHECKSUM MISMATCH ON SHARE')"
    cerr "the archive no longer matches the checksum written moments ago"
    cerr "it reached the share corrupt: ${DB_DIR}/${db}_${RUN_ID}.sql.zst.age"
  fi
done <<< "$DATABASES"

if [[ -n "$CORRUPT_LIST" ]]; then
  # Left in place deliberately: the .sha256 beside each one already fails, so
  # nothing downstream will trust them, and the files are evidence.
  die "$(leader 'archives verified' "$VERIFIED/$OK_COUNT")" \
      "corrupt on the share: $CORRUPT_LIST" \
      "they are NOT deleted — their checksum sidecars already mark them bad," \
      "and a corrupt archive is evidence of how the share is failing"
fi
val "archives verified" "$VERIFIED/$OK_COUNT re-read off the share"

# ═══════════════════════════════════════════════════════════════════════════
# PART 12  MANIFEST  4/4
# ═══════════════════════════════════════════════════════════════════════════

phase manifest 4/4

mkdir -p "$MANIFEST_DIR" 2>/dev/null \
  || die "cannot create the manifest directory: $MANIFEST_DIR"

cat > "${MANIFEST_FILE}.part" <<EOF || die "failed to write the manifest"
run_id=${RUN_ID}
server_name=${SERVER_NAME}
started_at=$(date -d "@$START_EPOCH" '+%F %T' 2>/dev/null || echo unknown)
finished_at=$(date '+%F %T')
dumped_from=${MYSQL_HOST:-local socket}
restored_from_backup_id=${SOURCE_BACKUP_ID:-unknown}
restore_marker=${RESTORE_MARKER:-none}
db_count=${DB_COUNT}
ok_count=${OK_COUNT}
failed_count=${FAILED_COUNT}
failed_list=${FAILED_LIST}
archive_bytes=${TOTAL_BYTES}
mysql_version=$(mysql_q "SELECT VERSION()" 2>/dev/null || echo unknown)
character_set=$(mysql_q "SELECT @@character_set_server" 2>/dev/null || echo unknown)
dump_opts=${DUMP_OPTS} ${SOURCE_DATA_OPT}
archive_format=sql.zst.age
compression=zstd
compression_level=${ZSTD_LEVEL}
encryption=age
age_recipients=${AGE_RECIPIENTS}
age_recipient_count=${RECIPIENT_COUNT}
restore_requires=an age private key matching one of the recipients above
recovery_method=logical_per_database
consistency=per_database_only
EOF
mv "${MANIFEST_FILE}.part" "$MANIFEST_FILE" 2>>"$ERROR_LOG" \
  || die "failed to finalize the manifest"
ok "manifest published"

rm -rf "$WORK_DIR" 2>/dev/null || true
WORK_DIR=""

# ═══════════════════════════════════════════════════════════════════════════
# PART 13  SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

PHASE="done"; STEP="-"

emit ""
if [[ "$FAILED_COUNT" -gt 0 ]]; then
  banner " LOGICAL BACKUP INCOMPLETE  $SERVER_NAME  $RUN_ID"
else
  banner " LOGICAL BACKUP OK  $SERVER_NAME  $RUN_ID"
fi
kv "duration"    "$(elapsed "$START_EPOCH")"
kv "server"      "$SERVER_NAME"
kv "run id"      "$RUN_ID"
kv "source"      "${MYSQL_HOST:-local socket}"
kv "from backup" "${SOURCE_BACKUP_ID:-unknown}"
kv "databases"   "$DB_COUNT listed / $OK_COUNT published / $FAILED_COUNT failed"
kv "verified"    "$VERIFIED archive(s) re-read off the share"
kv "total size"  "$(hsize "$TOTAL_BYTES")"
kv "archives"    "$BACKUP_DIR/<database>/<database>_${RUN_ID}.sql.zst.age"
kv "manifest"    "$MANIFEST_FILE"
kv "warnings"    "$WARN_COUNT"
if [[ "$FAILED_COUNT" -gt 0 ]]; then
  sub
  emit " failed databases:"
  emit "   $FAILED_LIST"
  emit " each of those has NO archive for this run. The published archives are"
  emit " complete and verified; the run still reports failure, because a partial"
  emit " dump set must not read as a success."
fi
sub
kv "logs" "$SECONDARY_LOG_DIR/"

if [[ "$FAILED_COUNT" -gt 0 ]]; then
  banner " RESULT failed server=${SERVER_NAME} run=${RUN_ID} dbs=${DB_COUNT} ok=${OK_COUNT} failed=${FAILED_COUNT} bytes=${TOTAL_BYTES} dur_s=$(( $(date +%s) - START_EPOCH )) warn=${WARN_COUNT}"
  publish_logs
  trap - ERR INT TERM
  exit 1
fi

banner " RESULT ok server=${SERVER_NAME} run=${RUN_ID} dbs=${DB_COUNT} ok=${OK_COUNT} failed=0 bytes=${TOTAL_BYTES} dur_s=$(( $(date +%s) - START_EPOCH )) warn=${WARN_COUNT}"

publish_logs

trap - ERR INT TERM
exit 0
