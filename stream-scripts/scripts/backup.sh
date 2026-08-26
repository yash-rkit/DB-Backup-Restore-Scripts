#!/usr/bin/env bash
#
# stream-scripts/physical/backup.sh — streaming XtraBackup full backup, SMB/CIFS
#
# Publishes an UNPREPARED .xbstream; restore.sh runs --prepare.
# Docs: stream-scripts/physical/README.md
#
#   PART 1   configuration
#   PART 2   log engine
#   PART 3   failure handling
#   PART 4   probes
#   PART 5   identity and paths
#   PART 6   bootstrap
#   PART 7   pre-flight            15 checks
#   PART 8   stream                step 1/5
#   PART 9   verify                step 2/5
#   PART 10  binlog position       step 3/5
#   PART 11  checksum              step 4/5
#   PART 12  publish               step 5/5
#   PART 13  summary
#   PART 14  inline binlog collection
#
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# PART 1  CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

MYSQL_USER="Admin"
MYSQL_PASSWORD=""

BACKUP_BASE="/Data/dbvault-stage"                    # LOCAL staging, never CIFS
XB_TMPDIR="/Data/xb-tmp"                             # --tmpdir, --extra-lsndir
STREAM_SPACE_PCT=40                                  # staging need, % of datadir
KEEP_LOCAL_DAYS=14                                   # prune logs stranded by a dead share

XTRABACKUP_BIN="/usr/bin/xtrabackup"
MYSQL_BIN="/usr/bin/mysql"
MYSQL_DATADIR="/Data/mysql"

PARALLEL_THREADS=8
COMPRESS_THREADS=8
ZSTD_LEVEL=1

SECONDARY_STORAGE_DIR="/livestorage/YK/Restore-VM"   # permanent home
SMB_MOUNT_POINT="/livestorage"                       # the CIFS mount point

LOCK_DIR="/var/lock/dbvault"                         # LOCAL; binlog_collect polls
BINLOG_SCRIPT=""

# ═══════════════════════════════════════════════════════════════════════════
# PART 2  LOG ENGINE
#
#   HH:MM:SS LEVEL [phase     nn/nn] message
# ═══════════════════════════════════════════════════════════════════════════

RUN_LOG=""
ERROR_LOG=""
XTRABACKUP_LOG=""
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

CHECK_N=0
CHECK_TOTAL=15
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

TRANSFER_OK="no"
PUBLISHED_LOGS=0

publish_logs() {
  [[ "$PUBLISHED_LOGS" == "1" ]] && return 0
  PUBLISHED_LOGS=1
  [[ -n "${SECONDARY_LOG_DIR:-}" ]] || return 0

  # Without this, an unmounted share lets `mkdir -p` succeed against a plain
  # LOCAL directory and the logs are moved onto the root filesystem, out of
  # sight, with the staging copies deleted.
  if ! mountpoint -q "$SMB_MOUNT_POINT" 2>/dev/null; then
    printf '%s\n' " [WARN] share not mounted — logs kept in $BACKUP_BASE:" >&2
    printf '%s\n' "        $RUN_LOG" >&2
    return 0
  fi

  mkdir -p "$SECONDARY_LOG_DIR" 2>/dev/null || {
    printf '%s\n' " [WARN] cannot create $SECONDARY_LOG_DIR — logs kept in $BACKUP_BASE" >&2
    return 0
  }

  # Copy, confirm the destination is non-empty, then drop the local file.
  local pair src dst kept=0
  for pair in "${RUN_LOG}:backup.log" \
              "${XTRABACKUP_LOG}:xtrabackup.log" \
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
    printf '%s\n' " [WARN] $kept log(s) could not be published — kept in $BACKUP_BASE" >&2
  fi
  printf '%s\n' " logs published to $SECONDARY_LOG_DIR"
}

# Safety net only. A successful run leaves nothing in BACKUP_BASE, so this
# clears what an earlier run kept because the share was unreachable.
# Never touches this run's files: -mtime is in whole days.
prune_local() {
  local f n=0
  while IFS= read -r f; do
    rm -f "$f" 2>/dev/null && n=$((n + 1))
  done < <(find "$BACKUP_BASE" -maxdepth 1 -type f \
             \( -name '*_backup.log' -o -name '*_errors.log' -o -name '*_xtrabackup.log' \) \
             -mtime "+${KEEP_LOCAL_DAYS}" 2>/dev/null || true)
  [[ $n -gt 0 ]] && info "pruned $n local log file(s) older than ${KEEP_LOCAL_DAYS} days"
  return 0
}

