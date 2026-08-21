#!/usr/bin/env bash
set -euo pipefail

############################
# CONFIGURATION
############################

RESTORE_SCRIPT="/Data/script/restore.sh"
DB_BACKUP_SCRIPT="/Data/script/db_backup_1606.sh"
BACKUP_SYNC_SCRIPT="/Data/script/backup_sync.sh"
LOG_DIR="/Data/script/final.log"
LOCK_FILE="/var/run/db_orchestrator.lock"

CONFIG_FILE=""
SKIP_SHUTDOWN=false

############################
# ARGUMENT PARSING
############################

show_usage() {
  echo "Usage: $0 --config=PATH [--no-shutdown]"
  echo ""
  echo "  --config=PATH   :  JSON file listing servers to process, in order"
  echo "  --no-shutdown   :  Skip the shutdown after the sequence completes"
  exit 1
}

for arg in "$@"; do
  case "$arg" in
    --config=*)     CONFIG_FILE="${arg#*=}" ;;
    --no-shutdown)  SKIP_SHUTDOWN=true ;;
    -h|--help)      show_usage ;;
    *)
      echo "Unknown argument: $arg" >&2
      show_usage
      ;;
  esac
done

[[ -n "$CONFIG_FILE" ]] || show_usage
[[ -f "$CONFIG_FILE" ]] || { echo "Config file not found: $CONFIG_FILE" >&2; exit 1; }
[[ -x "$RESTORE_SCRIPT" ]] || { echo "restore script not found or not executable: $RESTORE_SCRIPT" >&2; exit 1; }
[[ -x "$DB_BACKUP_SCRIPT" ]] || { echo "db backup script not found or not executable: $DB_BACKUP_SCRIPT" >&2; exit 1; }
[[ -x "$BACKUP_SYNC_SCRIPT" ]] || { echo "backup sync script not found or not executable: $BACKUP_SYNC_SCRIPT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required but not installed" >&2; exit 1; }

############################
# LOGGING
############################

mkdir -p "$LOG_DIR"
RUN_LOG="$LOG_DIR/orchestrator_$(date +'%Y%m%d_%H%M%S').log"

log_msg()   { echo "[$(date '+%F %T')] [INFO]  $1" | tee -a "$RUN_LOG"; }
log_error() { echo "[$(date '+%F %T')] [ERROR] $1" | tee -a "$RUN_LOG"; }

############################
# SINGLE-INSTANCE LOCK
############################

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another orchestrator run is already in progress, exiting." >&2
  exit 1
fi

############################
# VALIDATE CONFIG
############################

if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
  log_error "Invalid JSON in config file: $CONFIG_FILE"
  exit 1
fi

SERVER_COUNT=$(jq 'length' "$CONFIG_FILE")
if [[ "$SERVER_COUNT" -eq 0 ]]; then
  log_error "Config file has no entries: $CONFIG_FILE"
  exit 1
fi

log_msg "===================================================="
log_msg "ORCHESTRATION RUN START ($SERVER_COUNT server(s) from $CONFIG_FILE)"
log_msg "===================================================="

############################
# MAIN SEQUENCE
############################

SUCCESS_SERVERS=()
FAILED_SERVERS=()

for i in $(seq 0 $((SERVER_COUNT - 1))); do
  SERVER_NAME=$(jq -r ".[$i].server_name" "$CONFIG_FILE")
  BACKUP_BASE=$(jq -r ".[$i].backup_base" "$CONFIG_FILE")
  BASE_DIR=$(jq -r ".[$i].base_dir" "$CONFIG_FILE")

  if [[ -z "$SERVER_NAME" || "$SERVER_NAME" == "null" ]] || \
     [[ -z "$BACKUP_BASE" || "$BACKUP_BASE" == "null" ]] || \
     [[ -z "$BASE_DIR" || "$BASE_DIR" == "null" ]]; then
    log_error "Entry $((i + 1))/$SERVER_COUNT is missing server_name, backup_base, or base_dir - skipping."
    FAILED_SERVERS+=("entry-$((i + 1)) (bad config)")
    continue
  fi

  log_msg "----------------------------------------------------"
  log_msg "[$((i + 1))/$SERVER_COUNT] Starting: $SERVER_NAME"
  log_msg "----------------------------------------------------"

  if bash "$RESTORE_SCRIPT" --server_name="$SERVER_NAME" --backup_base="$BACKUP_BASE" 2>&1 | tee -a "$RUN_LOG"; then
    log_msg "[$SERVER_NAME] Restore succeeded."

    if bash "$DB_BACKUP_SCRIPT" --server_name="$SERVER_NAME" --base_dir="$BASE_DIR" 2>&1 | tee -a "$RUN_LOG"; then
      log_msg "[$SERVER_NAME] Dump succeeded."
      SUCCESS_SERVERS+=("$SERVER_NAME")
    else
      log_error "[$SERVER_NAME] Dump FAILED."
      FAILED_SERVERS+=("$SERVER_NAME (dump)")
    fi
  else
    log_error "[$SERVER_NAME] Restore FAILED, skipping dump for this server."
    FAILED_SERVERS+=("$SERVER_NAME (restore)")
  fi
done

############################
# SUMMARY
############################

log_msg "===================================================="
log_msg "SEQUENCE COMPLETE"
log_msg "Succeeded: ${#SUCCESS_SERVERS[@]}/$SERVER_COUNT (${SUCCESS_SERVERS[*]:-none})"
log_msg "Failed:    ${#FAILED_SERVERS[@]}/$SERVER_COUNT (${FAILED_SERVERS[*]:-none})"
log_msg "===================================================="

############################
# BACKUP SYNC
############################

log_msg "Running backup_sync.sh..."
if bash "$BACKUP_SYNC_SCRIPT" 2>&1 | tee -a "$RUN_LOG"; then
  log_msg "backup_sync.sh completed successfully."
else
  log_error "backup_sync.sh FAILED."
fi

############################
# SHUTDOWN
############################

if [[ "$SKIP_SHUTDOWN" == true ]]; then
  log_msg "Shutdown skipped (--no-shutdown)."
else
  log_msg "Shutting down in 10 minutes..."
  shutdown -h +10 "Good Night"
fi
