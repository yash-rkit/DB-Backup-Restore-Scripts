#!/usr/bin/env bash
#
# Usage:   ./db_cleanup.sh [options]         (--help lists them all)
# Example: ./db_cleanup.sh --config=servers.json --dry-run
#
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# PART 1  CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════


# ── 1A  SET PER VM ─────────────────────────────────────────────────────────
SMB_MOUNT_POINT="__SET_ME__"                         # mount point itself; all that stands between rm and /
EXTRA_MOUNTS=""                                      # other mounts that may hold server paths, space separated

# ── 1B  TUNING ─────────────────────────────────────────────────────────────
SMART_DAILY_DAYS=7                                   # smart: keep every dump for this long,
SMART_WEEKDAY=7                                      #   then this weekday: 1=Mon ... 7=Sun
SMART_WEEKDAY_KEEP=3                                 #   this many of them
ALWAYS_KEEP_NEWEST=1                                 # never delete a database's or server's last one
LOG_KEPT=1                                           # log every archive kept, and why; 0 = deletions only
CLEANUP_LOG_BASE="/livestorage/final/cleanup_logs"   # this script's logs
KEEP_CLEANUP_LOG_DAYS=60
KEEP_LOCAL_DAYS=14                                   # prune logs stranded here

# ── 1C  SHARED ─────────────────────────────────────────────────────────────
CONFIG_FILE="/Data/script/servers.json"              # the server list; --config= overrides
DUMP_ROOT="/livestorage/Backup"                       # base_dir when an entry omits it
LOCAL_STAGE="/Data/dbvault-stage"                    # logs only, during the run
LOCK_DIR="/var/lock/dbvault"

ARCHIVE_GLOB="*.tar.gz"                              # finds a logical set
PHYSICAL_GLOB="*.xbstream"                           # finds a physical set
PHYS_SET_SUFFIXES=".xbstream .sha256 .manifest _binlog_info"
PHYS_SET_DIRS="binlog meta logs"
NON_DB_DIRS="logs manifests cleanup_logs restart-logs meta"  # dirs in a dump tree that are not databases

# ── 1D  NOT SET HERE ───────────────────────────────────────────────────────
DRY_RUN=0                                            # --dry-run

# ── 1E  GUARD ──────────────────────────────────────────────────────────────
# Refuses to start while any 1A value is still __SET_ME__.

SET_ME_VARS=(SMB_MOUNT_POINT)

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
check_set_me

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
CHECK_TOTAL=8
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
# ═══════════════════════════════════════════════════════════════════════════

START_EPOCH="$(date +%s)"
SERVER_COUNT=0
RET_COUNT=0
NOT_CONFIGURED=""
DELETED=0
FREED_BYTES=0
KEPT=0
DELETE_ERRORS=0
DB_DIRS=0
PRUNED_LOGS=0
PUBLISHED_LOGS=0
CURRENT=""
SERVER_NAMES=()
DUMP_TREES=()
RETENTION_PATTERNS=()

PHYS_COUNT=0
PHYS_NOT_CONFIGURED=""
PHYS_DELETED=0
PHYS_KEPT=0
PHYS_ORPHANS=0
PHYSICAL_SERVER_NAMES=()
PHYSICAL_TREES=()
PHYSICAL_PATTERNS=()

