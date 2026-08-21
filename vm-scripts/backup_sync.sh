#!/bin/bash
#===============================================================================
# backup_sync.sh
# 
# Purpose : Copy latest backup files from source Azure storage mount to
#           destination Azure storage mount, and enforce retention policy
#           on the destination.
#
# Author  : Keyur Adhyaru
# Created : 2026-07-01
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# CONFIGURATION — change these variables as needed
#-------------------------------------------------------------------------------

# Source and destination mount roots
SOURCE_BASE="/livestorage/Backup"
DEST_BASE="/southstorage/backup_latest"

# Server folders to process (space-separated)
# Add or remove server names here as needed
SERVER_FOLDERS=(
    "Cloud-Live-DB-4th-Server"
    "Cloud-Live-DB-Default"
    "Cloud-Live-DB-Sandbox"
    "Cloud-Live-DB-Tirupati"
    "GSP-Cloud-Live-DB"
)

# Backup file extension pattern (glob). Adjust if your files use .sql, .gz, etc.
BACKUP_FILE_PATTERN="*.tar.gz"

# Retention: keep files in destination for this many days, delete older ones
DEST_RETENTION_DAYS=3

# Log directory and retention
LOG_DIR="/southstorage/backup_latest/log/backup_sync"
LOG_RETENTION_DAYS=7

# Date stamp used in log filenames
DATE_STAMP=$(date +"%Y-%m-%d")

# Dry run mode: set to "true" to preview actions without copying/deleting
DRY_RUN="false"

#-------------------------------------------------------------------------------
# INTERNAL VARIABLES — do not change unless you know what you're doing
#-------------------------------------------------------------------------------

COPY_LOG="${LOG_DIR}/copy_${DATE_STAMP}.log"
DELETE_LOG="${LOG_DIR}/delete_${DATE_STAMP}.log"

TOTAL_COPY_COUNT=0
TOTAL_COPY_SIZE=0
TOTAL_DELETE_COUNT=0
TOTAL_DELETE_SIZE=0

#-------------------------------------------------------------------------------
# HELPER FUNCTIONS
#-------------------------------------------------------------------------------

log_header() {
    local file="$1"
    local title="$2"
    {
        echo "==============================================================================="
        echo " ${title}"
        echo " Date       : $(date '+%Y-%m-%d %H:%M:%S')"
        echo " Source      : ${SOURCE_BASE}"
        echo " Destination : ${DEST_BASE}"
        echo " Retention   : ${DEST_RETENTION_DAYS} days"
        echo " Servers     : ${SERVER_FOLDERS[*]}"
        echo " Dry Run     : ${DRY_RUN}"
        echo "==============================================================================="
        echo ""
    } >> "${file}"
}

human_size() {
    # Convert bytes to human-readable format
    local bytes=$1
    if (( bytes >= 1073741824 )); then
        printf "%.2f GB" "$(echo "scale=2; ${bytes}/1073741824" | bc)"
    elif (( bytes >= 1048576 )); then
        printf "%.2f MB" "$(echo "scale=2; ${bytes}/1048576" | bc)"
    elif (( bytes >= 1024 )); then
        printf "%.2f KB" "$(echo "scale=2; ${bytes}/1024" | bc)"
    else
        printf "%d Bytes" "${bytes}"
    fi
}

check_prerequisites() {
    # Verify source mount is accessible
    if [[ ! -d "${SOURCE_BASE}" ]]; then
        echo "ERROR: Source path '${SOURCE_BASE}' does not exist or is not mounted." | tee -a "${COPY_LOG}"
        exit 1
    fi

    # Verify destination mount is accessible
    if [[ ! -d "${DEST_BASE}" ]]; then
        echo "ERROR: Destination path '${DEST_BASE}' does not exist or is not mounted." | tee -a "${COPY_LOG}"
        exit 1
    fi

    # Create log directory if missing
    mkdir -p "${LOG_DIR}"
}

#-------------------------------------------------------------------------------
# COPY LOGIC — find latest file per database folder and copy to destination
#-------------------------------------------------------------------------------

