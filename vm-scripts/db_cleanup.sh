#!/bin/bash
#
# db_cleanup.sh
# Config-driven backup retention for multiple servers/folders.
#
# Retention Patterns:
#   "smart"   – Keep last 7 daily + 3 oldest-per-week beyond that ≈ 10 backups
#   "days:N"  – Keep last N days of backups, delete everything older
#
# Usage:
#   ./db_cleanup.sh           # perform deletions
#   ./db_cleanup.sh --dry-run # preview only, delete nothing
#
set -euo pipefail

# =============================================================================
# REGION 1 – CONFIGURATION
# =============================================================================

BASE_PATH="/livestorage/DBBackup"
LOG_DIR="$BASE_PATH/_cleanup_logs"          # central log location
LOCKFILE="/var/run/db_cleanup.lock"

# Each entry:  "FolderName:pattern"
#   pattern = "smart"   → 7 daily + 3 weekly  (≈10 kept)
#   pattern = "days:N"  → keep N calendar days
SERVERS=(
  "Auth-DB:days:15"
  "Cloud-Live-DB-Default:smart"
)

# How many days to keep THIS script's own cleanup logs
KEEP_CLEANUP_LOG_DAYS=60

# Backup file glob (adjust if your naming differs)
BACKUP_GLOB="*.tar.gz"

# =============================================================================
# REGION 2 – RUNTIME SETUP
# =============================================================================

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/cleanup_$(date +'%Y%m%d_%H%M%S').log"

TOTAL_DELETED=0
TOTAL_FREED_BYTES=0

# =============================================================================
# REGION 3 – LOGGING  (concise: only deletions + summary)
# =============================================================================

_log() {
  local level="$1"; shift
  printf '%s [%-5s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$LOG_FILE"
}
log_info()  { _log "INFO"  "$@"; }
log_warn()  { _log "WARN"  "$@"; }
log_error() { _log "ERROR" "$@"; }

# Also print to stdout for interactive runs
console() {
  local msg="$*"
  printf '%s\n' "$msg"
  log_info "$msg"
}

# =============================================================================
# REGION 4 – HELPERS
# =============================================================================

human_size() {
  local bytes=$1
  if   (( bytes >= 1073741824 )); then printf "%.2f GB" "$(echo "scale=2; $bytes/1073741824" | bc)"
  elif (( bytes >= 1048576 ));    then printf "%.2f MB" "$(echo "scale=2; $bytes/1048576" | bc)"
  elif (( bytes >= 1024 ));       then printf "%.2f KB" "$(echo "scale=2; $bytes/1024" | bc)"
  else printf "%d B" "$bytes"
  fi
}