publish_logs() {
  [[ "$PUBLISHED_LOGS" == "1" ]] && return 0
  PUBLISHED_LOGS=1
  [[ -n "${SECONDARY_LOG_DIR:-}" ]] || return 0

  if ! mountpoint -q "$SMB_MOUNT_POINT" 2>/dev/null; then
    printf '%s\n' " [WARN] share not mounted — logs kept in $LOCAL_STAGE:" >&2
    printf '%s\n' "        $RUN_LOG" >&2
    return 0
  fi

  mkdir -p "$SECONDARY_LOG_DIR" 2>/dev/null || {
    printf '%s\n' " [WARN] cannot create $SECONDARY_LOG_DIR — logs kept in $LOCAL_STAGE" >&2
    return 0
  }

  local pair src dst kept=0
  for pair in "${RUN_LOG}:cleanup.log" \
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

# Safety net only; -mtime is in whole days, so this run's files are never touched.
prune_local() {
  local f n=0
  while IFS= read -r f; do
    rm -f "$f" 2>/dev/null && n=$((n + 1))
  done < <(find "$LOCAL_STAGE" -maxdepth 1 -type f -name 'db_cleanup_*.log' \
             -mtime "+${KEEP_LOCAL_DAYS}" 2>/dev/null || true)
  [[ $n -gt 0 ]] && info "pruned $n stranded log file(s) older than ${KEEP_LOCAL_DAYS} days"
  return 0
}

DIED=0
INTERRUPTED=0
FAILED_CMD=""
FAILED_LINE=""
FAILED_RC=""

fail_run() {
  trap - ERR INT TERM
  local at="$PHASE $STEP"

  emit ""
  banner " DB CLEANUP FAILED"
  kv "failed in" "$at"
  if [[ ${INTERRUPTED:-0} -eq 1 ]]; then
    kv "cause" "interrupted — Ctrl-C or kill"
  elif [[ ${DIED:-0} -eq 0 && -n "${FAILED_CMD:-}" ]]; then
    kv "cause"          "uncaught failure — no check reported this"
    kv "failed command" "$FAILED_CMD"
    kv "at line"        "${FAILED_LINE:-?}  (exit ${FAILED_RC:-?})"
  fi
  kv "duration"  "$(elapsed "$START_EPOCH")"
  [[ -n "$CURRENT" ]] && kv "working on" "$CURRENT"
  sub

  if [[ $DELETED -gt 0 || $PHYS_DELETED -gt 0 ]]; then
    erro "$DELETED archive(s) and $PHYS_DELETED physical set(s) were ALREADY DELETED"
    cerr "the pass is part-applied and cannot be undone"
    cerr "every deletion is listed above in this log"
  fi

  sub
  kv "error log" "${ERROR_LOG:-(none)}"
  banner " RESULT failed phase=${at% *} step=${at#* } deleted=${DELETED} sets=${PHYS_DELETED} orphans=${PHYS_ORPHANS} freed=${FREED_BYTES} dur_s=$(( $(date +%s) - START_EPOCH )) warn=${WARN_COUNT}"

  publish_logs
  exit 1
}

die() {
  DIED=1
  erro "$1"; shift
  local l; for l in "$@"; do cerr "$l"; done
  fail_run
}

# Captured inside the trap: fail_run's own commands would overwrite BASH_COMMAND.
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

mount_for() {
  local p="$1" m
  for m in $SMB_MOUNT_POINT $EXTRA_MOUNTS; do
    [[ "$p" == "$m"/* ]] && { printf '%s' "$m"; return 0; }
  done
  return 1
}

writable() {
  local probe="$1/.probe_$$"
  touch "$probe" 2>/dev/null || return 1
  rm -f "$probe"
  return 0
}

fsize() { stat -c%s "$1" 2>/dev/null || echo 0; }

jqv() { jq -r "$1" "$CONFIG_FILE" 2>/dev/null || true; }

is_non_db() {
  local name="$1" d
  [[ "$name" == .* || "$name" == _* ]] && return 0
  for d in $NON_DB_DIRS; do
    [[ "$name" == "$d" ]] && return 0
  done
  return 1
}

newest_archive() {
  find "$1" -maxdepth 1 -type f -name "$ARCHIVE_GLOB" -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-
  return 0
}

# delete_file <path> <reason>
delete_file() {
  local f="$1" reason="$2" bytes name
  bytes="$(fsize "$f")"
  name="$(basename "$f")"

  if [[ $DRY_RUN -eq 1 ]]; then
    cont "would delete $name  ($(hsize "$bytes"))  [$reason]"
    DELETED=$((DELETED + 1))
    FREED_BYTES=$(( FREED_BYTES + bytes ))
    return 0
  fi

  if rm -f "$f" 2>>"$ERROR_LOG"; then
    rm -f "${f}.sha256" 2>/dev/null || true
    cont "deleted $name  ($(hsize "$bytes"))  [$reason]"
    DELETED=$((DELETED + 1))
    FREED_BYTES=$(( FREED_BYTES + bytes ))
  else
    erro "$(leader "$name" 'DELETE FAILED')"
    cerr "$f"
    DELETE_ERRORS=$((DELETE_ERRORS + 1))
  fi
  return 0
}

dsize() {
  local b
  b="$(du -sb "$1" 2>/dev/null | awk '{print $1+0}')"
  [[ -n "$b" ]] || b=0
  printf '%s' "$b"
  return 0
}

RET_WHY=""
valid_pattern() {
  RET_WHY=""
  case "$1" in
    smart) return 0 ;;
    days:*)
      [[ "${1#days:}" =~ ^[1-9][0-9]*$ ]] && return 0
      RET_WHY="'$1' — days:N needs N as a positive integer"
      return 1 ;;
    *)
      RET_WHY="'$1' — expected 'smart' or 'days:N'"
      return 1 ;;
  esac
}

# The backup ID of the newest physical set, by archive mtime.
newest_set() {
  find "$1" -maxdepth 1 -type f -name "$PHYSICAL_GLOB" -printf '%T@ %f\n' 2>/dev/null \
    | sort -rn | head -1 | sed 's/^[^ ]* //; s/\.xbstream$//'
  return 0
}

set_bytes() {
  local tree="$1" id="$2" total=0 s d
  for s in $PHYS_SET_SUFFIXES; do
    [[ -f "${tree}/${id}${s}" ]] && total=$(( total + $(fsize "${tree}/${id}${s}") ))
  done
  for d in $PHYS_SET_DIRS; do
    [[ -d "${tree}/${d}/${id}" ]] && total=$(( total + $(dsize "${tree}/${d}/${id}") ))
  done
  printf '%s' "$total"
  return 0
}

# delete_set <tree> <id> <reason> — .xbstream first, so a half-deleted set is invisible to the resolver.
delete_set() {
  local tree="$1" id="$2" reason="$3" bytes s d p failed=0
  bytes="$(set_bytes "$tree" "$id")"

  if [[ $DRY_RUN -eq 1 ]]; then
    cont "would delete set $id  ($(hsize "$bytes"))  [$reason]"
    PHYS_DELETED=$((PHYS_DELETED + 1))
    FREED_BYTES=$(( FREED_BYTES + bytes ))
    return 0
  fi

  for s in $PHYS_SET_SUFFIXES; do
    p="${tree}/${id}${s}"
    [[ -e "$p" ]] || continue
    rm -f "$p" 2>>"$ERROR_LOG" || { failed=$((failed + 1)); cerr "could not delete $p"; }
  done
  for d in $PHYS_SET_DIRS; do
    p="${tree}/${d}/${id}"
    [[ -d "$p" ]] || continue
    rm -rf "$p" 2>>"$ERROR_LOG" || { failed=$((failed + 1)); cerr "could not delete $p"; }
  done

  if [[ $failed -eq 0 ]]; then
    cont "deleted set $id  ($(hsize "$bytes"))  [$reason]"
    PHYS_DELETED=$((PHYS_DELETED + 1))
    FREED_BYTES=$(( FREED_BYTES + bytes ))
  else
    erro "$(leader "set $id" "$failed PART(S) FAILED")"
    cerr "the set is part-deleted; the next run's orphan sweep will finish it"
    DELETE_ERRORS=$((DELETE_ERRORS + failed))
  fi
  return 0
}

guard_days() {
  case "$1" in
    smart)  printf '%s' $(( SMART_DAILY_DAYS + SMART_WEEKDAY_KEEP * 7 )) ;;
    days:*) printf '%s' "${1#days:}" ;;
  esac
  return 0
}

# 1..7 as date's %u numbers them, for the log line and the keep reason.
weekday_name() {
  case "$1" in
    1) printf 'Monday'    ;; 2) printf 'Tuesday'  ;; 3) printf 'Wednesday' ;;
    4) printf 'Thursday'  ;; 5) printf 'Friday'   ;; 6) printf 'Saturday'  ;;
    7) printf 'Sunday'    ;; *) printf 'weekday %s' "$1" ;;
  esac
  return 0
}

sweep_orphans() {
  local tree="$1" guard="$2"
  local d p id bytes cutoff
  cutoff=$(( $(date +%s) - guard * 86400 ))

  for d in $PHYS_SET_DIRS; do
    [[ -d "${tree}/${d}" ]] || continue
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      id="$(basename "$p")"
      [[ -f "${tree}/${id}.xbstream" ]] && continue

      bytes="$(dsize "$p")"
      if [[ $DRY_RUN -eq 1 ]]; then
        cont "would delete orphan ${d}/${id}  ($(hsize "$bytes"))  [no ${id}.xbstream]"
      elif rm -rf "$p" 2>>"$ERROR_LOG"; then
        cont "deleted orphan ${d}/${id}  ($(hsize "$bytes"))  [no ${id}.xbstream]"
      else
        erro "$(leader "orphan ${d}/${id}" 'DELETE FAILED')"
        DELETE_ERRORS=$((DELETE_ERRORS + 1))
        continue
      fi
      PHYS_ORPHANS=$((PHYS_ORPHANS + 1))
      FREED_BYTES=$(( FREED_BYTES + bytes ))
    done < <(find "${tree}/${d}" -mindepth 1 -maxdepth 1 -type d \
               ! -newermt "@${cutoff}" 2>/dev/null | sort || true)
  done
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# PART 5  USAGE AND ARGUMENTS
# ═══════════════════════════════════════════════════════════════════════════

usage() {
  cat <<EOF
Usage: $0 [--config=PATH] [--dry-run]

  Step 1  retention  apply each server's pattern to each of its databases
  Step 2  physical   apply each server's physical pattern to its backup sets
  Step 3  prune      drop this script's own old logs

  --config=PATH  server list, default: $CONFIG_FILE
  --dry-run      list every deletion without performing any

Per entry in the config file:
  server_name         required  the only required field
  base_dir            derived   the dump tree to expire
                                (default: $DUMP_ROOT/<server_name>)
  retention           opt-in    "smart" or "days:N", over base_dir
  backup_base         required alongside physical_retention: the physical tree
  physical_retention  opt-in    "smart" or "days:N", over backup_base

So the shortest useful entry is a name and a rule:
  { "server_name": "Some-DB", "retention": "days:7" }

  smart   everything from the last $SMART_DAILY_DAYS days, plus the last
          $SMART_WEEKDAY_KEEP archives written on a $(weekday_name "$SMART_WEEKDAY")
  days:N  everything from the last N days

The two rules are independent. An entry without retention keeps every dump; an
entry without physical_retention keeps every physical backup. If no entry has
either, this exits without deleting anything.

A physical backup is one ID and seven parts — <ID>.xbstream, its .sha256,
.manifest and _binlog_info, and binlog/<ID>/, meta/<ID>/, logs/<ID>/ — and the
physical pass expires all seven together. A per-ID directory left without its
archive is swept once it is older than that server's retention window.

The two passes measure age differently, as they always have. The logical days:N
is find -mtime +N: whole days, strictly greater, so it keeps a little over N
days. The physical days:N is an exact N x 24h cutoff from the moment of the run.

This touches the primary share only. The second share's retention belongs to
backup_sync.sh.
EOF
  trap - ERR INT TERM
  exit 1
}

argfail() { echo "[ERROR] $1" >&2; trap - ERR INT TERM; exit 1; }

for arg in "$@"; do
  case "$arg" in
    --config=*) CONFIG_FILE="${arg#*=}" ;;
    --dry-run)  DRY_RUN=1 ;;
    -h|--help)  usage ;;
    *) echo "[ERROR] Unknown argument: $arg" >&2; usage ;;
  esac
done

[[ -f "$CONFIG_FILE" ]] || argfail "Config file not found: $CONFIG_FILE"
command -v jq >/dev/null 2>&1 || argfail "jq is required but not installed"

# ═══════════════════════════════════════════════════════════════════════════
# PART 6  SINGLE-INSTANCE LOCK
# ═══════════════════════════════════════════════════════════════════════════

mkdir -p "$LOCK_DIR" "$LOCAL_STAGE" 2>/dev/null || true
exec 200>"${LOCK_DIR}/db_cleanup.lock"
if ! flock -n 200; then
  echo "[ERROR] Another db_cleanup run is already in progress." >&2
  trap - ERR INT TERM
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 7  IDENTITY AND PATHS
# ═══════════════════════════════════════════════════════════════════════════

RUN_STAMP="$(date +%Y%m%d_%H%M%S)"
RUN_LOG="${LOCAL_STAGE}/db_cleanup_${RUN_STAMP}.log"
ERROR_LOG="${LOCAL_STAGE}/db_cleanup_${RUN_STAMP}_errors.log"
SECONDARY_LOG_DIR="${CLEANUP_LOG_BASE}/${RUN_STAMP}"

mkdir -p "$LOCAL_STAGE" 2>/dev/null || {
  echo "[ERROR] Failed to create $LOCAL_STAGE" >&2
  trap - ERR INT TERM; exit 1; }

printf 'errors for db cleanup %s\n\n' "$RUN_STAMP" > "$ERROR_LOG"

banner " DB CLEANUP RUN  $RUN_STAMP"
kv "started"     "$(date '+%F %T %Z')"
kv "host"        "$(hostname -s 2>/dev/null || echo unknown)"
kv "mode"        "$([[ $DRY_RUN -eq 1 ]] && echo 'DRY RUN — nothing is deleted' || echo 'LIVE — deletions are permanent')"
kv "config"      "$CONFIG_FILE"
kv "scope"       "entries with a retention field; the rest are never expired"
kv "keep newest" "$([[ "$ALWAYS_KEEP_NEWEST" == "1" ]] && echo 'yes, always' || echo 'NO — a database can be emptied')"
kv "log kept"    "$([[ "$LOG_KEPT" == "1" ]] && echo 'yes — every archive kept is listed with its reason' || echo 'no — deletions only')"
kv "logs"        "$LOCAL_STAGE during the run, published at the end"
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
  cont "the share is usually mounted for root only — deletions may fail"
else
  ok "user privileges"
fi

check
for cmd in jq find sort stat date rm awk du sed mountpoint flock basename; do
  command -v "$cmd" >/dev/null 2>&1 \
    || die "$(leader 'required binaries' 'MISSING')" "not found in PATH: $cmd"
done
ok "required binaries"

check
jq empty "$CONFIG_FILE" >/dev/null 2>&1 \
  || die "$(leader 'config parses' 'INVALID JSON')" "$CONFIG_FILE"
[[ "$(jqv 'type')" == "array" ]] \
  || die "$(leader 'config parses' 'NOT AN ARRAY')" "expected an array of server objects"
SERVER_COUNT="$(jqv 'length')"
[[ "$SERVER_COUNT" =~ ^[0-9]+$ && "$SERVER_COUNT" -gt 0 ]] \
  || die "$(leader 'config parses' 'EMPTY')" "no entries in $CONFIG_FILE"

PROBLEMS=0
USED_MOUNTS=""
for i in $(seq 0 $((SERVER_COUNT - 1))); do
  n="$(jqv ".[$i].server_name // empty")"
  t="$(jqv ".[$i].base_dir // empty")"
  r="$(jqv ".[$i].retention // empty")"
  pb="$(jqv ".[$i].backup_base // empty")"
  pr="$(jqv ".[$i].physical_retention // empty")"
  label="entry $((i + 1))/$SERVER_COUNT"
  t="${t%/}"
  pb="${pb%/}"

  if [[ -z "$n" ]]; then
    erro "$(leader "$label" 'INCOMPLETE')"
    cerr "server_name is required — every other field is derived from it or optional"
    PROBLEMS=$((PROBLEMS + 1))
    continue
  fi

  [[ -n "$t" ]] || t="${DUMP_ROOT}/${n}"

  # ── the logical rule, over base_dir ──
  if [[ -z "$r" ]]; then
    NOT_CONFIGURED="${NOT_CONFIGURED}${n} "
  else
    if m="$(mount_for "$t")"; then
      USED_MOUNTS="${USED_MOUNTS} ${m}"
    else
      erro "$(leader "$label" 'PATH OFF THE SHARE')"
      cerr "base_dir '$t' is not under $SMB_MOUNT_POINT${EXTRA_MOUNTS:+ or $EXTRA_MOUNTS}"
      PROBLEMS=$((PROBLEMS + 1))
    fi

    if valid_pattern "$r"; then
      SERVER_NAMES+=("$n"); DUMP_TREES+=("$t"); RETENTION_PATTERNS+=("$r")
    else
      erro "$(leader "$label" 'BAD RETENTION')"
      cerr "$RET_WHY"
      PROBLEMS=$((PROBLEMS + 1))
    fi
  fi

  # ── the physical rule, over backup_base ──
  if [[ -z "$pr" ]]; then
    PHYS_NOT_CONFIGURED="${PHYS_NOT_CONFIGURED}${n} "
  else
    if [[ -z "$pb" ]]; then
      erro "$(leader "$label" 'NO BACKUP_BASE')"
      cerr "physical_retention '$pr' has no backup_base to apply to"
      PROBLEMS=$((PROBLEMS + 1))
    elif m="$(mount_for "$pb")"; then
      USED_MOUNTS="${USED_MOUNTS} ${m}"
    else
      erro "$(leader "$label" 'PATH OFF THE SHARE')"
      cerr "backup_base '$pb' is not under $SMB_MOUNT_POINT${EXTRA_MOUNTS:+ or $EXTRA_MOUNTS}"
      PROBLEMS=$((PROBLEMS + 1))
    fi

    if ! valid_pattern "$pr"; then
      erro "$(leader "$label" 'BAD PHYSICAL RETENTION')"
      cerr "$RET_WHY"
      PROBLEMS=$((PROBLEMS + 1))
    elif [[ -n "$pb" ]]; then
      PHYSICAL_SERVER_NAMES+=("$n"); PHYSICAL_TREES+=("$pb"); PHYSICAL_PATTERNS+=("$pr")
    fi
  fi
done

[[ $PROBLEMS -eq 0 ]] \
  || die "$(leader 'config parses' "$PROBLEMS PROBLEM(S)")" \
         "listed above; nothing has been deleted"

RET_COUNT=${#SERVER_NAMES[@]}
PHYS_COUNT=${#PHYSICAL_SERVER_NAMES[@]}
val "config parses" "$SERVER_COUNT entry/ies, $RET_COUNT logical, $PHYS_COUNT physical"
for i in $(seq 0 $((RET_COUNT - 1))); do
  cont "$(printf '%-28s %-10s logical' "${SERVER_NAMES[$i]}" "${RETENTION_PATTERNS[$i]}")"
done
for i in $(seq 0 $((PHYS_COUNT - 1))); do
  cont "$(printf '%-28s %-10s physical' "${PHYSICAL_SERVER_NAMES[$i]}" "${PHYSICAL_PATTERNS[$i]}")"
done
[[ -n "$NOT_CONFIGURED" ]] \
  && cont "no retention, dumps never expired: $NOT_CONFIGURED"
[[ -n "$PHYS_NOT_CONFIGURED" ]] \
  && cont "no physical_retention, sets never expired: $PHYS_NOT_CONFIGURED"

if [[ $RET_COUNT -eq 0 && $PHYS_COUNT -eq 0 ]]; then
  STEP="-"
  emit ""
  banner " DB CLEANUP NOT CONFIGURED"
  kv "config"  "$CONFIG_FILE"
  kv "entries" "$SERVER_COUNT, none with either rule"
  kv "effect"  "nothing deleted; every backup is kept and the share keeps growing"
  sub
  emit " to expire a server's dumps, give its entry a retention:"
  emit "   \"retention\": \"smart\"                ${SMART_DAILY_DAYS} daily + last ${SMART_WEEKDAY_KEEP} $(weekday_name "$SMART_WEEKDAY")s"
  emit "   \"retention\": \"days:15\"              the last 15 days"
  emit " to expire its physical backups, set by whole set:"
  emit "   \"physical_retention\": \"days:7\"      the last 7 days of sets"
  sub
  banner " RESULT ok servers=${SERVER_COUNT} deleted=0 kept=0 sets=0 orphans=0 errors=0 freed=0 dur_s=$(( $(date +%s) - START_EPOCH )) warn=${WARN_COUNT}"
  publish_logs
  trap - ERR INT TERM
  exit 0
fi

check
for m in $(printf '%s\n' $SMB_MOUNT_POINT $USED_MOUNTS | sort -u); do
  mountpoint -q "$m" \
    || die "$(leader 'smb shares' 'NOT MOUNTED')" \
           "expected a mount at $m" \
           "an unmounted share reads as an empty tree: nothing would be deleted" \
           "and the run would report success, hiding that retention has stopped"
done
val "smb shares" "$(printf '%s ' $(printf '%s\n' $SMB_MOUNT_POINT $USED_MOUNTS | sort -u))mounted"

check
[[ "$SMART_DAILY_DAYS" =~ ^[1-9][0-9]*$ && "$SMART_WEEKDAY_KEEP" =~ ^[1-9][0-9]*$ ]] \
  || die "$(leader 'smart settings' 'INVALID')" \
         "SMART_DAILY_DAYS=$SMART_DAILY_DAYS SMART_WEEKDAY_KEEP=$SMART_WEEKDAY_KEEP" \
         "both must be positive integers"
[[ "$SMART_WEEKDAY" =~ ^[1-7]$ ]] \
  || die "$(leader 'smart settings' 'INVALID WEEKDAY')" \
         "SMART_WEEKDAY=$SMART_WEEKDAY — expected 1..7, as date's %u numbers them" \
         "1=Monday through 7=Sunday"
val "smart settings" \
    "${SMART_DAILY_DAYS} daily + the last ${SMART_WEEKDAY_KEEP} $(weekday_name "$SMART_WEEKDAY")s"

check
writable "$LOCAL_STAGE" \
  || die "$(leader 'local stage writable' 'NO')" "not writable: $LOCAL_STAGE"
ok "local stage writable"

check
if [[ $RET_COUNT -eq 0 ]]; then
  skp "dump trees" "NONE CONFIGURED"
else
  PRESENT=0
  for i in $(seq 0 $((${#DUMP_TREES[@]} - 1))); do
    [[ -d "${DUMP_TREES[$i]}" ]] || continue
    writable "${DUMP_TREES[$i]}" \
      || die "$(leader 'dump trees' 'NOT WRITABLE')" \
             "${DUMP_TREES[$i]} — every deletion would fail"
    PRESENT=$((PRESENT + 1))
  done
  [[ $PRESENT -gt 0 ]] \
    || die "$(leader 'dump trees' 'NONE')" \
           "not one base_dir with a retention rule exists under $SMB_MOUNT_POINT" \
           "either the share is mounted from the wrong account, or every" \
           "base_dir is wrong — deleting nothing quietly is not an acceptable" \
           "outcome for a retention job"
  val "dump trees" "$PRESENT/$RET_COUNT present and writable"
fi

check
if [[ $PHYS_COUNT -eq 0 ]]; then
  skp "physical trees" "NONE CONFIGURED"
else
  PHYS_PRESENT=0
  for i in $(seq 0 $((PHYS_COUNT - 1))); do
    [[ -d "${PHYSICAL_TREES[$i]}" ]] || continue
    writable "${PHYSICAL_TREES[$i]}" \
      || die "$(leader 'physical trees' 'NOT WRITABLE')" \
             "${PHYSICAL_TREES[$i]} — every deletion would fail"
    PHYS_PRESENT=$((PHYS_PRESENT + 1))
  done
  [[ $PHYS_PRESENT -gt 0 ]] \
    || die "$(leader 'physical trees' 'NONE')" \
           "not one backup_base with a physical_retention rule exists under" \
           "$SMB_MOUNT_POINT — check each against SECONDARY_STORAGE_DIR in the" \
           "backup.sh of the host that writes it; deleting nothing quietly is" \
           "not an acceptable outcome for a retention job"
  val "physical trees" "$PHYS_PRESENT/$PHYS_COUNT present and writable"
fi

STEP="-"
info "$CHECK_N checks passed, ${WARN_COUNT} warning(s)   ($(elapsed "$PREFLIGHT_EPOCH"))"
sub

# ═══════════════════════════════════════════════════════════════════════════
# PART 9  LOGICAL RETENTION  1/3
# ═══════════════════════════════════════════════════════════════════════════

phase retention 1/3

apply_days() {
  local dir="$1" days="$2" keep="$3"
  local now total=0 removed=0 kept=0 entry mtime age f
  now="$(date +%s)"

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    mtime="${entry%%.*}"                             # %T@ is epoch.fraction
    f="${entry#* }"
    total=$((total + 1))
    age=$(( (now - mtime) / 86400 ))

    if (( age > days )); then
      if [[ "$ALWAYS_KEEP_NEWEST" == "1" && "$f" == "$keep" ]]; then
        cont "keeping $(basename "$f")  [newest, older than ${days}d]"
        kept=$((kept + 1))
        continue
      fi
      delete_file "$f" "older than ${days}d"
      removed=$((removed + 1))
    else
      [[ "$LOG_KEPT" == "1" ]] && cont "keeping $(basename "$f")  [${age}d old, within ${days}d]"
      kept=$((kept + 1))
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name "$ARCHIVE_GLOB" \
             -printf '%T@ %p\n' 2>/dev/null | sort -rn || true)

  KEPT=$(( KEPT + kept ))
  val "$CURRENT" "total ${total}, removing ${removed}, keeping ${kept}"
}

apply_smart() {
  local dir="$1" keep="$2"
  local now cutoff f mtime dow label entry days_kept=0
  now="$(date +%s)"
  cutoff=$(( now - SMART_DAILY_DAYS * 86400 ))

  local -a sorted=()
  mapfile -t sorted < <(find "$dir" -maxdepth 1 -type f -name "$ARCHIVE_GLOB" \
                          -printf '%T@ %p\n' 2>/dev/null | sort -rn || true)

  if [[ ${#sorted[@]} -eq 0 ]]; then
    skp "$CURRENT" "no archives"
    return 0
  fi

  local -A keep_reason=()
  local -A day_taken=()
  local days_kept=0

  for entry in "${sorted[@]}"; do
    mtime="${entry%%.*}"                             # %T@ is epoch.fraction
    f="${entry#* }"

    if (( mtime >= cutoff )); then
      keep_reason["$f"]="within ${SMART_DAILY_DAYS}d"
      continue
    fi
    [[ $days_kept -lt $SMART_WEEKDAY_KEEP ]] || continue
    dow="$(date -d "@$mtime" +%u 2>/dev/null || echo 0)"
    [[ "$dow" == "$SMART_WEEKDAY" ]] || continue
    label="$(date -d "@$mtime" +%F 2>/dev/null || echo "")"
    if [[ -n "$label" && -z "${day_taken[$label]:-}" ]]; then
      keep_reason["$f"]="$(weekday_name "$SMART_WEEKDAY") $label"
      day_taken["$label"]=1
      days_kept=$((days_kept + 1))
    fi
  done

  local kept=0 removed=0
  for entry in "${sorted[@]}"; do
    f="${entry#* }"
    if [[ -n "${keep_reason[$f]:-}" ]]; then
      [[ "$LOG_KEPT" == "1" ]] && cont "keeping $(basename "$f")  [${keep_reason[$f]}]"
      kept=$((kept + 1))
      continue
    fi
    if [[ "$ALWAYS_KEEP_NEWEST" == "1" && "$f" == "$keep" ]]; then
      cont "keeping $(basename "$f")  [newest, would otherwise expire]"
      kept=$((kept + 1))
      continue
    fi
    delete_file "$f" "smart — expired"
    removed=$((removed + 1))
  done

  KEPT=$(( KEPT + kept ))
  val "$CURRENT" "total ${#sorted[@]}, removing ${removed}, keeping ${kept}"
}

for i in $(seq 0 $((RET_COUNT - 1))); do
  server="${SERVER_NAMES[$i]}"
  tree="${DUMP_TREES[$i]}"
  pattern="${RETENTION_PATTERNS[$i]}"

  sub
  info "$server  ($pattern)"

  if [[ ! -d "$tree" ]]; then
    nok "$server" "NO DUMP TREE"
    cont "expected $tree"
    continue
  fi

  server_dbs=0
  while IFS= read -r db_dir; do
    [[ -n "$db_dir" ]] || continue
    db="$(basename "$db_dir")"
    is_non_db "$db" && continue

    CURRENT="${server}/${db}"
    server_dbs=$((server_dbs + 1))
    DB_DIRS=$((DB_DIRS + 1))
    newest="$(newest_archive "$db_dir")"

    case "$pattern" in
      smart)  apply_smart "$db_dir" "$newest" ;;
      days:*) apply_days  "$db_dir" "${pattern#days:}" "$newest" ;;
    esac
  done < <(find "$tree" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

  [[ $server_dbs -eq 0 ]] && nok "$server" "NO DATABASE DIRECTORIES"
done
CURRENT=""

sub
val "retention" "$DELETED deleted, $KEPT kept, $(hsize "$FREED_BYTES") freed"
[[ $DELETE_ERRORS -gt 0 ]] && nok "delete errors" "$DELETE_ERRORS"

# ═══════════════════════════════════════════════════════════════════════════
# PART 10  PHYSICAL RETENTION  2/3
# ═══════════════════════════════════════════════════════════════════════════

phase physical 2/3

apply_physical() {
  local tree="$1" pattern="$2" keep="$3"
  local now cutoff entry mtime id dow label kept=0 removed=0 days_kept=0
  local -a sorted=()
  mapfile -t sorted < <(find "$tree" -maxdepth 1 -type f -name "$PHYSICAL_GLOB" \
                          -printf '%T@ %f\n' 2>/dev/null | sort -rn || true)

  if [[ ${#sorted[@]} -eq 0 ]]; then
    skp "$CURRENT" "no sets"
    return 0
  fi

  now="$(date +%s)"
  local -A keep_reason=()
  local -A day_taken=()

  for entry in "${sorted[@]}"; do
    mtime="${entry%%.*}"                             # %T@ is epoch.fraction
    id="${entry#* }"; id="${id%.xbstream}"

    if [[ "$pattern" == days:* ]]; then
      cutoff=$(( now - ${pattern#days:} * 86400 ))
      (( mtime >= cutoff )) && keep_reason["$id"]="within ${pattern#days:}d"
      continue
    fi

    cutoff=$(( now - SMART_DAILY_DAYS * 86400 ))
    if (( mtime >= cutoff )); then
      keep_reason["$id"]="within ${SMART_DAILY_DAYS}d"
      continue
    fi
    [[ $days_kept -lt $SMART_WEEKDAY_KEEP ]] || continue
    dow="$(date -d "@$mtime" +%u 2>/dev/null || echo 0)"
    [[ "$dow" == "$SMART_WEEKDAY" ]] || continue
    label="$(date -d "@$mtime" +%F 2>/dev/null || echo "")"
    if [[ -n "$label" && -z "${day_taken[$label]:-}" ]]; then
      keep_reason["$id"]="$(weekday_name "$SMART_WEEKDAY") $label"
      day_taken["$label"]=1
      days_kept=$((days_kept + 1))
    fi
  done

  for entry in "${sorted[@]}"; do
    id="${entry#* }"; id="${id%.xbstream}"
    if [[ -n "${keep_reason[$id]:-}" ]]; then
      [[ "$LOG_KEPT" == "1" ]] && cont "keeping set $id  [${keep_reason[$id]}]"
      kept=$((kept + 1))
      continue
    fi
    if [[ "$ALWAYS_KEEP_NEWEST" == "1" && "$id" == "$keep" ]]; then
      cont "keeping set $id  [newest, would otherwise expire]"
      kept=$((kept + 1))
      continue
    fi
    delete_set "$tree" "$id" "$pattern — expired"
    removed=$((removed + 1))
  done

  PHYS_KEPT=$(( PHYS_KEPT + kept ))
  val "$CURRENT" "total ${#sorted[@]} set(s), removing ${removed}, keeping ${kept}"
}

if [[ $PHYS_COUNT -eq 0 ]]; then
  skp "physical retention" "NOT CONFIGURED"
else
  for i in $(seq 0 $((PHYS_COUNT - 1))); do
    server="${PHYSICAL_SERVER_NAMES[$i]}"
    tree="${PHYSICAL_TREES[$i]}"
    pattern="${PHYSICAL_PATTERNS[$i]}"

    sub
    info "$server  ($pattern, physical)"

    if [[ ! -d "$tree" ]]; then
      nok "$server" "NO PHYSICAL TREE"
      cont "expected $tree"
      continue
    fi

    CURRENT="${server} (physical)"
    apply_physical "$tree" "$pattern" "$(newest_set "$tree")"
    sweep_orphans "$tree" "$(guard_days "$pattern")"
  done
  CURRENT=""

  sub
  val "physical retention" \
      "$PHYS_DELETED set(s) deleted, $PHYS_KEPT kept, $PHYS_ORPHANS orphan(s) swept"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART 11  PRUNE LOGS  3/3
# ═══════════════════════════════════════════════════════════════════════════

phase prune 3/3

if [[ -d "$CLEANUP_LOG_BASE" ]]; then
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    if [[ $DRY_RUN -eq 1 ]]; then
      cont "would remove log directory $(basename "$d")"
    else
      rm -rf "$d" 2>>"$ERROR_LOG" || { nok "log prune" "FAILED on $d"; continue; }
    fi
    PRUNED_LOGS=$((PRUNED_LOGS + 1))
  done < <(find "$CLEANUP_LOG_BASE" -mindepth 1 -maxdepth 1 -type d \
             -mtime "+${KEEP_CLEANUP_LOG_DAYS}" 2>/dev/null | sort || true)
fi
val "log prune" "$PRUNED_LOGS directory/ies older than ${KEEP_CLEANUP_LOG_DAYS} days"

# ═══════════════════════════════════════════════════════════════════════════
# PART 12  SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

PHASE="done"; STEP="-"

emit ""
if [[ $DELETE_ERRORS -gt 0 ]]; then
  banner " DB CLEANUP INCOMPLETE"
elif [[ $DRY_RUN -eq 1 ]]; then
  banner " DB CLEANUP DRY RUN COMPLETE — NOTHING WAS DELETED"
else
  banner " DB CLEANUP OK"
fi
kv "duration"    "$(elapsed "$START_EPOCH")"
kv "config"      "$CONFIG_FILE"
kv "servers"     "$SERVER_COUNT in config, $RET_COUNT logical, $PHYS_COUNT physical"
kv "databases"   "$DB_DIRS directory/ies examined"
kv "deleted"     "$DELETED archive(s), $PHYS_DELETED physical set(s)"
kv "kept"        "$KEPT archive(s), $PHYS_KEPT physical set(s)"
kv "orphans"     "$PHYS_ORPHANS per-ID directory/ies swept"
kv "freed"       "$(hsize "$FREED_BYTES")"
kv "errors"      "$DELETE_ERRORS"
kv "logs pruned" "$PRUNED_LOGS"
kv "warnings"    "$WARN_COUNT"
sub
kv "logs" "$SECONDARY_LOG_DIR/"

if [[ $DELETE_ERRORS -gt 0 ]]; then
  banner " RESULT failed servers=${SERVER_COUNT} deleted=${DELETED} kept=${KEPT} sets=${PHYS_DELETED} orphans=${PHYS_ORPHANS} errors=${DELETE_ERRORS} freed=${FREED_BYTES} dur_s=$(( $(date +%s) - START_EPOCH )) warn=${WARN_COUNT}"
  publish_logs
  trap - ERR INT TERM
  exit 1
fi

banner " RESULT ok servers=${SERVER_COUNT} deleted=${DELETED} kept=${KEPT} sets=${PHYS_DELETED} orphans=${PHYS_ORPHANS} errors=0 freed=${FREED_BYTES} dur_s=$(( $(date +%s) - START_EPOCH )) warn=${WARN_COUNT}"

publish_logs

trap - ERR INT TERM
exit 0
