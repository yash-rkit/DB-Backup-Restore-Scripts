#!/usr/bin/env bash
#
# streaming/rnd/restore_logical_secure.sh — restore one encrypted logical dump
#
# Takes a <db>_<run id>.sql.zst.age written by logical_secure.sh, verifies it,
# decrypts it, and imports it over a database. The reverse of that script:
#
#   sha256 -> age -d -> zstd -d -> mysql
#
# DESTRUCTIVE. The target database is dropped and recreated. It therefore
# reports and exits by default; CONFIRM_RESTORE=1, or --confirm, is what lets
# it write. A safety dump of the current contents is taken first.
#
# This is the one script in the set that needs an age PRIVATE key, so it runs
# on the restore host and never on a backup VM.
# Docs: streaming/rnd/encrypted-logical.md §7
#
#   PART 1   configuration        1A set per VM / 1B tune / 1C shared
#   PART 2   log engine
#   PART 3   failure handling
#   PART 4   probes
#   PART 5   usage and arguments
#   PART 6   single-instance lock
#   PART 7   identity and paths
#   PART 8   pre-flight            11 checks
#   PART 9   verify archive        step 1/6
#   PART 10  decrypt               step 2/6
#   PART 11  inspect               step 3/6
#   PART 12  safety dump           step 4/6
#   PART 13  restore               step 5/6
#   PART 14  verify                step 6/6
#   PART 15  summary
#
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# PART 1  CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

# ── 1A  SET PER VM ─────────────────────────────────────────────────────────
MYSQL_USER="__SET_ME__"                              # needs CREATE, DROP, INSERT, and whatever the dump replays
MYSQL_PASSWORD="__SET_ME__"
MYSQL_HOST="__SET_ME__"                              # target instance; "" = local socket
AGE_IDENTITY_FILE="__SET_ME__"                       # the PRIVATE key, e.g. /etc/dbvault/dbvault-ops.key

# ── 1B  TUNING ─────────────────────────────────────────────────────────────
# 0 = report what would happen and stop. 1 = drop the database and import.
# Kept at 0 deliberately: this is the only script here that destroys data.
CONFIRM_RESTORE=0                                    # --confirm overrides for one run
SAFETY_DUMP=1                                        # dump the current contents before dropping
SAFETY_DUMP_DIR=""                                   # empty = beside the archive
KEEP_STAGED_SQL=0                                    # 1 = keep the decrypted .sql after a successful run
STAGE_PCT=115                                        # % of decompressed size wanted free in LOCAL_STAGE

# Mirrors DUMP_OPTS in logical_secure.sh. Change one, change the other.
DUMP_OPTS="--single-transaction --quick --routines --events --triggers \
--set-gtid-purged=OFF --default-character-set=utf8mb4"

# ── 1C  SHARED ─────────────────────────────────────────────────────────────
LOCAL_STAGE="/Data/dbvault-stage"                    # logs and decrypt staging
LOCK_DIR="/var/lock/dbvault"

# ── 1D  NOT SET HERE ───────────────────────────────────────────────────────
MYSQL_BIN="${MYSQL_BIN:-}"                           # PATH
MYSQLDUMP_BIN="${MYSQLDUMP_BIN:-}"                   # PATH
ZSTD_BIN="${ZSTD_BIN:-}"                             # PATH
AGE_BIN="${AGE_BIN:-}"                               # PATH

ARCHIVE=""                                           # --archive=
TARGET_DB=""                                         # --target_db=, default: whatever the dump declares

MYSQL_USER="${DBVAULT_MYSQL_USER:-$MYSQL_USER}"
MYSQL_PASSWORD="${DBVAULT_MYSQL_PASSWORD:-$MYSQL_PASSWORD}"

# ── 1E  GUARD ──────────────────────────────────────────────────────────────
SET_ME_VARS=(MYSQL_USER MYSQL_PASSWORD MYSQL_HOST AGE_IDENTITY_FILE)

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
CHECK_TOTAL=11
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
# The staged plaintext .sql is the one thing that must never be left behind:
# it is the decrypted database, on local disk, outside the encryption this
# whole design exists to provide.
# ═══════════════════════════════════════════════════════════════════════════

START_EPOCH="$(date +%s)"
RUN_ID=""
WORK_DIR=""
SQL_FILE=""
SAFETY_FILE=""
IMPORT_STARTED=0
DIED=0
INTERRUPTED=0
FAILED_CMD=""
FAILED_LINE=""
FAILED_RC=""