# Delete a single file; log its name and size. Updates counters.
delete_file() {
  local file="$1" desc="$2"
  local size db_name fname
  size=$(stat -c%s "$file" 2>/dev/null || echo 0)
  db_name=$(basename "$(dirname "$file")")
  fname=$(basename "$file")

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "[DRY-RUN] would delete: ${db_name}/${fname}  ($(human_size "$size"))  [$desc]"
  else
    if rm -f "$file"; then
      log_info "DELETED: ${db_name}/${fname}  ($(human_size "$size"))  [$desc]"
      TOTAL_DELETED=$((TOTAL_DELETED + 1))
      TOTAL_FREED_BYTES=$((TOTAL_FREED_BYTES + size))
    else
      log_error "FAILED to delete: ${db_name}/${fname}"
    fi
  fi

  # Also remove .sha256 sidecar if it exists
  if [[ -f "${file}.sha256" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log_info "[DRY-RUN] would delete sidecar: ${db_name}/${fname}.sha256"
    else
      rm -f "${file}.sha256" && log_info "DELETED sidecar: ${db_name}/${fname}.sha256"
    fi
  fi
}

# =============================================================================
# REGION 5 – RETENTION STRATEGIES
# =============================================================================

# ---------- Pattern: days:N ------------------------------------------------
# Simple: delete every .tar.gz older than N days.
#
apply_days_retention() {
  local folder="$1" days="$2"
  local count=0 total
  total=$(find "$folder" -maxdepth 1 -type f -name "$BACKUP_GLOB" 2>/dev/null | wc -l)

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    delete_file "$f" "older than ${days}d"
    count=$((count + 1))
  done < <(find "$folder" -maxdepth 1 -type f -name "$BACKUP_GLOB" -mtime +"$days" 2>/dev/null | sort)

  console "    Total: ${total} | Removing: ${count} | Keeping: $((total - count))"
}

# ---------- Pattern: smart -------------------------------------------------
# Keep last 7 days fully + 3 weekly backups beyond that.
#
# Logic:
#   1. Collect all .tar.gz sorted newest-first.
#   2. Anything ≤ 7 days old → KEEP.
#   3. Among files > 7 days old, group by ISO week (YYYY-WW).
#      Keep the NEWEST file per week, for up to 3 weeks.
#   4. Everything else → DELETE.
#
apply_smart_retention() {
  local folder="$1"
  local now cutoff_epoch
  now=$(date +%s)
  cutoff_epoch=$((now - 7 * 86400))

  # Gather all backups: "epoch|filename"
  local -a all_files=()
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    local mtime
    mtime=$(stat -c%Y "$f" 2>/dev/null || echo 0)
    all_files+=("$mtime|$f")
  done < <(find "$folder" -maxdepth 1 -type f -name "$BACKUP_GLOB" 2>/dev/null)

  if [[ ${#all_files[@]} -eq 0 ]]; then
    console "    No backups found."
    return
  fi

  # Sort newest first
  IFS=$'\n' sorted=($(printf '%s\n' "${all_files[@]}" | sort -t'|' -k1,1 -rn)); unset IFS

  local -A keep_map=()          # file → reason
  local -A weekly_kept=()       # "YYYY-WW" → 1
  local weekly_count=0

  for entry in "${sorted[@]}"; do
    local mtime="${entry%%|*}"
    local file="${entry#*|}"

    if (( mtime >= cutoff_epoch )); then
      keep_map["$file"]="within 7 days"
    else
      # Older than 7 days – check weekly slot
      local week_label
      week_label=$(date -d "@$mtime" +'%G-W%V' 2>/dev/null || date -d "@$mtime" +'%Y-W%U')

      if [[ -z "${weekly_kept[$week_label]:-}" ]] && (( weekly_count < 3 )); then
        keep_map["$file"]="weekly keeper ($week_label)"
        weekly_kept["$week_label"]=1
        weekly_count=$((weekly_count + 1))
      fi
      # else: not kept → will be deleted below
    fi
  done

  # Pass 2: delete anything not in keep_map
  local del_count=0 keep_count=0
  for entry in "${sorted[@]}"; do
    local file="${entry#*|}"
    if [[ -n "${keep_map[$file]:-}" ]]; then
      keep_count=$((keep_count + 1))
    else
      delete_file "$file" "smart retention – expired"
      del_count=$((del_count + 1))
    fi
  done

  console "    Total: ${#sorted[@]} | Removing: ${del_count} | Keeping: ${keep_count}"
}

# =============================================================================
# REGION 6 – CLEANUP OLD LOGS
# =============================================================================

cleanup_old_logs() {
  local count=0

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    delete_file "$f" "old cleanup log"
    count=$((count + 1))
  done < <(find "$LOG_DIR" -maxdepth 1 -type f -name "cleanup_*.log" -mtime +"$KEEP_CLEANUP_LOG_DAYS" 2>/dev/null | sort)

  (( count > 0 )) && console "  Old cleanup logs removed: ${count}"
}

# =============================================================================
# REGION 7 – MAIN
# =============================================================================

# Acquire lock
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  console "Another cleanup instance is already running. Exiting."
  exit 0
fi

[[ "$DRY_RUN" -eq 1 ]] && MODE_LABEL="DRY-RUN" || MODE_LABEL="LIVE"

console "========================================"
console "  Backup Cleanup – $MODE_LABEL"
console "  $(date +'%Y-%m-%d %H:%M:%S')"
console "  Base: $BASE_PATH"
console "========================================"

for entry in "${SERVERS[@]}"; do
  IFS=':' read -r folder pattern param <<< "$entry"
  server_path="$BASE_PATH/$folder"

  console ""
  console "═══════════════════════════════════"
  console "  Server: $folder"
  console "  Pattern: $( [[ "$pattern" == "smart" ]] && echo "smart (7 daily + 3 weekly)" || echo "days:${param:-?}" )"
  console "═══════════════════════════════════"

  if [[ ! -d "$server_path" ]]; then
    log_warn "Directory not found: $server_path – skipping."
    console "  SKIPPED (directory not found)"
    continue
  fi

  # Validate days pattern upfront
  if [[ "$pattern" == "days" ]]; then
    if [[ -z "${param:-}" ]] || ! [[ "$param" =~ ^[0-9]+$ ]]; then
      log_error "Invalid days value for $folder: '${param:-}'"
      console "  SKIPPED (invalid days config)"
      continue
    fi
  fi

  # Iterate each database subfolder within this server
  local_db_count=0
  while IFS= read -r db_dir; do
    [[ -z "$db_dir" ]] && continue
    db_name=$(basename "$db_dir")
    local_db_count=$((local_db_count + 1))

    console ""
    console "  ── $folder/$db_name ──"

    case "$pattern" in
      smart)
        apply_smart_retention "$db_dir"
        ;;
      days)
        apply_days_retention "$db_dir" "$param"
        ;;
      *)
        log_error "Unknown pattern '$pattern' for $folder/$db_name"
        console "    SKIPPED (unknown pattern)"
        ;;
    esac
  done < <(find "$server_path" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

  if (( local_db_count == 0 )); then
    console "  No database folders found in $server_path"
  else
    console ""
    console "  Processed $local_db_count database(s) under $folder"
  fi
done

# Cleanup this script's own old logs
console ""
console "── Cleanup Logs ──"
cleanup_old_logs

# Final summary
console ""
console "========================================"
if [[ "$DRY_RUN" -eq 1 ]]; then
  console "  DRY-RUN complete. No files were deleted."
else
  console "  Done. Deleted: $TOTAL_DELETED file(s), Freed: $(human_size $TOTAL_FREED_BYTES)"
fi
console "  Log: $LOG_FILE"
console "========================================"
