#!/bin/bash

# Log directory and file
LOG_DIR="/livestorage/DBBackup/Cloud-Live-DB-Tirupati/restart-logs"
LOG_FILE="$LOG_DIR/mysql-restart-$(date +%Y-%m-%d).log"

# Create log directory if not exists
mkdir -p "$LOG_DIR"

# Start log
echo "=========================================" >> "$LOG_FILE"
echo "$(date '+%Y-%m-%d %H:%M:%S') - MySQL restart started" >> "$LOG_FILE"

# Restart MySQL
systemctl restart mysql

# Check status
if [ $? -eq 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - MySQL restart completed successfully" >> "$LOG_FILE"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - MySQL restart FAILED" >> "$LOG_FILE"
fi

# Delete logs older than 7 days
find "$LOG_DIR" -name "*.log" -type f -mtime +7 -delete

echo "$(date '+%Y-%m-%d %H:%M:%S') - Old logs cleanup completed" >> "$LOG_FILE"
echo "=========================================" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

40 3 * * 0 /Data/script/mysql_restart.sh