scrub_stage() {
  [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] || return 0
  rm -rf "$WORK_DIR" 2>/dev/null || true
  return 0
}

fail_run() {
  trap - ERR INT TERM HUP
  local at="$PHASE $STEP"

  emit ""
  banner " LOGICAL RESTORE FAILED  ${TARGET_DB:-(no db)}  ${RUN_ID:-(no run)}"
  kv "failed in" "$at"
  if [[ ${INTERRUPTED:-0} -eq 1 ]]; then
    kv "cause" "interrupted — Ctrl-C or kill"
  elif [[ ${DIED:-0} -eq 0 && -n "${FAILED_CMD:-}" ]]; then
    kv "cause"          "uncaught failure — no check reported this"
    kv "failed command" "$FAILED_CMD"
    kv "at line"        "${FAILED_LINE:-?}  (exit ${FAILED_RC:-?})"
  fi
  kv "duration" "$(elapsed "$START_EPOCH")"

  # The state the database is in decides what the operator has to do next, so
  # say it plainly rather than leaving it to be worked out.
  if (( IMPORT_STARTED == 1 )); then
    sub
    erro "THE IMPORT HAD ALREADY STARTED"
    cerr "'${TARGET_DB}' is now partially restored and must not be used as is."
    if [[ -n "$SAFETY_FILE" ]]; then
      cerr "roll back with the safety dump taken before this run:"
      cerr "  $AGE_BIN -d -i $AGE_IDENTITY_FILE '$SAFETY_FILE' | $ZSTD_BIN -d | mysql ..."
    else
      cerr "there is NO safety dump — re-run the restore once the cause is fixed."
    fi
  elif [[ -n "$SAFETY_FILE" ]]; then
    sub
    kv "safety dump" "$SAFETY_FILE"
    cont "the database was not touched; this dump can be deleted"
  fi

  sub
  kv "error log" "${ERROR_LOG:-(none)}"
  scrub_stage
  banner " RESULT failed db=${TARGET_DB:-none} run=${RUN_ID:-none} phase=${at% *} step=${at#* } dur_s=$(( $(date +%s) - START_EPOCH )) warn=${WARN_COUNT}"
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
trap 'INTERRUPTED=1; fail_run' INT TERM HUP

# ═══════════════════════════════════════════════════════════════════════════
# PART 4  PROBES
# ═══════════════════════════════════════════════════════════════════════════

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
Usage: $0 --archive=PATH [--target_db=NAME] [--confirm] [--no-safety-dump]

  Step 1  verify    check the archive against its .sha256 sidecar
  Step 2  decrypt   age -d, then zstd -d, to a staged .sql
  Step 3  inspect   confirm the dump is what it claims to be
  Step 4  safety    dump the current contents before they are replaced
  Step 5  restore   import the dump
  Step 6  verify    count what landed

  --archive=PATH      the .sql.zst.age to restore (required)
  --target_db=NAME    restore into this database instead of the one the dump
                      declares; the dump is rewritten as it is imported
  --confirm           actually do it. Without this the script reports and stops
  --no-safety-dump    skip the pre-restore dump of the current contents
  --keep-sql          keep the decrypted .sql after a successful run

DESTRUCTIVE: the target database is dropped and recreated.

Decryption needs the PRIVATE key in AGE_IDENTITY_FILE (PART 1A), which is why
this runs on the restore host and never on a backup VM.

Current settings (PART 1):
  AGE_IDENTITY_FILE = $AGE_IDENTITY_FILE
  CONFIRM_RESTORE   = $CONFIRM_RESTORE  $([[ $CONFIRM_RESTORE -eq 0 ]] && echo '(report only)' || echo '(WILL EXECUTE)')
  SAFETY_DUMP       = $SAFETY_DUMP

Example:
  $0 --archive=/livestorage/Backup/NAME/somedb/somedb_2026-09-14_02-30-01.sql.zst.age --confirm
EOF
  trap - ERR INT TERM HUP
  exit 1
}

argfail() { echo "[ERROR] $1" >&2; trap - ERR INT TERM HUP; exit 1; }

[[ $# -ge 1 ]] || usage

for arg in "$@"; do
  case "$arg" in
    --archive=*)      ARCHIVE="${arg#*=}" ;;
    --target_db=*)    TARGET_DB="${arg#*=}" ;;
    --confirm)        CONFIRM_RESTORE=1 ;;
    --no-safety-dump) SAFETY_DUMP=0 ;;
    --keep-sql)       KEEP_STAGED_SQL=1 ;;
    -h|--help)        usage ;;
    *) echo "[ERROR] Unknown argument: $arg" >&2; usage ;;
  esac
