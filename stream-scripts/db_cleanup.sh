#!/usr/bin/env bash
#
# stream-scripts/db_cleanup.sh — retention for the backups on the share
#
# Two trees, two independent opt-in rules, the same two patterns:
#   base_dir     + retention            the logical dumps, expired file by file
#   backup_base  + physical_retention   the physical backups, expired set by set
#
#   smart    keep everything from the last SMART_DAILY_DAYS days, plus the
#            newest of each of the SMART_WEEKLY_KEEP most recent weeks
#   days:N   keep the last N days, delete everything older
# The newest archive of a database, and the newest physical set of a server,
# are never deleted under either pattern.
#
# A physical backup is not one file. backup.sh and binlog_collect.sh publish
# seven parts per backup ID, and they only mean anything together:
#   <ID>.xbstream   <ID>.sha256   <ID>.manifest   <ID>_binlog_info
#   binlog/<ID>/    meta/<ID>/    logs/<ID>/
# So the physical pass expires an ID, not a file. Deleting the archive alone
# would strand binlog/<ID>, which keeps growing until the next full backup and
# is unreplayable without the anchor it belongs to.
#
# Servers, their trees and their patterns come from the same JSON file final.sh
# uses. Docs: stream-scripts/README-dr.md
#
#   PART 1   configuration
#   PART 2   log engine
#   PART 3   failure handling
#   PART 4   probes
#   PART 5   usage and arguments
#   PART 6   single-instance lock
#   PART 7   identity and paths
#   PART 8   pre-flight            8 checks
#   PART 9   logical retention     step 1/3
#   PART 10  physical retention    step 2/3
#   PART 11  prune logs            step 3/3
#   PART 12  summary
#
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# PART 1  CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

# The server list. Per entry this script reads:
#   base_dir             the dump tree to expire — where logical.sh published
#   retention            "smart" or "days:N", applied to base_dir
#   backup_base          the physical tree — where backup.sh published
#   physical_retention   "smart" or "days:N", applied to backup_base
#
# Both rules are OPT-IN and independent: an entry without retention keeps every
# dump, an entry without physical_retention keeps every physical set, and a
# config with neither anywhere means there is nothing for this script to do.
# There is deliberately no default — a script whose only job is rm must delete
# exactly what it was told to and nothing by assumption.
CONFIG_FILE="/Data/script/servers.json"

SMB_MOUNT_POINT="/livestorage"

ARCHIVE_GLOB="*.tar.gz"

# The physical side. The archive glob finds the set; every other part is derived
# from the backup ID that the archive's own name carries.
PHYSICAL_GLOB="*.xbstream"
PHYS_SET_SUFFIXES=".xbstream .sha256 .manifest _binlog_info"
PHYS_SET_DIRS="binlog meta logs"

# smart: full daily coverage for this many days, then one archive per week.
SMART_DAILY_DAYS=7
SMART_WEEKLY_KEEP=3

# Never delete the last remaining archive of a database, or the last remaining
# physical set of a server, however old either is. A server that stopped
# producing backups is exactly when the old one matters — and on the physical
# side it is the only restore path there is.
ALWAYS_KEEP_NEWEST=1

# This script's own logs, published here as one directory per run.
CLEANUP_LOG_BASE="/livestorage/final/_cleanup_logs"
KEEP_CLEANUP_LOG_DAYS=60

LOCAL_STAGE="/Data/dbvault-stage"                    # logs only, during the run
KEEP_LOCAL_DAYS=14                                   # prune logs stranded here

# Directories inside a server's dump tree that are not databases.
NON_DB_DIRS="logs manifests _cleanup_logs"

LOCK_DIR="/var/lock/dbvault"

DRY_RUN=0

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

# Safety net only. A successful run leaves nothing in LOCAL_STAGE: the log is
# published to the share and the local copy dropped. This clears only what an
# earlier run kept BECAUSE the share was unreachable.
# Never touches this run's files: -mtime is in whole days.
prune_local() {
  local f n=0
  while IFS= read -r f; do
    rm -f "$f" 2>/dev/null && n=$((n + 1))
  done < <(find "$LOCAL_STAGE" -maxdepth 1 -type f -name 'db_cleanup_*.log' \
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

  # Deletions already made are permanent, which is the whole reason this is
  # reported rather than swallowed: whatever aborted the run did so with the
  # retention pass part-applied.
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
# The .sha256 sidecar goes with the archive: an orphan checksum is a file that
# looks like a backup record and refers to nothing.
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

# Shared by both fields, so "smart" and "days:N" cannot drift apart between the
# logical rule and the physical one. The reason is left in RET_WHY for the
# caller to report against whichever field name it was validating.
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

# Every byte the set occupies — archive, sidecars, per-ID directories — so the
# freed total reports the space the share actually gets back.
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

# delete_set <tree> <id> <reason>
# Order matters. The .xbstream goes first: restore_vm.sh discovers backups by
# globbing *.xbstream, so removing it makes the set invisible to the resolver
# immediately — no restore can select a set that is half gone — and it frees the
# bulk of the space up front. An interrupted delete then leaves only small
# metadata behind, which sweep_orphans collects on the next run.
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

# The orphan sweep's age floor, in days. Anything younger is left alone:
# logs/<ID> with no <ID>.xbstream is exactly the evidence of a backup that
# failed last night, and it has to survive long enough for someone to read it.
guard_days() {
  case "$1" in
    smart)  printf '%s' $(( SMART_DAILY_DAYS + SMART_WEEKLY_KEEP * 7 )) ;;
    days:*) printf '%s' "${1#days:}" ;;
  esac
  return 0
}