copy_latest_backups() {
    echo "--- COPY DETAILS ---" >> "${COPY_LOG}"
    printf "%-20s %-30s %-50s %15s\n" "SERVER" "DATABASE" "FILE" "SIZE" >> "${COPY_LOG}"
    echo "------------------------------------------------------------------------------------------------------------" >> "${COPY_LOG}"

    for server in "${SERVER_FOLDERS[@]}"; do
        local src_server_path="${SOURCE_BASE}/${server}"

        if [[ ! -d "${src_server_path}" ]]; then
            echo "[WARN] Server folder not found: ${src_server_path} — skipping" >> "${COPY_LOG}"
            continue
        fi

        # Iterate over each database folder inside the server folder
        for db_dir in "${src_server_path}"/*/; do
            # Skip if no subdirectories found (glob returned literal)
            [[ -d "${db_dir}" ]] || continue

            local db_name
            db_name=$(basename "${db_dir}")

            # Find the latest backup file by modification time
            local latest_file
            latest_file=$(find "${db_dir}" -maxdepth 1 -type f -name "${BACKUP_FILE_PATTERN}" -printf '%T@ %p\n' 2>/dev/null \
                          | sort -rn | head -1 | awk '{print $2}')

            if [[ -z "${latest_file}" ]]; then
                echo "[WARN] No backup file matching '${BACKUP_FILE_PATTERN}' in ${db_dir} — skipping" >> "${COPY_LOG}"
                continue
            fi

            local file_name file_size
            file_name=$(basename "${latest_file}")
            file_size=$(stat -c '%s' "${latest_file}" 2>/dev/null || echo 0)

            # Prepare destination path
            local dest_db_path="${DEST_BASE}/${server}/${db_name}"
            local dest_file="${dest_db_path}/${file_name}"

            # Skip if the exact same file already exists at destination (same name + size)
            if [[ -f "${dest_file}" ]]; then
                local dest_size
                dest_size=$(stat -c '%s' "${dest_file}" 2>/dev/null || echo 0)
                if [[ "${file_size}" -eq "${dest_size}" ]]; then
                    printf "%-20s %-30s %-50s %15s  [SKIPPED - already exists]\n" \
                        "${server}" "${db_name}" "${file_name}" "$(human_size "${file_size}")" >> "${COPY_LOG}"
                    continue
                fi
            fi

            # Copy
            if [[ "${DRY_RUN}" == "true" ]]; then
                printf "%-20s %-30s %-50s %15s  [DRY RUN]\n" \
                    "${server}" "${db_name}" "${file_name}" "$(human_size "${file_size}")" >> "${COPY_LOG}"
            else
                mkdir -p "${dest_db_path}"
                if cp -f "${latest_file}" "${dest_file}" 2>>"${COPY_LOG}"; then
                    printf "%-20s %-30s %-50s %15s  [OK]\n" \
                        "${server}" "${db_name}" "${file_name}" "$(human_size "${file_size}")" >> "${COPY_LOG}"
                else
                    printf "%-20s %-30s %-50s %15s  [FAILED]\n" \
                        "${server}" "${db_name}" "${file_name}" "$(human_size "${file_size}")" >> "${COPY_LOG}"
                    continue
                fi
            fi

            TOTAL_COPY_COUNT=$((TOTAL_COPY_COUNT + 1))
            TOTAL_COPY_SIZE=$((TOTAL_COPY_SIZE + file_size))
        done
    done

    # Summary
    {
        echo ""
        echo "--- COPY SUMMARY ---"
        echo "Total files copied : ${TOTAL_COPY_COUNT}"
        echo "Total size copied  : $(human_size ${TOTAL_COPY_SIZE})"
        echo "Completed at       : $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
    } >> "${COPY_LOG}"
}

#-------------------------------------------------------------------------------
# DELETE LOGIC — remove files older than retention days from destination
#-------------------------------------------------------------------------------

delete_old_backups() {
    echo "--- DELETE DETAILS ---" >> "${DELETE_LOG}"
    printf "%-20s %-30s %-50s %15s %20s\n" "SERVER" "DATABASE" "FILE" "SIZE" "LAST MODIFIED" >> "${DELETE_LOG}"
    echo "-------------------------------------------------------------------------------------------------------------------------------" >> "${DELETE_LOG}"

    for server in "${SERVER_FOLDERS[@]}"; do
        local dest_server_path="${DEST_BASE}/${server}"

        [[ -d "${dest_server_path}" ]] || continue

        for db_dir in "${dest_server_path}"/*/; do
            [[ -d "${db_dir}" ]] || continue

            local db_name
            db_name=$(basename "${db_dir}")

            # Find files older than retention period
            while IFS= read -r old_file; do
                [[ -z "${old_file}" ]] && continue

                local file_name file_size file_mtime
                file_name=$(basename "${old_file}")
                file_size=$(stat -c '%s' "${old_file}" 2>/dev/null || echo 0)
                file_mtime=$(stat -c '%y' "${old_file}" 2>/dev/null | cut -d'.' -f1)

                if [[ "${DRY_RUN}" == "true" ]]; then
                    printf "%-20s %-30s %-50s %15s %20s  [DRY RUN]\n" \
                        "${server}" "${db_name}" "${file_name}" "$(human_size "${file_size}")" "${file_mtime}" >> "${DELETE_LOG}"
                else
                    if rm -f "${old_file}" 2>>"${DELETE_LOG}"; then
                        printf "%-20s %-30s %-50s %15s %20s  [DELETED]\n" \
                            "${server}" "${db_name}" "${file_name}" "$(human_size "${file_size}")" "${file_mtime}" >> "${DELETE_LOG}"
                    else
                        printf "%-20s %-30s %-50s %15s %20s  [FAILED]\n" \
                            "${server}" "${db_name}" "${file_name}" "$(human_size "${file_size}")" "${file_mtime}" >> "${DELETE_LOG}"
                        continue
                    fi
                fi

                TOTAL_DELETE_COUNT=$((TOTAL_DELETE_COUNT + 1))
                TOTAL_DELETE_SIZE=$((TOTAL_DELETE_SIZE + file_size))

            done < <(find "${db_dir}" -maxdepth 1 -type f -name "${BACKUP_FILE_PATTERN}" -mtime +"${DEST_RETENTION_DAYS}" 2>/dev/null)
        done
    done

    # Summary
    {
        echo ""
        echo "--- DELETE SUMMARY ---"
        echo "Total files deleted : ${TOTAL_DELETE_COUNT}"
        echo "Total size freed    : $(human_size ${TOTAL_DELETE_SIZE})"
        echo "Completed at        : $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
    } >> "${DELETE_LOG}"
}