done

check_set_me

resolve_bin MYSQL_BIN     mysql
resolve_bin MYSQLDUMP_BIN mysqldump
resolve_bin ZSTD_BIN      zstd
resolve_bin AGE_BIN       age

[[ -n "$ARCHIVE" ]] || argfail "--archive is required"
[[ "$ARCHIVE" == /* ]] || argfail "--archive must be an absolute path: $ARCHIVE"
[[ -n "$TARGET_DB" && ! "$TARGET_DB" =~ ^[A-Za-z0-9_$-]+$ ]] \
  && argfail "Invalid --target_db: $TARGET_DB"

# ═══════════════════════════════════════════════════════════════════════════
# PART 6  SINGLE-INSTANCE LOCK
#
# Per target instance, not per database: two restores into one MySQL are a
# recipe for a half-applied pair nobody can untangle.
# ═══════════════════════════════════════════════════════════════════════════

mkdir -p "$LOCK_DIR" "$LOCAL_STAGE" 2>/dev/null || true
exec 200>"${LOCK_DIR}/restore_logical_$(echo "${MYSQL_HOST:-localsocket}" | tr -c 'A-Za-z0-9._-' '_').lock"
if ! flock -n 200; then
  echo "[ERROR] Another logical restore is already running against ${MYSQL_HOST:-the local socket}." >&2
  trap - ERR INT TERM HUP
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 7  IDENTITY AND PATHS
# ═══════════════════════════════════════════════════════════════════════════

RUN_ID="$(date +%Y-%m-%d_%H-%M-%S)"
RUN_STAMP="$(date +%Y%m%d_%H%M%S)"
ARCHIVE_BASE="$(basename "$ARCHIVE")"
ARCHIVE_DIR="$(dirname "$ARCHIVE")"

# <db>_<run id>.sql.zst.age — used only to cross-check what the dump declares.
NAME_DB="${ARCHIVE_BASE%%_[0-9][0-9][0-9][0-9]-*}"

RUN_LOG="${LOCAL_STAGE}/restore_${NAME_DB}_${RUN_STAMP}.log"
ERROR_LOG="${LOCAL_STAGE}/restore_${NAME_DB}_${RUN_STAMP}_errors.log"

# 0700: this holds the decrypted database for the length of the restore.
WORK_DIR="${LOCAL_STAGE}/.restore_${NAME_DB}_${RUN_STAMP}"
mkdir -p "$WORK_DIR" 2>/dev/null || {
  echo "[ERROR] Failed to create $WORK_DIR" >&2
  trap - ERR INT TERM HUP; exit 1; }
chmod 700 "$WORK_DIR" 2>/dev/null || true

printf 'errors for logical restore of %s run %s\n\n' "$ARCHIVE_BASE" "$RUN_ID" > "$ERROR_LOG"

banner " LOGICAL RESTORE  $ARCHIVE_BASE  $RUN_ID"
kv "started"    "$(date '+%F %T %Z')"
kv "host"       "$(hostname -s 2>/dev/null || echo unknown)"
kv "archive"    "$ARCHIVE"
kv "target"     "${MYSQL_HOST:-local socket}"
kv "identity"   "$AGE_IDENTITY_FILE"
kv "staging"    "$WORK_DIR (decrypted dump, removed at the end)"
kv "mode"       "$( (( CONFIRM_RESTORE == 1 )) && echo 'CONFIRMED — will drop and import' || echo 'report only — nothing will change')"
sub

# ═══════════════════════════════════════════════════════════════════════════
# PART 8  PRE-FLIGHT
# ═══════════════════════════════════════════════════════════════════════════

phase preflight
PREFLIGHT_EPOCH="$PHASE_EPOCH"

check
for cmd in mysql mysqldump zstd age sha256sum awk stat df flock numfmt; do
  command -v "$cmd" >/dev/null 2>&1 \
    || die "$(leader 'required binaries' 'MISSING')" \
           "not found in PATH: $cmd" \
           "on Ubuntu: sudo apt install zstd age"
done
for bin in "$MYSQL_BIN" "$MYSQLDUMP_BIN" "$ZSTD_BIN" "$AGE_BIN"; do
  [[ -x "$bin" ]] || die "$(leader 'required binaries' 'MISSING')" "not executable: $bin"
done
ok "required binaries"

check
[[ -f "$ARCHIVE" ]] || die "$(leader 'archive' 'NOT FOUND')" "$ARCHIVE"
[[ -r "$ARCHIVE" ]] || die "$(leader 'archive' 'UNREADABLE')" "$ARCHIVE"
[[ -s "$ARCHIVE" ]] || die "$(leader 'archive' 'EMPTY')" "$ARCHIVE"
ARCHIVE_BYTES="$(stat -c%s "$ARCHIVE")"
val "archive" "$(hsize "$ARCHIVE_BYTES")"

# An archive that is not age-encrypted is not one of ours, and feeding it to
# age -d would fail later with a far less obvious message.
check
if [[ "$(head -c 21 "$ARCHIVE" 2>/dev/null)" != "age-encryption.org/v1" ]]; then
  die "$(leader 'archive format' 'NOT AGE-ENCRYPTED')" \
      "$ARCHIVE does not start with the age header" \
      "this script restores .sql.zst.age written by logical_secure.sh" \
      "for a plain .tar.gz use the older restore path"
fi
ok "archive format"

check
[[ -f "$AGE_IDENTITY_FILE" ]] \
  || die "$(leader 'age identity' 'NOT FOUND')" \
         "$AGE_IDENTITY_FILE does not exist" \
         "this is the PRIVATE key — see streaming/rnd/encrypted-logical.md §2"
[[ -r "$AGE_IDENTITY_FILE" ]] \
  || die "$(leader 'age identity' 'UNREADABLE')" "$AGE_IDENTITY_FILE"
grep -q 'AGE-SECRET-KEY-' "$AGE_IDENTITY_FILE" 2>/dev/null \
  || die "$(leader 'age identity' 'NOT A PRIVATE KEY')" \
         "$AGE_IDENTITY_FILE holds no AGE-SECRET-KEY- line" \
         "a recipients file of age1... PUBLIC keys cannot decrypt anything"

# A private key readable by others is the same failure as no encryption.
# The last two octal digits are group and other. Anything but 0 there means
# someone else on this host can read the key.
IDENT_MODE="$(stat -c%a "$AGE_IDENTITY_FILE" 2>/dev/null || echo '?')"
if [[ "$IDENT_MODE" =~ ^[0-7]+$ ]] && (( 10#${IDENT_MODE: -2} != 0 )); then
  nok "age identity" "MODE $IDENT_MODE"
  cont "the private key is readable beyond its owner — chmod 600 it"
else
  val "age identity" "mode $IDENT_MODE"
fi

check
writable "$LOCAL_STAGE" \
  || die "$(leader 'local stage writable' 'NO')" "not writable: $LOCAL_STAGE"
ok "local stage writable"

# The decrypted dump is written here in full. zstd knows the decompressed size
# from the frame header, so this is a real number rather than a guess — but
# only once the archive is decrypted, so the estimate uses the measured ratio.
check
STAGE_AVAIL="$(df -Pk "$LOCAL_STAGE" 2>/dev/null | tail -1 | awk '{print $4}')"
[[ "$STAGE_AVAIL" =~ ^[0-9]+$ ]] || STAGE_AVAIL=0
STAGE_AVAIL=$(( STAGE_AVAIL * 1024 ))
NEED_EST=$(( ARCHIVE_BYTES * 7 * STAGE_PCT / 100 ))   # ~6.3x measured, rounded up
if (( STAGE_AVAIL > 0 && STAGE_AVAIL < NEED_EST )); then
  die "$(leader 'stage space' 'NOT ENOUGH')" \
      "the decrypted dump is expected to need about $(hsize "$NEED_EST")" \
      "only $(hsize "$STAGE_AVAIL") is free in $LOCAL_STAGE" \
      "point LOCAL_STAGE at a bigger filesystem, or free space here"
fi
val "stage space" "need ~$(hsize "$NEED_EST"), have $(hsize "$STAGE_AVAIL")"

check
mysql_q "SELECT 1" >/dev/null \
  || die "$(leader 'mysql connection' 'FAILED')" \
         "user $MYSQL_USER at ${MYSQL_HOST:-local socket}"
val "mysql connection" "$(mysql_q 'SELECT VERSION()' 2>/dev/null || echo unknown)"

# Dropping and recreating needs more than the dump's own statements do.
check
GRANTS="$(mysql_q "SHOW GRANTS" 2>/dev/null | tr '\n' ' ' || true)"
if [[ "$GRANTS" == *"ALL PRIVILEGES ON *.*"* || "$GRANTS" == *"DROP"* ]]; then
  ok "restore privileges"
else
  nok "restore privileges" "UNCERTAIN"
  cont "could not confirm DROP on this account — the restore may fail partway"
fi

check
SIDECAR="${ARCHIVE}.sha256"
if [[ -f "$SIDECAR" && -s "$SIDECAR" ]]; then
  val "checksum sidecar" "$(basename "$SIDECAR")"
else
  nok "checksum sidecar" "MISSING"
  cont "$SIDECAR is not there — the archive cannot be proven intact before use"
  cont "age will still refuse to decrypt a tampered file, so this is not fatal"
fi

check
if (( SAFETY_DUMP == 1 )); then
  SAFETY_TARGET_DIR="${SAFETY_DUMP_DIR:-$ARCHIVE_DIR}"
  if [[ -d "$SAFETY_TARGET_DIR" ]] && writable "$SAFETY_TARGET_DIR"; then
    val "safety dump" "to $SAFETY_TARGET_DIR"
  else
    nok "safety dump" "DIR NOT WRITABLE"
    cont "$SAFETY_TARGET_DIR — the restore will have no rollback"
    SAFETY_DUMP=0
  fi
else
  skp "safety dump" "disabled (--no-safety-dump)"
fi

check
{ [[ -d "$WORK_DIR" ]] && writable "$WORK_DIR"; } \
  || die "$(leader 'work dir' 'UNUSABLE')" "$WORK_DIR"
ok "work dir"

STEP="-"
info "$CHECK_N checks passed, ${WARN_COUNT} warning(s)   ($(elapsed "$PREFLIGHT_EPOCH"))"
sub

# ═══════════════════════════════════════════════════════════════════════════
# PART 9  VERIFY ARCHIVE  1/6
#
# The cheap check, and the one that distinguishes "the file on the share is
# damaged" from "the key is wrong" — both of which surface as a failed decrypt.
# ═══════════════════════════════════════════════════════════════════════════

phase verify 1/6

if [[ -f "$SIDECAR" && -s "$SIDECAR" ]]; then
  if ( cd "$ARCHIVE_DIR" && sha256sum -c --quiet "$(basename "$SIDECAR")" ) 2>>"$ERROR_LOG"; then
    ok "checksum"
  else
    die "$(leader 'checksum' 'MISMATCH')" \
        "$ARCHIVE does not match $SIDECAR" \
        "the archive is damaged or was replaced — do NOT restore from it" \
        "check the copy on the other share before doing anything else"
  fi
else
  skp "checksum" "no sidecar to check against"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 10  DECRYPT  2/6
#
# age -d then zstd -d, in one pipe, to a staged .sql. Staged rather than piped
# straight into mysql so PART 11 can look at it before anything is dropped:
# importing the wrong archive over a live database is not recoverable.
# ═══════════════════════════════════════════════════════════════════════════

phase decrypt 2/6

SQL_FILE="${WORK_DIR}/${NAME_DB}.sql"

DECRYPT_EPOCH="$(date +%s)"

# `if !` rather than `set +e`: a ( ) subshell still fires the ERR trap even
# with errexit off, which would report this as an uncaught failure instead of
# the diagnosis below. A command in an if-condition is exempt from both.
if ! ( set -o pipefail
       "$AGE_BIN" -d -i "$AGE_IDENTITY_FILE" "$ARCHIVE" 2>>"$ERROR_LOG" \
         | "$ZSTD_BIN" -d -q -o "$SQL_FILE" 2>>"$ERROR_LOG" ); then
  rm -f "$SQL_FILE" 2>/dev/null || true
  die "$(leader 'decrypt' 'FAILED')" \
      "age or zstd could not decrypt $ARCHIVE" \
      "" \
      "the usual causes, in order of likelihood:" \
      "  the key in $AGE_IDENTITY_FILE was not a recipient of this archive" \
      "  the archive is truncated or corrupt (its checksum would usually catch that)" \
      "" \
      "the manifest beside the archive lists which public keys can open it:" \
      "  grep age_recipients ${ARCHIVE_DIR%/*}/manifests/*.manifest"
fi

[[ -s "$SQL_FILE" ]] \
  || die "$(leader 'decrypt' 'EMPTY RESULT')" \
         "the archive decrypted to nothing"

SQL_BYTES="$(stat -c%s "$SQL_FILE")"
val "decrypted" "$(hsize "$SQL_BYTES") in $(elapsed "$DECRYPT_EPOCH")"
cont "$(awk -v a="$ARCHIVE_BYTES" -v s="$SQL_BYTES" 'BEGIN{printf "%.1fx compression", s/a}')"

# ═══════════════════════════════════════════════════════════════════════════
# PART 11  INSPECT  3/6
#
# What the dump actually contains, checked BEFORE anything is dropped. A
# renamed or mis-selected archive imported over a live database is the failure
# this part exists to prevent.
# ═══════════════════════════════════════════════════════════════════════════

phase inspect 3/6

# The dump is authoritative about which database it holds; the file name is
# only a convention and may have been changed by hand.
DUMP_DB="$(grep -m1 -oE 'CREATE DATABASE[^`]*`[^`]+`' "$SQL_FILE" 2>/dev/null \
             | grep -oE '`[^`]+`$' | tr -d '`' || true)"
if [[ -z "$DUMP_DB" ]]; then
  DUMP_DB="$(grep -m1 -oE '^USE `[^`]+`' "$SQL_FILE" 2>/dev/null \
               | grep -oE '`[^`]+`' | tr -d '`' || true)"
fi

[[ -n "$DUMP_DB" ]] \
  || die "$(leader 'dump contents' 'NO DATABASE DECLARED')" \
         "the dump carries neither CREATE DATABASE nor USE" \
         "it was not written by logical_secure.sh, or it is truncated" \
         "pass --target_db=NAME to import it into a named database anyway"

val "dump declares" "$DUMP_DB"

if [[ "$DUMP_DB" != "$NAME_DB" ]]; then
  nok "name vs contents" "DIFFER"
  cont "the file is named for '$NAME_DB' but the dump declares '$DUMP_DB'"
  cont "the dump contents win; the archive may have been renamed"
fi

# Default target is whatever the dump declares. --target_db= overrides it, and
# is the only way to restore into a different name.
if [[ -z "$TARGET_DB" ]]; then
  TARGET_DB="$DUMP_DB"
else
  if [[ "$TARGET_DB" != "$DUMP_DB" ]]; then
    nok "target database" "REDIRECTED"
    cont "importing '$DUMP_DB' into '$TARGET_DB' — the dump is rewritten as it loads"
  fi
fi

TABLE_COUNT="$(grep -c '^CREATE TABLE' "$SQL_FILE" 2>/dev/null || true)"
ROW_INSERTS="$(grep -c '^INSERT INTO' "$SQL_FILE" 2>/dev/null || true)"
val "dump contents" "${TABLE_COUNT:-0} table(s), ${ROW_INSERTS:-0} insert statement(s)"

(( ${TABLE_COUNT:-0} > 0 )) \
  || die "$(leader 'dump contents' 'NO TABLES')" \
         "the dump declares a database but creates no tables" \
         "restoring it would leave an empty schema in place of the current one"

# Informational. This script never applies binlogs.
BINLOG_LINE="$(grep -m1 'CHANGE MASTER TO\|CHANGE REPLICATION SOURCE TO' "$SQL_FILE" 2>/dev/null || true)"
if [[ -n "$BINLOG_LINE" ]]; then
  cont "binlog coordinate: $(printf '%s' "$BINLOG_LINE" | tr -d '-' | tr -s ' ' | cut -c1-90)"
else
  cont "no binlog coordinate in this dump"
fi

# What is about to be replaced.
DB_EXISTS="$(mysql_q "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${TARGET_DB}'" 2>/dev/null || echo 0)"
if [[ "$DB_EXISTS" == "1" ]]; then
  CUR_TABLES="$(mysql_q "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${TARGET_DB}'" 2>/dev/null || echo 0)"
  nok "target database" "EXISTS with ${CUR_TABLES} table(s) — WILL BE DROPPED"
else
  CUR_TABLES=0
  val "target database" "does not exist — will be created"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 12  SAFETY GATE
#
# Everything above this line is read-only. Nothing has been dropped, and the
# report below is the whole point of the default mode.
# ═══════════════════════════════════════════════════════════════════════════

ARCHIVE_AGE_H=$(( ( $(date +%s) - $(stat -c%Y "$ARCHIVE" 2>/dev/null || date +%s) ) / 3600 ))

if (( CONFIRM_RESTORE != 1 )); then
  emit ""
  banner " REPORT ONLY — NOTHING HAS BEEN CHANGED"
  kv "archive"       "$ARCHIVE"
  kv "archive age"   "${ARCHIVE_AGE_H}h old"
  kv "decrypted"     "$(hsize "$SQL_BYTES"), ${TABLE_COUNT} table(s)"
  kv "would restore" "$DUMP_DB -> $TARGET_DB on ${MYSQL_HOST:-local socket}"
  if [[ "$DB_EXISTS" == "1" ]]; then
    kv "current state" "${CUR_TABLES} table(s) — would be DROPPED and replaced"
    kv "data loss"     "everything written to '$TARGET_DB' in the last ${ARCHIVE_AGE_H}h"
  else
    kv "current state" "database does not exist — nothing would be lost"
  fi
  sub
  emit " To execute, re-run with --confirm (or set CONFIRM_RESTORE=1 in PART 1B)."
  sub
  kv "log" "$RUN_LOG"
  scrub_stage
  banner " RESULT report_only db=${TARGET_DB} archive=${ARCHIVE_BASE} dur_s=$(( $(date +%s) - START_EPOCH )) warn=${WARN_COUNT}"
  trap - ERR INT TERM HUP
  exit 0
fi

emit ""
warn "CONFIRM_RESTORE — proceeding with a DESTRUCTIVE restore of '$TARGET_DB'"

# ═══════════════════════════════════════════════════════════════════════════
# PART 13  SAFETY DUMP  4/6
#
# A failure here does NOT stop the restore: the usual reason the current
# contents cannot be dumped is that they are damaged, which is why someone is
# restoring in the first place. It is reported loudly instead.
# ═══════════════════════════════════════════════════════════════════════════

phase safety 4/6

if (( SAFETY_DUMP == 1 )) && [[ "$DB_EXISTS" == "1" ]]; then
  CANDIDATE="${SAFETY_TARGET_DIR}/PRE-RESTORE_${TARGET_DB}_${RUN_STAMP}.sql.zst"
  info "dumping the current contents of '$TARGET_DB' first"
  MAPFILE_ARGS=(); mapfile -t MAPFILE_ARGS < <(mysql_args)
  SAFETY_RC=0
  # if-condition, not `set +e`: see the note in PART 10. A failure here must be
  # reported and survived, never turned into an uncaught trap.
  if ! ( set -o pipefail
         # shellcheck disable=SC2086  # DUMP_OPTS is a deliberate word-split option list
         "$MYSQLDUMP_BIN" "${MAPFILE_ARGS[@]}" $DUMP_OPTS --databases "$TARGET_DB" 2>>"$ERROR_LOG" \
           | "$ZSTD_BIN" -9 -T1 -q -o "$CANDIDATE" 2>>"$ERROR_LOG" ); then
    SAFETY_RC=1
  fi
  if (( SAFETY_RC == 0 )) && [[ -s "$CANDIDATE" ]]; then
    SAFETY_FILE="$CANDIDATE"
    val "safety dump" "$(hsize "$(stat -c%s "$SAFETY_FILE")")"
    cont "rollback: zstd -dc '$SAFETY_FILE' | mysql -u$MYSQL_USER -p"
    cont "NOTE: this dump is NOT encrypted — delete it once the restore is confirmed good"
  else
    rm -f "$CANDIDATE" 2>/dev/null || true
    nok "safety dump" "FAILED"
    cont "the current contents of '$TARGET_DB' could not be dumped, most likely"
    cont "because they are damaged — which is probably why you are restoring."
    cont ""
    cont "CONSEQUENCE: this restore has NO ROLLBACK. Once the database is"
    cont "dropped below, its current contents are gone for good."
  fi
elif [[ "$DB_EXISTS" != "1" ]]; then
  skp "safety dump" "target does not exist, nothing to preserve"
else
  skp "safety dump" "disabled"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 14  RESTORE  5/6
# ═══════════════════════════════════════════════════════════════════════════

phase restore 5/6
RESTORE_EPOCH="$(date +%s)"

mapfile -t MYSQL_ARGV < <(mysql_args)

# From here on the database is being replaced, and fail_run must say so.
IMPORT_STARTED=1

if [[ "$TARGET_DB" != "$DUMP_DB" ]]; then
  # The dump names its own database in CREATE DATABASE / USE, so redirecting it
  # means rewriting those two statements as it streams past.
  info "rewriting '$DUMP_DB' to '$TARGET_DB' during import"
  mysql_q "DROP DATABASE IF EXISTS \`${TARGET_DB}\`" >/dev/null \
    || die "$(leader 'restore' 'DROP FAILED')" "could not drop $TARGET_DB"
  mysql_q "CREATE DATABASE \`${TARGET_DB}\`" >/dev/null \
    || die "$(leader 'restore' 'CREATE FAILED')" "could not create $TARGET_DB"
  IMPORT_RC=0
  if ! ( set -o pipefail
         sed -e "s/\`${DUMP_DB}\`/\`${TARGET_DB}\`/g" "$SQL_FILE" \
           | "$MYSQL_BIN" "${MYSQL_ARGV[@]}" 2>>"$ERROR_LOG" ); then
    IMPORT_RC=1
  fi
else
  # The dump carries its own DROP/CREATE DATABASE, so it replaces the schema on
  # its own terms — no statement here has to guess at the right order.
  mysql_q "DROP DATABASE IF EXISTS \`${TARGET_DB}\`" >/dev/null \
    || die "$(leader 'restore' 'DROP FAILED')" "could not drop $TARGET_DB"
  IMPORT_RC=0
  if ! "$MYSQL_BIN" "${MYSQL_ARGV[@]}" < "$SQL_FILE" 2>>"$ERROR_LOG"; then
    IMPORT_RC=1
  fi
fi

if (( IMPORT_RC != 0 )); then
  die "$(leader 'restore' 'IMPORT FAILED')" \
      "mysql exited $IMPORT_RC partway through the import" \
      "'$TARGET_DB' is now incomplete and must not be used" \
      "$( [[ -n "$SAFETY_FILE" ]] && echo "roll back: zstd -dc '$SAFETY_FILE' | mysql -u$MYSQL_USER -p" \
                                  || echo "there is no safety dump to roll back to" )"
fi

val "imported" "$(elapsed "$RESTORE_EPOCH")"

# ═══════════════════════════════════════════════════════════════════════════
# PART 15  VERIFY  6/6
#
# The dump said how many tables it creates. Anything else landing is a partial
# import that mysql did not report as an error.
# ═══════════════════════════════════════════════════════════════════════════

phase verify 6/6

LANDED="$(mysql_q "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${TARGET_DB}'" 2>/dev/null || echo 0)"
LANDED="${LANDED:-0}"

if (( LANDED == 0 )); then
  die "$(leader 'tables restored' 'NONE')" \
      "'$TARGET_DB' holds no tables after the import" \
      "the restore did not work, whatever mysql reported"
elif (( LANDED != TABLE_COUNT )); then
  nok "tables restored" "$LANDED (dump declared $TABLE_COUNT)"
  cont "views and temporary tables can account for a small difference;"
  cont "a large one means the import did not finish"
else
  val "tables restored" "$LANDED of $TABLE_COUNT"
fi

ROUTINES="$(mysql_q "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='${TARGET_DB}'" 2>/dev/null || echo 0)"
TRIGGERS="$(mysql_q "SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='${TARGET_DB}'" 2>/dev/null || echo 0)"
val "routines/triggers" "${ROUTINES:-0} / ${TRIGGERS:-0}"

# ═══════════════════════════════════════════════════════════════════════════
# PART 16  SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

PHASE="done"; STEP="-"

if (( KEEP_STAGED_SQL == 1 )); then
  KEPT_SQL="${LOCAL_STAGE}/${TARGET_DB}_${RUN_STAMP}.sql"
  mv "$SQL_FILE" "$KEPT_SQL" 2>/dev/null && chmod 600 "$KEPT_SQL" 2>/dev/null || true
fi
scrub_stage

emit ""
banner " LOGICAL RESTORE OK  $TARGET_DB  $RUN_ID"
kv "duration"     "$(elapsed "$START_EPOCH")"
kv "archive"      "$ARCHIVE"
kv "restored"     "$DUMP_DB -> $TARGET_DB on ${MYSQL_HOST:-local socket}"
kv "tables"       "$LANDED"
kv "replaced"     "$( [[ "$DB_EXISTS" == "1" ]] && echo "${CUR_TABLES} table(s)" || echo 'nothing — the database was new')"
kv "safety dump"  "${SAFETY_FILE:-none}"
if (( KEEP_STAGED_SQL == 1 )); then
  kv "staged sql" "${KEPT_SQL:-none}  (PLAINTEXT — delete it when done)"
fi
kv "warnings"     "$WARN_COUNT"
sub
if [[ -n "$SAFETY_FILE" ]]; then
  emit " The safety dump above is UNENCRYPTED and holds the previous contents."
  emit " Delete it once this restore is confirmed good:"
  emit "   rm -f '$SAFETY_FILE'"
  sub
fi
kv "log" "$RUN_LOG"

banner " RESULT ok db=${TARGET_DB} archive=${ARCHIVE_BASE} tables=${LANDED} dur_s=$(( $(date +%s) - START_EPOCH )) warn=${WARN_COUNT}"

trap - ERR INT TERM HUP
exit 0