drop() {
  [[ -n "${1:-}" && -e "$1" ]] || return 0
  info "removing $1"
  rm -rf "$1" 2>/dev/null || true
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
  banner " BACKUP FAILED  ${BACKUP_ID:-(no id)}"
  kv "failed in" "$at"
  if [[ ${INTERRUPTED:-0} -eq 1 ]]; then
    kv "cause" "interrupted — Ctrl-C or kill"
  elif [[ ${DIED:-0} -eq 0 && -n "${FAILED_CMD:-}" ]]; then
    kv "cause"          "uncaught failure — no check reported this"
    kv "failed command" "$FAILED_CMD"
    kv "at line"        "${FAILED_LINE:-?}  (exit ${FAILED_RC:-?})"
  fi
  kv "duration"  "$(elapsed "${START_EPOCH:-$(date +%s)}")"
  sub

  PHASE="cleanup"; STEP="-"
  drop "${LOCK_FILE:-}"

  if [[ "$TRANSFER_OK" == "yes" ]]; then
    warn "archive already verified on the share — KEEPING ${SECONDARY_FILE:-?}"
  else
    drop "${STREAM_FILE:-}"
    drop "${SECONDARY_FILE:-/nonexistent}.part"
  fi
  drop "${CHECKSUM_FILE:-}"
  drop "${BINLOG_INFO_FILE:-}"
  drop "${MANIFEST_FILE:-}"
  drop "${LSN_DIR:-}"

  sub
  kv "error log"      "${ERROR_LOG:-(none)}"
  kv "xtrabackup log" "${XTRABACKUP_LOG:-(none)}"
  banner " RESULT failed id=${BACKUP_ID:-none} phase=${at% *} step=${at#* } dur_s=$(( $(date +%s) - ${START_EPOCH:-$(date +%s)} )) warn=${WARN_COUNT}"

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

free_gb() { df -BG "$1" | awk 'NR==2 {print $4}' | sed 's/G//'; }
mysql_q() { "$MYSQL_BIN" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -NBe "$1" 2>/dev/null; }

writable() {
  local probe="$1/.probe_$$"
  touch "$probe" 2>/dev/null || return 1
  rm -f "$probe"
  return 0
}

mysql_up() {
  systemctl is-active --quiet mysql  2>/dev/null && return 0
  systemctl is-active --quiet mysqld 2>/dev/null && return 0
  pgrep -x mysqld >/dev/null 2>&1    && return 0
  return 1
}

# A dropped CIFS mount reverts to an empty local dir that passes [[ -d ]],
# so: mountpoint, then an actual write.
smb_ready() {
  mountpoint -q "$SMB_MOUNT_POINT" || return 1
  writable "$SECONDARY_STORAGE_DIR" || return 2
  return 0
}

# BASH_REMATCH, not sed|head: a non-match must not fail the run under pipefail.
binlog_field() {
  [[ "$2" =~ $1[[:space:]]*\'([^\']*)\' ]] && printf '%s' "${BASH_REMATCH[1]}"
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# PART 5  IDENTITY AND PATHS
# ═══════════════════════════════════════════════════════════════════════════

# Bare date for the daily run; a time is appended only when that day's archive
# already exists. The SHARE is the authoritative test — local staging is emptied
# after every run, so only a published archive proves the day is taken.
BACKUP_ID="$(date +%Y%m%d)"
if [[ -e "${SECONDARY_STORAGE_DIR}/${BACKUP_ID}.xbstream" ]]; then
  BACKUP_ID="${BACKUP_ID}_$(date +%H%M%S)"
  SAME_DAY_RERUN=yes
else
  SAME_DAY_RERUN=no
fi

START_EPOCH="$(date +%s)"

STREAM_FILE="${BACKUP_BASE}/${BACKUP_ID}.xbstream"
CHECKSUM_FILE="${BACKUP_BASE}/${BACKUP_ID}.sha256"
BINLOG_INFO_FILE="${BACKUP_BASE}/${BACKUP_ID}_binlog_info"
LSN_DIR="${XB_TMPDIR}/${BACKUP_ID}"                       # only on-disk metadata
LOCK_FILE="${LOCK_DIR}/$(basename "$BACKUP_BASE")_$(date +%Y%m%d)_lock"

RUN_LOG="${BACKUP_BASE}/${BACKUP_ID}_backup.log"
ERROR_LOG="${BACKUP_BASE}/${BACKUP_ID}_errors.log"
XTRABACKUP_LOG="${BACKUP_BASE}/${BACKUP_ID}_xtrabackup.log"
SECONDARY_LOG_DIR="${SECONDARY_STORAGE_DIR}/logs/${BACKUP_ID}"

SECONDARY_FILE=""
MANIFEST_FILE=""
META_DIR=""

# ═══════════════════════════════════════════════════════════════════════════
# PART 6  BOOTSTRAP
# ═══════════════════════════════════════════════════════════════════════════

if [[ -z "$SECONDARY_STORAGE_DIR" ]]; then
  echo "[ERROR] SECONDARY_STORAGE_DIR is empty — the backup has nowhere to go." >&2
  exit 1
fi
if [[ "$SECONDARY_STORAGE_DIR" == "$BACKUP_BASE"* ]]; then
  echo "[ERROR] SECONDARY_STORAGE_DIR is inside BACKUP_BASE — scratch is wiped each run." >&2
  exit 1
fi
for dir in "$BACKUP_BASE" "$XB_TMPDIR" "$LSN_DIR" "$LOCK_DIR"; do
  if [[ ! -d "$dir" ]] && ! mkdir -p "$dir" 2>/dev/null; then
    echo "[ERROR] Failed to create directory: $dir" >&2
    exit 1
  fi
done

printf 'errors for backup run %s (started %s)\n\n' "$BACKUP_ID" "$(date '+%F %T')" > "$ERROR_LOG"

banner " BACKUP RUN $BACKUP_ID"
kv "started"     "$(date '+%F %T %Z')"
kv "backup id"   "$BACKUP_ID$([[ "$SAME_DAY_RERUN" == yes ]] && echo "  (same-day rerun — a bare-date archive already exists)")"
kv "host"        "$(hostname -s 2>/dev/null || echo unknown)"
kv "datadir"     "$MYSQL_DATADIR"
kv "destination" "$SECONDARY_STORAGE_DIR"
kv "staging"     "$BACKUP_BASE"
kv "compression" "zstd level $ZSTD_LEVEL"
kv "threads"     "$PARALLEL_THREADS read / $COMPRESS_THREADS compress"
kv "prepare"     "NOT done here — restore.sh runs --prepare"
sub

prune_local

# ═══════════════════════════════════════════════════════════════════════════
# PART 7  PRE-FLIGHT
# ═══════════════════════════════════════════════════════════════════════════

phase preflight
PREFLIGHT_EPOCH="$PHASE_EPOCH"

check
if [[ $EUID -ne 0 ]]; then
  nok "user privileges" "NOT ROOT"
  cont "must read $MYSQL_DATADIR and write $SECONDARY_STORAGE_DIR"
else
  ok "user privileges"
fi

check
for cmd in xtrabackup xbstream mysql awk sed du df grep sha256sum mountpoint stat; do
  command -v "$cmd" >/dev/null 2>&1 \
    || die "$(leader 'required binaries' 'MISSING')" "not found in PATH: $cmd"
done
ok "required binaries"

# --compress-zstd-level needs 8.0.30+. Captured whole: on newer builds the first
# --version line is a [Note] log line, and `| head` under pipefail can trip ERR.
check
set +e
XTRABACKUP_VERSION_RAW="$("$XTRABACKUP_BIN" --version 2>&1)"
set -e
XB_BANNER="$(grep -m1 'xtrabackup version' <<< "$XTRABACKUP_VERSION_RAW" || true)"
[[ -n "$XB_BANNER" ]] || XB_BANNER="$(head -1 <<< "$XTRABACKUP_VERSION_RAW")"

if [[ "$XB_BANNER" =~ ([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
  XB_VER="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
  if [[ ${BASH_REMATCH[1]} -lt 8 ]] \
     || { [[ ${BASH_REMATCH[1]} -eq 8 && ${BASH_REMATCH[2]} -eq 0 && ${BASH_REMATCH[3]} -lt 30 ]]; }; then
    die "$(leader 'xtrabackup version' "$XB_VER")" \
        "--compress-zstd-level requires 8.0.30 or newer" \
        "upgrade, or use server/physical/ instead"
  fi
  val "xtrabackup version" "$XB_VER"
else
  nok "xtrabackup version" "UNPARSED"
  cont "banner was: ${XB_BANNER:-(no output)}"
  cont "below 8.0.30 the stream will fail on --compress-zstd-level"
fi

check
mysql_up || die "$(leader 'mysql running' 'NO')"
ok "mysql running"

check
[[ -d "$MYSQL_DATADIR" && -r "$MYSQL_DATADIR" ]] \
  || die "$(leader 'datadir readable' 'NO')" "missing or unreadable: $MYSQL_DATADIR"
ok "datadir readable"

check
mysql_q "SELECT 1" >/dev/null \
  || die "$(leader 'mysql connection' 'FAILED')" "user: $MYSQL_USER"
ok "mysql connection"

check
for dir in "$BACKUP_BASE" "$LSN_DIR"; do
  writable "$dir" || die "$(leader 'staging writable' 'NO')" "not writable: $dir"
done
ok "staging writable"

check
mountpoint -q "$SMB_MOUNT_POINT" \
  || die "$(leader 'smb share' 'NOT MOUNTED')" \
         "expected a mount at $SMB_MOUNT_POINT" \
         "the path may exist as an empty local directory — writing there" \
         "would fill the root filesystem instead of the NAS"
mkdir -p "$SECONDARY_STORAGE_DIR" 2>/dev/null \
  || die "$(leader 'smb share' 'MKDIR FAILED')" "cannot create $SECONDARY_STORAGE_DIR"
writable "$SECONDARY_STORAGE_DIR" \
  || die "$(leader 'smb share' 'NOT WRITABLE')" \
         "mounted but not writable: $SECONDARY_STORAGE_DIR" \
         "stale handle, auth failure, or uid=/gid=/file_mode= mount options"
ok "smb share"

check
DATADIR_BYTES=$(du -sb "$MYSQL_DATADIR" 2>/dev/null | awk '{print $1}')
DATADIR_GB=$(( DATADIR_BYTES / 1073741824 + 1 ))     # derived, not a second du
REQUIRED_GB=$(( (DATADIR_GB * STREAM_SPACE_PCT + 99) / 100 ))
STAGE_FREE_GB=$(free_gb "$BACKUP_BASE")
SHARE_FREE_GB=$(free_gb "$SECONDARY_STORAGE_DIR")

[[ $STAGE_FREE_GB -ge $REQUIRED_GB ]] \
  || die "$(leader 'disk space' 'INSUFFICIENT')" \
         "staging $BACKUP_BASE: need ${REQUIRED_GB}GB, have ${STAGE_FREE_GB}GB" \
         "raise STREAM_SPACE_PCT if the data compresses poorly"
[[ $SHARE_FREE_GB -ge $REQUIRED_GB ]] \
  || die "$(leader 'disk space' 'INSUFFICIENT')" \
         "share $SECONDARY_STORAGE_DIR: need ${REQUIRED_GB}GB, have ${SHARE_FREE_GB}GB"
val "disk space" "need ${REQUIRED_GB}GB / stage ${STAGE_FREE_GB}GB / share ${SHARE_FREE_GB}GB"
cont "datadir $(hsize "$DATADIR_BYTES"), estimate is ${STREAM_SPACE_PCT}% of it"

check
pgrep -f "xtrabackup.*--backup" >/dev/null 2>&1 \
  && die "$(leader 'no concurrent backup' 'FAILED')" "another xtrabackup --backup is running"
ok "no concurrent backup"

check
if [[ "$(mysql_q 'SELECT @@log_bin' || echo 0)" != "1" ]]; then
  nok "binary logging" "DISABLED"
  cont "point-in-time recovery from this backup will NOT be possible"
else
  ok "binary logging"
fi

check
[[ -z "$(ls -A "$LSN_DIR" 2>/dev/null)" ]] \
  || die "$(leader 'metadata dir empty' 'NO')" \
         "$LSN_DIR is not empty; stale metadata would read as this run's"
ok "metadata dir empty"

check
for pair in "PARALLEL_THREADS:$PARALLEL_THREADS" \
            "COMPRESS_THREADS:$COMPRESS_THREADS" \
            "ZSTD_LEVEL:$ZSTD_LEVEL"; do
  [[ "${pair##*:}" =~ ^[1-9][0-9]*$ ]] \
    || die "$(leader 'thread settings' 'INVALID')" \
           "${pair%:*} must be a positive integer, got '${pair##*:}'"
done
CORES=$(nproc 2>/dev/null || echo 0)
if [[ $CORES -gt 0 && $((PARALLEL_THREADS + COMPRESS_THREADS)) -gt $((CORES * 2)) ]]; then
  nok "thread settings" "OVERSUBSCRIBED"
  cont "$((PARALLEL_THREADS + COMPRESS_THREADS)) threads on ${CORES} cores — contends with mysqld"
else
  val "thread settings" "${PARALLEL_THREADS}+${COMPRESS_THREADS} on ${CORES:-?} cores"
fi

check
PROBE_FILE="${BACKUP_BASE}/.sha256_probe_$$"
echo probe > "$PROBE_FILE"
sha256sum "$PROBE_FILE" >/dev/null 2>&1 \
  || { rm -f "$PROBE_FILE"; die "$(leader 'sha256 utility' 'FAILED')" \
         "sha256sum cannot hash a file on $BACKUP_BASE"; }
rm -f "$PROBE_FILE"
ok "sha256 utility"

check
# Second-level guard. PART 5 already appends a time when the day is taken, so a
# collision here means either a same-second rerun, or that the share was
# unreachable when the name was chosen and the day is in fact taken.
[[ ! -f "$STREAM_FILE" && ! -f "${SECONDARY_STORAGE_DIR}/${BACKUP_ID}.xbstream" ]] \
  || die "$(leader 'archive name free' 'NO')" \
         "${BACKUP_ID}.xbstream already exists" \
         "either a run started in this same second, or the share was unreachable" \
         "when this run picked its name — re-run once it is mounted"
ok "archive name free"

STEP="-"
info "$CHECK_N checks passed, ${WARN_COUNT} warning(s)   ($(elapsed "$PREFLIGHT_EPOCH"))"
sub

# ═══════════════════════════════════════════════════════════════════════════
# PART 8  STREAM  1/5
#
# stdout is the archive, stderr is the log, nothing is piped — a pipe would
# hide xtrabackup's exit code behind tee's.
# ═══════════════════════════════════════════════════════════════════════════

echo "$$" > "$LOCK_FILE"

phase stream 1/5
info "starting xtrabackup, progress in $(basename "$XTRABACKUP_LOG")"
info "lock held for binlog_collect.sh: $LOCK_FILE (pid $$)"

set +e
"$XTRABACKUP_BIN" --backup \
  --user="$MYSQL_USER" \
  --password="$MYSQL_PASSWORD" \
  --datadir="$MYSQL_DATADIR" \
  --stream=xbstream \
  --compress \
  --compress-zstd-level="$ZSTD_LEVEL" \
  --parallel="$PARALLEL_THREADS" \
  --compress-threads="$COMPRESS_THREADS" \
  --extra-lsndir="$LSN_DIR" \
  --tmpdir="$XB_TMPDIR" \
  > "$STREAM_FILE" 2> "$XTRABACKUP_LOG"
XB_STATUS=$?
set -e

if [[ $XB_STATUS -ne 0 ]]; then
  cat "$XTRABACKUP_LOG" >> "$ERROR_LOG" 2>/dev/null || true
  erro "xtrabackup --backup exited $XB_STATUS after $(elapsed "$PHASE_EPOCH")"
  cerr "last 40 lines of $XTRABACKUP_LOG:"
  while IFS= read -r l; do cerr "  $l"; done < <(tail -40 "$XTRABACKUP_LOG" 2>/dev/null || true)
  fail_run
fi

STREAM_BYTES=$(stat -c%s "$STREAM_FILE")
info "done  $(hsize "$STREAM_BYTES")  ($(elapsed "$PHASE_EPOCH"))"

# ═══════════════════════════════════════════════════════════════════════════
# PART 9  VERIFY  2/5
# ═══════════════════════════════════════════════════════════════════════════

phase verify 2/5

# Exactly one: there is no --prepare appending to this log.
COMPLETED_OK=$(grep -c 'completed OK!' "$XTRABACKUP_LOG" || true)
if [[ "${COMPLETED_OK:-0}" -ne 1 ]]; then
  cat "$XTRABACKUP_LOG" >> "$ERROR_LOG" 2>/dev/null || true
  die "$(leader 'completed OK! count' "${COMPLETED_OK:-0}, want 1")" \
      "0 means the backup did not finish; >1 means this log was reused"
fi
ok "completed OK! x1"

[[ -s "$STREAM_FILE" ]] || die "$(leader 'stream non-empty' 'NO')"
ok "stream non-empty"

for meta in xtrabackup_checkpoints xtrabackup_info; do
  [[ -s "${LSN_DIR}/${meta}" ]] \
    || die "$(leader 'extra-lsndir metadata' 'MISSING')" \
           "missing or empty: ${LSN_DIR}/${meta}" \
           "refusing to publish an archive that cannot be described"
done
ok "extra-lsndir metadata"

BACKUP_TYPE=$(awk '/backup_type/ {print $3}' "${LSN_DIR}/xtrabackup_checkpoints")
FROM_LSN=$(awk '/^from_lsn/ {print $3}'      "${LSN_DIR}/xtrabackup_checkpoints")
TO_LSN=$(awk '/^to_lsn/ {print $3}'          "${LSN_DIR}/xtrabackup_checkpoints")

[[ "$BACKUP_TYPE" == "full-backuped" ]] \
  || die "$(leader 'backup_type' "${BACKUP_TYPE:-(empty)}")" \
         "a streamed backup must be 'full-backuped'"
val "backup_type" "$BACKUP_TYPE (unprepared, expected)"
val "lsn range"   "${FROM_LSN:-?} -> ${TO_LSN:-?}"

# ═══════════════════════════════════════════════════════════════════════════
# PART 10  BINLOG POSITION  3/5
#
# No xtrabackup_binlog_info exists in stream mode; the position comes from the
# log, with xtrabackup_info as the fallback.
# ═══════════════════════════════════════════════════════════════════════════

phase binlog 3/5

BINLOG_LINE=$(grep -m1 'MySQL binlog position' "$XTRABACKUP_LOG" || true)
BINLOG_FROM="xtrabackup log"
if [[ -z "$BINLOG_LINE" ]]; then
  BINLOG_LINE=$(grep -m1 '^binlog_pos' "${LSN_DIR}/xtrabackup_info" || true)
  BINLOG_FROM="xtrabackup_info"
fi

BINLOG_NAME="$(binlog_field filename "$BINLOG_LINE")"
BINLOG_POS="$(binlog_field position "$BINLOG_LINE")"

if [[ -n "$BINLOG_NAME" && -n "$BINLOG_POS" ]]; then
  [[ "$BINLOG_NAME" =~ \.[0-9]{6}$ ]] \
    || die "$(leader 'binlog filename' "implausible: $BINLOG_NAME")" \
           "expected <prefix>.NNNNNN, parsed from: $BINLOG_LINE"
  [[ "$BINLOG_POS" =~ ^[0-9]+$ ]] \
    || die "$(leader 'binlog position' "implausible: $BINLOG_POS")"
  printf '%s\t%s\n' "$BINLOG_NAME" "$BINLOG_POS" > "$BINLOG_INFO_FILE"
  val "binlog position" "${BINLOG_NAME}:${BINLOG_POS}"
  cont "source: $BINLOG_FROM"
else
  nok "binlog position" "NOT FOUND"
  cont "absent from the xtrabackup log and xtrabackup_info"
  cont "point-in-time recovery from this backup will NOT be possible"
  echo "unknown 0" > "$BINLOG_INFO_FILE"
  BINLOG_NAME="unknown"
  BINLOG_POS="0"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 11  CHECKSUM  4/5
# ═══════════════════════════════════════════════════════════════════════════

phase sha256 4/5

sha256sum "$STREAM_FILE" > "$CHECKSUM_FILE" 2>>"$ERROR_LOG" \
  || die "failed to generate the SHA-256 checksum"
[[ -s "$CHECKSUM_FILE" ]] || die "the checksum file is empty"
BACKUP_SHA256=$(awk '{print $1}' "$CHECKSUM_FILE")

sha256sum -c "$CHECKSUM_FILE" >/dev/null 2>>"$ERROR_LOG" \
  || die "SHA-256 verification failed on local staging — the stream is corrupt"
val "sha256" "$BACKUP_SHA256"

COMPRESSION_PCT=$(awk -v s="$STREAM_BYTES" -v d="$DATADIR_BYTES" \
  'BEGIN { if (d > 0) printf "%.1f", (s * 100) / d; else printf "n/a" }')
info "verified locally  $(hsize "$STREAM_BYTES") = ${COMPRESSION_PCT}% of datadir  ($(elapsed "$PHASE_EPOCH"))"

# ═══════════════════════════════════════════════════════════════════════════
# PART 12  PUBLISH  5/5
#
# Copy, verify at the destination, then drop the local copy — never a bare move.
# ═══════════════════════════════════════════════════════════════════════════

phase publish 5/5

# Re-asserted: pre-flight may have passed hours ago.
smb_ready || die "the SMB share became unavailable during the backup — cannot publish" \
                 "mount point: $SMB_MOUNT_POINT"

SECONDARY_FILE="${SECONDARY_STORAGE_DIR}/${BACKUP_ID}.xbstream"
[[ ! -e "$SECONDARY_FILE" ]] || die "destination already exists: $SECONDARY_FILE"

info "copying $(hsize "$STREAM_BYTES") to the share"
cp "$STREAM_FILE" "${SECONDARY_FILE}.part" 2>>"$ERROR_LOG" \
  || die "failed to copy the archive to $SECONDARY_STORAGE_DIR"

sync "${SECONDARY_FILE}.part" 2>/dev/null || sync || true

TRANSFERRED_SHA=$(sha256sum "${SECONDARY_FILE}.part" 2>>"$ERROR_LOG" | awk '{print $1}')
[[ "$TRANSFERRED_SHA" == "$BACKUP_SHA256" ]] \
  || die "$(leader 'archive on share' 'CHECKSUM MISMATCH')" \
         "expected $BACKUP_SHA256" \
         "got      ${TRANSFERRED_SHA:-(none)}"

mv "${SECONDARY_FILE}.part" "$SECONDARY_FILE" 2>>"$ERROR_LOG" \
  || die "failed to finalize the archive name on the share"
TRANSFER_OK="yes"
ok "archive verified on share"
info "transferred in $(elapsed "$PHASE_EPOCH")"

rm -f "$STREAM_FILE" 2>>"$ERROR_LOG" || warn "could not remove scratch archive"

# Absolute path inside the file, so `sha256sum -c` resolves from anywhere.
rm -f "$CHECKSUM_FILE" 2>/dev/null || true
CHECKSUM_FILE="${SECONDARY_STORAGE_DIR}/${BACKUP_ID}.sha256"
printf '%s  %s\n' "$BACKUP_SHA256" "$SECONDARY_FILE" > "$CHECKSUM_FILE" 2>>"$ERROR_LOG" \
  || die "failed to write the checksum file to the share"
ok "checksum published"

# binlog_collect.sh anchors on this and reads only the share.
cp "$BINLOG_INFO_FILE" "${SECONDARY_STORAGE_DIR}/${BACKUP_ID}_binlog_info" 2>>"$ERROR_LOG" \
  || die "failed to publish the binlog anchor"
[[ -s "${SECONDARY_STORAGE_DIR}/${BACKUP_ID}_binlog_info" ]] \
  || die "the published binlog anchor is empty"
rm -f "$BINLOG_INFO_FILE" 2>/dev/null || true
BINLOG_INFO_FILE="${SECONDARY_STORAGE_DIR}/${BACKUP_ID}_binlog_info"
ok "binlog anchor published"

META_DIR="${SECONDARY_STORAGE_DIR}/meta/${BACKUP_ID}"
if mkdir -p "$META_DIR" 2>/dev/null; then
  for meta in xtrabackup_checkpoints xtrabackup_info; do
    cp "${LSN_DIR}/${meta}" "${META_DIR}/${meta}" 2>>"$ERROR_LOG" \
      || warn "could not publish metadata file $meta"
  done
  ok "metadata published"
else
  warn "could not create $META_DIR — metadata stays only in the manifest"
  META_DIR="(not published)"
fi

MANIFEST_FILE="${SECONDARY_STORAGE_DIR}/${BACKUP_ID}.manifest"
cat > "${MANIFEST_FILE}.part" <<EOF || die "failed to write the manifest"
backup_id=${BACKUP_ID}
created_at=$(date '+%F %T')
archive_path=${SECONDARY_FILE}
archive_sha256=${BACKUP_SHA256}
archive_format=xbstream
archive_bytes=${STREAM_BYTES}
compression=zstd
compress_zstd_level=${ZSTD_LEVEL}
prepared=no
backup_type=${BACKUP_TYPE}
from_lsn=${FROM_LSN}
to_lsn=${TO_LSN}
datadir_bytes=${DATADIR_BYTES}
mysql_version=$(mysql_q "SELECT VERSION()" || echo unknown)
xtrabackup_version=${XB_BANNER}
binlog_format=$(mysql_q "SELECT @@binlog_format" || echo unknown)
gtid_mode=$(mysql_q "SELECT @@gtid_mode" || echo unknown)
binlog_file=${BINLOG_NAME}
binlog_pos=${BINLOG_POS}
recovery_method=file_position
datadir=${MYSQL_DATADIR}
EOF
mv "${MANIFEST_FILE}.part" "$MANIFEST_FILE" 2>>"$ERROR_LOG" \
  || die "failed to finalize the manifest"
ok "manifest published"

rm -rf "$LSN_DIR" 2>/dev/null || warn "could not remove $LSN_DIR"
LSN_DIR=""

for f in "$SECONDARY_FILE" "$CHECKSUM_FILE" "$BINLOG_INFO_FILE" "$MANIFEST_FILE"; do
  [[ -r "$f" ]] || die "published artifact is not readable: $f"
done

info "re-reading the archive from the share for a final integrity check"
sha256sum -c "$CHECKSUM_FILE" >/dev/null 2>>"$ERROR_LOG" \
  || die "final SHA-256 verification FAILED against the published archive"
ok "final integrity check"

# ═══════════════════════════════════════════════════════════════════════════
# PART 13  SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

rm -f "$LOCK_FILE" 2>/dev/null || true

emit ""
banner " BACKUP OK  $BACKUP_ID"
kv "duration"        "$(elapsed "$START_EPOCH")"
kv "datadir size"    "$(hsize "$DATADIR_BYTES")"
kv "archive size"    "$(hsize "$STREAM_BYTES")  (${COMPRESSION_PCT}% of datadir)"
kv "archive"         "$SECONDARY_FILE"
kv "sha256"          "$BACKUP_SHA256"
kv "binlog position" "${BINLOG_NAME}:${BINLOG_POS}"
kv "backup_type"     "$BACKUP_TYPE  (NOT prepared — restore.sh prepares)"
kv "lsn range"       "${FROM_LSN:-?} -> ${TO_LSN:-?}"
kv "manifest"        "$MANIFEST_FILE"
kv "metadata"        "$META_DIR"
kv "warnings"        "$WARN_COUNT"
sub
kv "restore with"    "./restore.sh $BACKUP_ID --dry-run"
emit "$(printf ' %-16s  %s' '' "./restore.sh $BACKUP_ID")"
sub
kv "logs"            "$SECONDARY_LOG_DIR/"

# ═══════════════════════════════════════════════════════════════════════════
# PART 14  INLINE BINLOG COLLECTION  (best-effort; never fails the run)
# ═══════════════════════════════════════════════════════════════════════════

sub
phase collect
if [[ ! -x "$BINLOG_SCRIPT" ]]; then
  nok "inline collection" "SKIPPED"
  cont "not executable: $BINLOG_SCRIPT"
  cont "cron collects at the next 15-minute interval"
elif "$BINLOG_SCRIPT" >> "$RUN_LOG" 2>&1; then
  ok "inline collection"
else
  nok "inline collection" "FAILED"
  cont "cron retries at the next 15-minute interval"
  cont "collector output is appended above"
fi

PHASE="done"; STEP="-"
banner " RESULT ok id=${BACKUP_ID} dur_s=$(( $(date +%s) - START_EPOCH )) bytes=${STREAM_BYTES} warn=${WARN_COUNT}"

publish_logs

trap - ERR INT TERM
exit 0