# A per-ID directory whose .xbstream is gone: the tail of an interrupted delete,
# or a backup that died before it published an archive. Without this the largest
# of them, binlog/<ID>, would sit there unreferenced and unreplayable forever.
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
  base_dir            required  the dump tree to expire
  retention           opt-in    "smart" or "days:N", over base_dir
  backup_base         required alongside physical_retention: the physical tree
  physical_retention  opt-in    "smart" or "days:N", over backup_base

  smart   everything from the last $SMART_DAILY_DAYS days, plus the newest of each of
          the $SMART_WEEKLY_KEEP most recent weeks beyond that
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

# Every entry — path and pattern — is validated here, before anything is
# deleted. A typo in entry four must not be discovered after entries one to
# three have been pruned.
check
jq empty "$CONFIG_FILE" >/dev/null 2>&1 \
  || die "$(leader 'config parses' 'INVALID JSON')" "$CONFIG_FILE"
[[ "$(jqv 'type')" == "array" ]] \
  || die "$(leader 'config parses' 'NOT AN ARRAY')" "expected an array of server objects"
SERVER_COUNT="$(jqv 'length')"
[[ "$SERVER_COUNT" =~ ^[0-9]+$ && "$SERVER_COUNT" -gt 0 ]] \
  || die "$(leader 'config parses' 'EMPTY')" "no entries in $CONFIG_FILE"

