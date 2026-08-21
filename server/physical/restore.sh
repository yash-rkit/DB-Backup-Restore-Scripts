#!/usr/bin/env bash
#
# server/physical/restore.sh — wrapper: restore_full.sh then apply_binlog.sh
#
# Usage: ./restore.sh <backup_id>
# Docs:  instructions/server/physical/README.md
#
# Holds NO restore logic of its own by design. For anything non-routine, run the
# two phases by hand so you get a checkpoint between them.
#
set -euo pipefail

############################
# CONFIGURATION
############################

# Locks — LOCAL to this VM. MUST match LOCK_DIR in the scripts called below.
LOCK_DIR="/var/lock/dbvault"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

############################
# USAGE
############################

show_usage() {
  cat <<EOF
Usage: $0 <backup_id>

  Runs both recovery phases in order:
    Phase 1  restore_full.sh  — wipes the datadir and restores the full backup
    Phase 2  apply_binlog.sh  — replays collected binlogs on top

  Phase 1 PERMANENTLY ERASES the MySQL data directory. Take a VM snapshot
  first — if the current data is damaged, it is still evidence.

Arguments:
  backup_id   :  As published by backup.sh — 20260810 or 20260810_143005

Example:
  $0 20260810
EOF
  exit 1
}

if [[ $# -ne 1 ]]; then
  show_usage
fi

BACKUP_ID="$1"

# Rejected rather than forwarded: forwarding would run the DESTRUCTIVE Phase 1
# in full and only then preview Phase 2.
if [[ "$BACKUP_ID" == "--dry-run" || "$BACKUP_ID" == "-n" ]]; then
  echo "[$(date '+%F %T')] [ERROR] --dry-run is not supported by this wrapper." >&2
  echo "[$(date '+%F %T')] [ERROR] Phase 1 wipes the datadir, so there is nothing to preview" >&2
  echo "[$(date '+%F %T')] [ERROR] without first performing a real restore." >&2
  echo "" >&2
  echo "To preview binlogs, run the phases separately:" >&2
  echo "  ${SCRIPT_DIR}/restore_full.sh <backup_id>" >&2
  echo "  ${SCRIPT_DIR}/apply_binlog.sh <backup_id> --dry-run" >&2
  exit 1
fi

if ! [[ "$BACKUP_ID" =~ ^[0-9]{8}(_[0-9]{6})?$ ]]; then
  echo "[$(date '+%F %T')] [ERROR] Invalid backup ID: $BACKUP_ID" >&2
  echo "[$(date '+%F %T')] [ERROR] Expected YYYYMMDD or YYYYMMDD_HHMMSS" >&2
  exit 1
fi

############################
# PRE-FLIGHT
############################

if [[ $EUID -ne 0 ]]; then
  echo "[$(date '+%F %T')] [ERROR] This script must be run as root" >&2
  exit 1
fi

for s in restore_full.sh apply_binlog.sh; do
  if [[ ! -x "${SCRIPT_DIR}/${s}" ]]; then
    echo "[$(date '+%F %T')] [ERROR] Not found or not executable: ${SCRIPT_DIR}/${s}" >&2
    echo "[$(date '+%F %T')] [ERROR] Fix with: chmod +x ${SCRIPT_DIR}/${s}" >&2
    exit 1
  fi
done

############################
# WRAPPER LOCK
# A DIFFERENT file from the restore.lock the two children take — using the same
# one would deadlock, since each child opens its own file description and would
# block on the lock this wrapper already holds.
############################

mkdir -p "$LOCK_DIR" 2>/dev/null || true
exec 200>"${LOCK_DIR}/restore_wrapper.lock"
if ! flock -n 200; then
  echo "[$(date '+%F %T')] [ERROR] Another restore is already running." >&2
  exit 1
fi

############################
# PHASE 1: FULL RESTORE
############################

echo ""
echo "===================================================="
echo "PHASE 1 of 2: FULL RESTORE  (backup_id: $BACKUP_ID)"
echo "===================================================="
echo ""

if ! "${SCRIPT_DIR}/restore_full.sh" "$BACKUP_ID"; then
  echo "" >&2
  echo "====================================================" >&2
  echo "[ERROR] PHASE 1 FAILED — full restore did not complete." >&2
  echo "[ERROR] Binlog apply was NOT attempted." >&2
  echo "[ERROR] Do not let applications use this server." >&2
  echo "====================================================" >&2
  exit 1
fi

############################
# PHASE 2: BINLOG APPLY
############################

echo ""
echo "===================================================="
echo "PHASE 2 of 2: BINLOG APPLY  (backup_id: $BACKUP_ID)"
echo "===================================================="
echo ""

if ! "${SCRIPT_DIR}/apply_binlog.sh" "$BACKUP_ID"; then
  echo "" >&2
  echo "====================================================" >&2
  echo "[ERROR] PHASE 2 FAILED — binlog apply did not complete." >&2
  echo "[ERROR] This instance may be PARTIALLY APPLIED." >&2
  echo "[ERROR] Do not let applications use this server." >&2
  echo "" >&2
  echo "[ERROR] GTID is off, so the apply cannot be resumed. Roll back:" >&2
  echo "[ERROR]   ${SCRIPT_DIR}/restore_full.sh $BACKUP_ID" >&2
  echo "[ERROR] (re-reads the full archive from the share — allow for the transfer)" >&2
  echo "" >&2
  echo "[ERROR] See the apply error log referenced above for the cause." >&2
  echo "====================================================" >&2
  exit 1
fi

############################
# COMPLETE
############################

cat <<EOF

====================================================
RESTORE + APPLY COMPLETE  (backup_id: $BACKUP_ID)
====================================================

Remaining steps:

  1. Verify row counts on your busiest tables, and run
     application smoke tests.

  2. Take a FRESH FULL BACKUP immediately:
       ${SCRIPT_DIR}/backup.sh

     The binlog chain restarts at this recovery point. Until a new
     full backup exists, this server has no usable recovery baseline.
====================================================
EOF

exit 0