#-------------------------------------------------------------------------------
# LOG CLEANUP — remove log files older than LOG_RETENTION_DAYS
#-------------------------------------------------------------------------------

cleanup_old_logs() {
    local deleted_logs=0

    if [[ -d "${LOG_DIR}" ]]; then
        while IFS= read -r old_log; do
            [[ -z "${old_log}" ]] && continue
            if [[ "${DRY_RUN}" == "true" ]]; then
                echo "[DRY RUN] Would delete old log: ${old_log}"
            else
                rm -f "${old_log}"
            fi
            deleted_logs=$((deleted_logs + 1))
        done < <(find "${LOG_DIR}" -maxdepth 1 -type f -name "*.log" -mtime +"${LOG_RETENTION_DAYS}" 2>/dev/null)
    fi

    if (( deleted_logs > 0 )); then
        echo "[INFO] Cleaned up ${deleted_logs} old log file(s) from ${LOG_DIR}" >> "${COPY_LOG}"
    fi
}

#-------------------------------------------------------------------------------
# MAIN
#-------------------------------------------------------------------------------

main() {
    echo "========================================"
    echo " Backup Sync started at $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================"

    check_prerequisites

    # Initialize log files with headers
    log_header "${COPY_LOG}" "BACKUP COPY LOG"
    log_header "${DELETE_LOG}" "BACKUP DELETE LOG"

    echo "[1/3] Copying latest backups from source to destination..."
    copy_latest_backups

    echo "[2/3] Deleting backups older than ${DEST_RETENTION_DAYS} days from destination..."
    delete_old_backups

    echo "[3/3] Cleaning up log files older than ${LOG_RETENTION_DAYS} days..."
    cleanup_old_logs

    echo ""
    echo "========================================"
    echo " DONE"
    echo " Copy  : ${TOTAL_COPY_COUNT} files ($(human_size ${TOTAL_COPY_SIZE}))"
    echo " Delete: ${TOTAL_DELETE_COUNT} files ($(human_size ${TOTAL_DELETE_SIZE}))"
    echo " Logs  : ${LOG_DIR}"
    echo "========================================"
}

main "$@"


shutdown -h +5 "Byeeeee"