PROBLEMS=0
for i in $(seq 0 $((SERVER_COUNT - 1))); do
  n="$(jqv ".[$i].server_name // empty")"
  t="$(jqv ".[$i].base_dir // empty")"
  r="$(jqv ".[$i].retention // empty")"
  pb="$(jqv ".[$i].backup_base // empty")"
  pr="$(jqv ".[$i].physical_retention // empty")"
  label="entry $((i + 1))/$SERVER_COUNT"
  t="${t%/}"
  pb="${pb%/}"

  if [[ -z "$n" || -z "$t" ]]; then
    erro "$(leader "$label" 'INCOMPLETE')"
    cerr "server_name='$n' base_dir='$t' — both are required"
    PROBLEMS=$((PROBLEMS + 1))
    continue
  fi

  # ── the logical rule, over base_dir ──
  # Opt-in: no retention, no expiry. Counted and named, so a server that was
  # meant to be pruned and lost its key shows up here rather than quietly
  # accumulating archives forever.
  if [[ -z "$r" ]]; then
    NOT_CONFIGURED="${NOT_CONFIGURED}${n} "
  else
    # This script's only job is rm. Outside the mount, base_dir is an ordinary
    # local directory, and an unmounted share looks like an empty one — which
    # would find nothing, delete nothing, and report a clean run while retention
    # had silently stopped happening.
    if [[ "$t" != "$SMB_MOUNT_POINT"/* ]]; then
      erro "$(leader "$label" 'PATH OFF THE SHARE')"
      cerr "base_dir '$t' is not under $SMB_MOUNT_POINT"
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
  # Independent of the logical one: a server can expire its dumps and keep every
  # physical backup, or the reverse.
  if [[ -z "$pr" ]]; then
    PHYS_NOT_CONFIGURED="${PHYS_NOT_CONFIGURED}${n} "
  else
    if [[ -z "$pb" ]]; then
      erro "$(leader "$label" 'NO BACKUP_BASE')"
      cerr "physical_retention '$pr' has no backup_base to apply to"
      PROBLEMS=$((PROBLEMS + 1))
    elif [[ "$pb" != "$SMB_MOUNT_POINT"/* ]]; then
      erro "$(leader "$label" 'PATH OFF THE SHARE')"
      cerr "backup_base '$pb' is not under $SMB_MOUNT_POINT"
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

# Not an error: a config with neither rule anywhere is a deliberate statement
# that every backup is kept. Exit 0 so the pipeline records a skipped step
# rather than a failed one.
if [[ $RET_COUNT -eq 0 && $PHYS_COUNT -eq 0 ]]; then
  STEP="-"
  emit ""
  banner " DB CLEANUP NOT CONFIGURED"
  kv "config"  "$CONFIG_FILE"
  kv "entries" "$SERVER_COUNT, none with either rule"
  kv "effect"  "nothing deleted; every backup is kept and the share keeps growing"
  sub
  emit " to expire a server's dumps, give its entry a retention:"
  emit "   \"retention\": \"smart\"                7 daily + 3 weekly"
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
mountpoint -q "$SMB_MOUNT_POINT" \
  || die "$(leader 'smb share' 'NOT MOUNTED')" \
         "expected a mount at $SMB_MOUNT_POINT" \
         "an unmounted share reads as an empty tree: nothing would be deleted" \
         "and the run would report success, hiding that retention has stopped"
ok "smb share"

check
[[ "$SMART_DAILY_DAYS" =~ ^[1-9][0-9]*$ && "$SMART_WEEKLY_KEEP" =~ ^[1-9][0-9]*$ ]] \
  || die "$(leader 'smart settings' 'INVALID')" \
         "SMART_DAILY_DAYS=$SMART_DAILY_DAYS SMART_WEEKLY_KEEP=$SMART_WEEKLY_KEEP" \
         "both must be positive integers"
val "smart settings" "${SMART_DAILY_DAYS} daily + ${SMART_WEEKLY_KEEP} weekly"

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

# backup.sh hardcodes SECONDARY_STORAGE_DIR per production host and never reads
# this config, so backup_base here is a hand-kept mirror of that constant and
# the two can drift. A drifted path is a directory that does not exist, which
# would expire nothing and report success — the same silent failure the mount
# check exists to prevent, so it gets the same treatment.
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

# days:N — everything older than N days goes, except the newest.
apply_days() {
  local dir="$1" days="$2" keep="$3"
  local total=0 removed=0 f

  total="$(find "$dir" -maxdepth 1 -type f -name "$ARCHIVE_GLOB" 2>/dev/null | wc -l)"

  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ "$ALWAYS_KEEP_NEWEST" == "1" && "$f" == "$keep" ]]; then
      cont "keeping $(basename "$f")  [newest, older than ${days}d]"
      continue
    fi
    delete_file "$f" "older than ${days}d"
    removed=$((removed + 1))
  done < <(find "$dir" -maxdepth 1 -type f -name "$ARCHIVE_GLOB" \
             -mtime "+${days}" 2>/dev/null | sort || true)

  KEPT=$(( KEPT + total - removed ))
  val "$CURRENT" "total ${total}, removing ${removed}, keeping $(( total - removed ))"
}

# smart — full daily coverage for SMART_DAILY_DAYS, then one archive per ISO
# week for SMART_WEEKLY_KEEP weeks. Newest first, so the archive kept for a week
# is that week's most recent. ISO weeks (%G-W%V), so a run early on a Monday
# does not merge two calendar weeks into one slot.
apply_smart() {
  local dir="$1" keep="$2"
  local now cutoff f mtime label entry
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
  local -A week_taken=()
  local weekly=0

  for entry in "${sorted[@]}"; do
    mtime="${entry%%.*}"                             # %T@ is epoch.fraction
    f="${entry#* }"

    if (( mtime >= cutoff )); then
      keep_reason["$f"]="within ${SMART_DAILY_DAYS}d"
      continue
    fi
    label="$(date -d "@$mtime" +'%G-W%V' 2>/dev/null || date -d "@$mtime" +'%Y-W%U')"
    if [[ -z "${week_taken[$label]:-}" && $weekly -lt $SMART_WEEKLY_KEEP ]]; then
      keep_reason["$f"]="weekly keeper $label"
      week_taken["$label"]=1
      weekly=$((weekly + 1))
    fi
  done

  local kept=0 removed=0
  for entry in "${sorted[@]}"; do
    f="${entry#* }"
    if [[ -n "${keep_reason[$f]:-}" ]]; then
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

# Over the entries that HAVE a retention rule, not over the whole config: the
# arrays only hold the ones that opted in.
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
#
# Whole sets, not files, and after the logical pass on purpose: the dumps are
# the derived product. If a run is going to abort part-way, the copy that
# survives should be the one that cannot be rebuilt from the other.
# ═══════════════════════════════════════════════════════════════════════════

phase physical 2/3

# One backup ID is one unit. Selection mirrors the logical patterns, but over
# sets rather than files — and the newest set of a server is the one thing this
# pass will not delete: it is that server's only physical restore path.
apply_physical() {
  local tree="$1" pattern="$2" keep="$3"
  local now cutoff entry mtime id label kept=0 removed=0 weekly=0
  local -a sorted=()
  mapfile -t sorted < <(find "$tree" -maxdepth 1 -type f -name "$PHYSICAL_GLOB" \
                          -printf '%T@ %f\n' 2>/dev/null | sort -rn || true)

  if [[ ${#sorted[@]} -eq 0 ]]; then
    skp "$CURRENT" "no sets"
    return 0
  fi

  now="$(date +%s)"
  local -A keep_reason=()
  local -A week_taken=()

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
    label="$(date -d "@$mtime" +'%G-W%V' 2>/dev/null || date -d "@$mtime" +'%Y-W%U')"
    if [[ -z "${week_taken[$label]:-}" && $weekly -lt $SMART_WEEKLY_KEEP ]]; then
      keep_reason["$id"]="weekly keeper $label"
      week_taken["$label"]=1
      weekly=$((weekly + 1))
    fi
  done

  for entry in "${sorted[@]}"; do
    id="${entry#* }"; id="${id%.xbstream}"
    if [[ -n "${keep_reason[$id]:-}" ]]; then
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
#
# Last, so this run's own log directory — published after everything below —
# is never a candidate for its own pass.
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
