#!/usr/bin/env bash
###############################################################################
#  provision.sh  (v6)
#  -----------------------------------------------------------------------
#  Fresh-VM provisioning for Ubuntu 24.04 (noble) / amd64
#
#  Every component is individually selectable. Install one thing or all of them.
#
#  Usage    : sudo bash provision.sh
#  Log      : /var/log/vm-provision.log
#  State    : /var/lib/vm-provision/state
#  Secrets  : /root/.mysql_credentials  (0600)
#
#  Behaviour:
#    - Interactive [ ]/[x] menu. Numbers, ranges (6-10), lists (1,4,9), groups.
#    - Fail-fast: if a SELECTED component is already installed, abort.
#    - Nothing is written to the system before the plan is confirmed.
#    - The data disk is NEVER formatted if it already contains data.
#    - With DATA_DISK_LUN empty and no extra data disk attached, /Data is created
#      on the OS disk instead (no format, no fstab). Set DATA_ALLOW_OS_DISK="no"
#      to make a missing data disk a hard error.
#    - Cleanup purges failed non-MySQL components only. MySQL is never purged.
###############################################################################

set -euo pipefail

# =============================================================================
# SECTION 1 : CONSTANTS  (edit here, nowhere else)
# =============================================================================

# ---- Data disk --------------------------------------------------------------
# Accepts: "0" | "lun0" | "/dev/disk/azure/scsi1/lun0" | "/dev/sdb"
# Leave empty for auto-detect:
#   - usable data disk(s) attached  -> you are prompted to pick one
#   - no usable data disk attached  -> /Data is a plain directory on the OS disk
#                                      (nothing formatted, no fstab entry)
# A non-empty value is mandatory: if it cannot be resolved the script aborts and
# never silently falls back to the OS disk.
DATA_DISK_LUN=""
DATA_FS_TYPE="ext4"
DATA_FS_LABEL="data"
DATA_MIN_GB=20
# Set to "no" to forbid the OS-disk fallback and require a real data disk.
DATA_ALLOW_OS_DISK="yes"

# ---- Azure Files SMB shares (MULTIPLE supported) ----------------------------
# One entry per share:  "cred_file|share_name|mount_point"
# Leave the array empty to be prompted (you can add as many as you like).
SMB_SHARES=(
  "/home/miracle/livestoragedata.cred|livestorage|/livestorage"
  "/home/miracle/rkitdatastorage.cred|rkitdatastorage|/rkitdatastorage"
)
SMB_CRED_DIR="/etc/smbcredentials"
SMB_ENDPOINT_SUFFIX="file.core.windows.net"
SMB_OPTS="_netdev,nofail,dir_mode=0770,file_mode=0660,serverino,nosharesock,actimeo=30,mfsymlinks"

# ---- MySQL ------------------------------------------------------------------
MYSQL_VERSION="8.4.4"
MYSQL_BUNDLE="mysql-server_${MYSQL_VERSION}-1ubuntu24.04_amd64.deb-bundle.tar"
MYSQL_URL="https://downloads.mysql.com/archives/get/p/23/file/${MYSQL_BUNDLE}"
MYSQL_SIG_URL="https://downloads.mysql.com/archives/gpg/?file=${MYSQL_BUNDLE}&p=23"
MYSQL_GPG_FPR="BCA43417C3B485DD128EC6D4B7B3B788A8D3785C"
MYSQL_GPG_REQUIRED="yes"
MYSQL_KEY_SOURCES=(
  "https://repo.mysql.com/RPM-GPG-KEY-mysql-2023"
  "https://repo.mysql.com/RPM-GPG-KEY-mysql-2022"
)
MYSQL_KEYSERVER="hkps://keys.openpgp.org"

# ---- Percona XtraBackup -----------------------------------------------------
PXB_PKG="percona-xtrabackup-84"
PXB_VERSION="8.4.0-6-1.noble"
PERCONA_RELEASE_DEB="https://repo.percona.com/apt/percona-release_latest.generic_all.deb"
PXB_PIN_FILE="/etc/apt/preferences.d/00-percona-xtrabackup.pref"

# ---- node_exporter ----------------------------------------------------------
NODE_VERSION="1.11.1"
NODE_ARCH="amd64"
NODE_TARBALL="node_exporter-${NODE_VERSION}.linux-${NODE_ARCH}.tar.gz"
NODE_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_VERSION}/${NODE_TARBALL}"
NODE_SHA_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_VERSION}/sha256sums.txt"
NODE_USER="node_exporter"
NODE_BIN="/usr/local/bin/node_exporter"
NODE_SERVICE="/etc/systemd/system/node_exporter.service"
NODE_PORT="9100"

# ---- System tuning ----------------------------------------------------------
APT_DAILY_UNITS=(apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service)
SNAPD_UNITS=(snapd.service snapd.socket snapd.seeded.service snapd.snap-repair.timer)

# ---- Timezone ---------------------------------------------------------------
# Any zone accepted by timedatectl. List them with: timedatectl list-timezones
TIMEZONE="Asia/Kolkata"

# ---- Transparent Huge Pages -------------------------------------------------
THP_SERVICE="/etc/systemd/system/disable-thp.service"
THP_SYS_ENABLED="/sys/kernel/mm/transparent_hugepage/enabled"
THP_SYS_DEFRAG="/sys/kernel/mm/transparent_hugepage/defrag"

# ---- Paths ------------------------------------------------------------------
DATA_MOUNT="/Data"
MYSQL_DATADIR="${DATA_MOUNT}/mysql"
MYSQL_BACKUPDIR="${DATA_MOUNT}/backups"
MYSQL_CONF="/etc/mysql/mysql.conf.d/mysqld.cnf"
MYSQL_LOGDIR="/var/log/mysql"
MYSQL_ORPHAN_DATADIR="/var/lib/mysql"
APPARMOR_LOCAL="/etc/apparmor.d/local/usr.sbin.mysqld"
MYSQL_DROPIN_DIR="/etc/systemd/system/mysql.service.d"
MYSQL_DROPIN="${MYSQL_DROPIN_DIR}/override.conf"
LOGROTATE_FILE="/etc/logrotate.d/mysql-error"
CREDS_FILE="/root/.mysql_credentials"

STATE_DIR="/var/lib/vm-provision"
STATE_FILE="${STATE_DIR}/state"
THP_BASELINE="${STATE_DIR}/thp.baseline"
TZ_BASELINE="${STATE_DIR}/timezone.baseline"
LOG_FILE="/var/log/vm-provision.log"
LOCK_FILE="/var/lock/vm-provision.lock"

# ---- Database users ---------------------------------------------------------
ADMIN_USER="Admin"
ADMIN_HOST="%"
MYSQL_PORT="3306"

# =============================================================================
# SECTION 2 : PROFILE MATRIX
# =============================================================================

declare -A VM_SIZE_PROFILE=(
  [Standard_B2s]=P1        [Standard_B2als_v2]=P1
  [Standard_B2as_v2]=P2
  [Standard_D4as_v4]=P3    [Standard_D4as_v5]=P3   [Standard_B4as_v2]=P3
  [Standard_D8as_v5]=P4    [Standard_B8as_v2]=P4
  [Standard_D16as_v5]=P5

  # ---- v6 low-memory families (NVMe controllers, 2 GiB per vCPU) ----
  [Standard_D2ls_v6]=P1    [Standard_D2als_v6]=P1
  [Standard_D2lds_v6]=P1   [Standard_D2alds_v6]=P1
  [Standard_D4ls_v6]=P6    [Standard_D4als_v6]=P6
  [Standard_D4lds_v6]=P6   [Standard_D4alds_v6]=P6
  [Standard_D8ls_v6]=P3    [Standard_D8als_v6]=P3
  [Standard_D8lds_v6]=P3   [Standard_D8alds_v6]=P3
  [Standard_D16ls_v6]=P4   [Standard_D16als_v6]=P4
  [Standard_D16lds_v6]=P4  [Standard_D16alds_v6]=P4

  # ---- v6 standard-memory families (4 GiB per vCPU) ----
  [Standard_D4s_v6]=P3     [Standard_D4as_v6]=P3
  [Standard_D4ds_v6]=P3    [Standard_D4ads_v6]=P3
  [Standard_D8s_v6]=P4     [Standard_D8as_v6]=P4
  [Standard_D8ds_v6]=P4    [Standard_D8ads_v6]=P4
  [Standard_D16s_v6]=P5    [Standard_D16as_v6]=P5
  [Standard_D16ds_v6]=P5   [Standard_D16ads_v6]=P5
)

declare -A PROFILE_DESC=(
  [P1]="2 vCPU / 4 GiB"   [P2]="2 vCPU / 8 GiB"   [P3]="4 vCPU / 16 GiB"
  [P4]="8 vCPU / 32 GiB"  [P5]="16 vCPU / 64 GiB"
  [P6]="4 vCPU / 8 GiB"
)

declare -A PROF=(
  [P1:BUFFER_POOL]=1G          [P1:BP_INSTANCES]=1        [P1:REDO_CAPACITY]=512M
  [P1:LOG_BUFFER]=8M           [P1:MAX_CONNECTIONS]=150   [P1:BACK_LOG]=150
  [P1:SORT_BUFFER]=512K        [P1:JOIN_BUFFER]=512K      [P1:READ_BUFFER]=128K
  [P1:READ_RND_BUFFER]=256K    [P1:TMP_TABLE_SIZE]=32M    [P1:KEY_BUFFER]=16M
  [P1:TABLE_OPEN_CACHE]=1000   [P1:TOC_INSTANCES]=2       [P1:TABLE_DEF_CACHE]=1400
  [P1:OPEN_FILES_LIMIT]=20000  [P1:INNODB_OPEN_FILES]=1000
  [P1:AUTOEXTEND]=64           [P1:MAX_BINLOG_SIZE]=256M

  [P2:BUFFER_POOL]=3G          [P2:BP_INSTANCES]=3        [P2:REDO_CAPACITY]=1G
  [P2:LOG_BUFFER]=16M          [P2:MAX_CONNECTIONS]=250   [P2:BACK_LOG]=250
  [P2:SORT_BUFFER]=1M          [P2:JOIN_BUFFER]=1M        [P2:READ_BUFFER]=128K
  [P2:READ_RND_BUFFER]=256K    [P2:TMP_TABLE_SIZE]=48M    [P2:KEY_BUFFER]=32M
  [P2:TABLE_OPEN_CACHE]=2000   [P2:TOC_INSTANCES]=2       [P2:TABLE_DEF_CACHE]=2000
  [P2:OPEN_FILES_LIMIT]=30000  [P2:INNODB_OPEN_FILES]=2000
  [P2:AUTOEXTEND]=64           [P2:MAX_BINLOG_SIZE]=256M

  [P3:BUFFER_POOL]=8G          [P3:BP_INSTANCES]=8        [P3:REDO_CAPACITY]=2G
  [P3:LOG_BUFFER]=16M          [P3:MAX_CONNECTIONS]=500   [P3:BACK_LOG]=500
  [P3:SORT_BUFFER]=2M          [P3:JOIN_BUFFER]=2M        [P3:READ_BUFFER]=128K
  [P3:READ_RND_BUFFER]=512K    [P3:TMP_TABLE_SIZE]=64M    [P3:KEY_BUFFER]=64M
  [P3:TABLE_OPEN_CACHE]=4000   [P3:TOC_INSTANCES]=4       [P3:TABLE_DEF_CACHE]=4096
  [P3:OPEN_FILES_LIMIT]=40000  [P3:INNODB_OPEN_FILES]=4000
  [P3:AUTOEXTEND]=128          [P3:MAX_BINLOG_SIZE]=512M

  [P4:BUFFER_POOL]=18G         [P4:BP_INSTANCES]=8        [P4:REDO_CAPACITY]=4G
  [P4:LOG_BUFFER]=16M          [P4:MAX_CONNECTIONS]=1000  [P4:BACK_LOG]=1000
  [P4:SORT_BUFFER]=4M          [P4:JOIN_BUFFER]=4M        [P4:READ_BUFFER]=128K
  [P4:READ_RND_BUFFER]=512K    [P4:TMP_TABLE_SIZE]=128M   [P4:KEY_BUFFER]=64M
  [P4:TABLE_OPEN_CACHE]=4096   [P4:TOC_INSTANCES]=8       [P4:TABLE_DEF_CACHE]=4096
  [P4:OPEN_FILES_LIMIT]=65535  [P4:INNODB_OPEN_FILES]=4096
  [P4:AUTOEXTEND]=128          [P4:MAX_BINLOG_SIZE]=512M

  [P5:BUFFER_POOL]=40G         [P5:BP_INSTANCES]=16       [P5:REDO_CAPACITY]=8G
  [P5:LOG_BUFFER]=32M          [P5:MAX_CONNECTIONS]=1500  [P5:BACK_LOG]=1500
  [P5:SORT_BUFFER]=4M          [P5:JOIN_BUFFER]=8M        [P5:READ_BUFFER]=128K
  [P5:READ_RND_BUFFER]=1M      [P5:TMP_TABLE_SIZE]=256M   [P5:KEY_BUFFER]=128M
  [P5:TABLE_OPEN_CACHE]=8192   [P5:TOC_INSTANCES]=16      [P5:TABLE_DEF_CACHE]=8192
  [P5:OPEN_FILES_LIMIT]=65535  [P5:INNODB_OPEN_FILES]=8192
  [P5:AUTOEXTEND]=128          [P5:MAX_BINLOG_SIZE]=512M

  # P6 : 4 vCPU / 8 GiB  (low-memory v6 sizes; RAM-bound like P2, more cores)
  [P6:BUFFER_POOL]=3G          [P6:BP_INSTANCES]=3        [P6:REDO_CAPACITY]=1G
  [P6:LOG_BUFFER]=16M          [P6:MAX_CONNECTIONS]=400   [P6:BACK_LOG]=400
  [P6:SORT_BUFFER]=1M          [P6:JOIN_BUFFER]=1M        [P6:READ_BUFFER]=128K
  [P6:READ_RND_BUFFER]=256K    [P6:TMP_TABLE_SIZE]=48M    [P6:KEY_BUFFER]=32M
  [P6:TABLE_OPEN_CACHE]=2000   [P6:TOC_INSTANCES]=4       [P6:TABLE_DEF_CACHE]=2000
  [P6:OPEN_FILES_LIMIT]=30000  [P6:INNODB_OPEN_FILES]=2000
  [P6:AUTOEXTEND]=64           [P6:MAX_BINLOG_SIZE]=256M
)

p() { echo "${PROF[${PROFILE}:$1]}"; }

# =============================================================================
# SECTION 3 : LOGGING
# =============================================================================

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m';    DIM=$'\033[2m'; NC=$'\033[0m'

if { : >/dev/tty; } 2>/dev/null; then TTY=/dev/tty; else TTY=/dev/stderr; fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"; chmod 640 "$LOG_FILE"
exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1

ts()      { date '+%Y-%m-%d %H:%M:%S'; }
info()    { echo "${CYAN}[$(ts)] [INFO]${NC} $*"; }
ok()      { echo "${GREEN}[$(ts)] [OK]${NC} $*"; }
warn()    { echo "${YELLOW}[$(ts)] [WARN]${NC} $*"; }
err()     { echo "${RED}[$(ts)] [ERROR]${NC} $*"; }
die()     { err "$*"; exit 1; }
phase()   { echo; echo "${BOLD}${CYAN}══════════════════════════════════════════════════════════${NC}"
            echo "${BOLD}${CYAN} $*${NC}"
            echo "${BOLD}${CYAN}══════════════════════════════════════════════════════════${NC}"; }

# =============================================================================
# SECTION 4 : COMPONENT TABLE   (display order == menu numbering)
# =============================================================================

COMPONENTS=(
  timezone apt_daily snapd_disable thp_disable
  mysql xtrabackup
  node_exporter
  smb_shares
  mc net_tools unzip bzip2 lz4
  perl_dbd perl_dbi curl_dev
)

declare -A COMP_GROUP=(
  [timezone]="System tuning"
  [apt_daily]="System tuning"   [snapd_disable]="System tuning"  [thp_disable]="System tuning"
  [mysql]="Database"            [xtrabackup]="Database"
  [node_exporter]="Monitoring"
  [smb_shares]="Storage"
  [mc]="CLI tools"              [net_tools]="CLI tools"   [unzip]="CLI tools"
  [bzip2]="CLI tools"           [lz4]="CLI tools"
  [perl_dbd]="Perl / dev"       [perl_dbi]="Perl / dev"   [curl_dev]="Perl / dev"
)

declare -A COMP_LABEL=(
  [timezone]="Set system timezone to ${TIMEZONE}"
  [apt_daily]="Disable apt-daily auto-update timers"
  [snapd_disable]="Disable + mask snapd   (breaks Livepatch)"
  [thp_disable]="Disable Transparent Huge Pages"
  [mysql]="MySQL ${MYSQL_VERSION}"
  [xtrabackup]="Percona XtraBackup ${PXB_VERSION%%-1.noble}"
  [node_exporter]="node_exporter ${NODE_VERSION}"
  [smb_shares]="Azure Files SMB mounts"
  [mc]="mc            (Midnight Commander)"
  [net_tools]="net-tools     (ifconfig, netstat)"
  [unzip]="unzip"
  [bzip2]="bzip2"
  [lz4]="lz4"
  [perl_dbd]="libdbd-mysql-perl"
  [perl_dbi]="libdbi-perl"
  [curl_dev]="libcurl4-openssl-dev"
)

declare -A COMP_PKG=(
  [mc]="mc"  [net_tools]="net-tools"  [unzip]="unzip"  [bzip2]="bzip2"  [lz4]="lz4"
  [perl_dbd]="libdbd-mysql-perl"  [perl_dbi]="libdbi-perl"  [curl_dev]="libcurl4-openssl-dev"
)

declare -A COMP_DEFAULT=(
  [timezone]=1 [apt_daily]=1 [snapd_disable]=0 [thp_disable]=1
  [mysql]=1 [xtrabackup]=1 [node_exporter]=1 [smb_shares]=0
  [mc]=1 [net_tools]=1 [unzip]=1 [bzip2]=1 [lz4]=1
  [perl_dbd]=0 [perl_dbi]=0 [curl_dev]=0
)

declare -A GROUP_KEY=(
  [t]="System tuning" [d]="Database" [m]="Monitoring"
  [s]="Storage"       [c]="CLI tools" [p]="Perl / dev"
)

declare -A SELECTED INSTALLED

# =============================================================================
# SECTION 5 : STATE, LOCK, TRAPS
# =============================================================================

WORKDIR=""
CURRENT_COMPONENT=""

state_init() { mkdir -p "$STATE_DIR"; touch "$STATE_FILE"; chmod 600 "$STATE_FILE"; }
state_set()  { sed -i "/^$1=/d" "$STATE_FILE" 2>/dev/null || true
               echo "$1=$2" >> "$STATE_FILE"; }
state_get()  { grep -m1 "^$1=" "$STATE_FILE" 2>/dev/null | cut -d= -f2- || true; }

on_error() {
  local rc=$?
  [[ -n "$CURRENT_COMPONENT" ]] && state_set "$CURRENT_COMPONENT" failed
  err "Failed with exit code ${rc}."
  [[ -n "$CURRENT_COMPONENT" ]] && err "Component '${CURRENT_COMPONENT}' marked FAILED in ${STATE_FILE}"
  err "Full log: ${LOG_FILE}"
  return $rc
}
trap on_error ERR

on_exit() {
  local rc=$?
  [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
  exec 9>&- 2>/dev/null || true
  if [[ $rc -eq 0 ]]; then ok "Finished. Log: ${LOG_FILE}"
  else err "Aborted. Log: ${LOG_FILE}"; fi
}
trap on_exit EXIT
trap 'err "Interrupted by user (SIGINT/SIGTERM)."; exit 130' INT TERM

# =============================================================================
# SECTION 6 : HELPERS
# =============================================================================

have()          { command -v "$1" &>/dev/null; }
unit_exists()   { systemctl list-unit-files "$1" 2>/dev/null | grep -q "^$1"; }
svc_active()    { systemctl is-active --quiet "$1" 2>/dev/null; }
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"; }
genpass()       { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 28; }
sel()           { [[ ${SELECTED[$1]} -eq 1 ]]; }

confirm() {
  local reply
  printf "%s [y/N]: " "$1" >"$TTY"
  read -r reply <"$TTY"
  [[ "$reply" =~ ^[Yy]$ ]]
}

ask() {
  local prompt="$1" __var="$2" __val=""
  while [[ -z "$__val" ]]; do
    printf "  %s: " "$prompt" >"$TTY"
    read -r __val <"$TTY" || true
    [[ -z "$__val" ]] && echo "  ${YELLOW}Value required.${NC}" >"$TTY"
  done
  printf -v "$__var" '%s' "$__val"
}

port_open() { timeout 5 bash -c "cat < /dev/null > /dev/tcp/$1/$2" 2>/dev/null; }

# =============================================================================
# SECTION 7 : DATA DISK
# =============================================================================

DATA_DEVICE=""; DATA_ACTION=""; DATA_DEVICE_INFO=""

list_azure_luns() {
  shopt -s nullglob
  local link dev found=0 base
  echo "  ${BOLD}Attached Azure data disks${NC}" >"$TTY"
  printf "    %-5s %-14s %-8s %-8s %-10s %s\n" LUN DEVICE SIZE FSTYPE LABEL MOUNT >"$TTY"
  for base in /dev/disk/azure/data/by-lun /dev/disk/azure/scsi1; do
    for link in "$base"/*; do
      [[ -b "$link" ]] || continue
      [[ "$link" == *-part* ]] && continue
      dev=$(readlink -f "$link")
      printf "    %-5s %-14s %-8s %-8s %-10s %s\n" \
        "$(basename "$link" | sed 's/^lun//')" "$dev" \
        "$(lsblk -dno SIZE       "$dev" 2>/dev/null | tr -d ' ')" \
        "$(lsblk -dno FSTYPE     "$dev" 2>/dev/null | tr -d ' ' | sed 's/^$/-/')" \
        "$(lsblk -dno LABEL      "$dev" 2>/dev/null | tr -d ' ' | sed 's/^$/-/')" \
        "$(lsblk -dno MOUNTPOINT "$dev" 2>/dev/null | tr -d ' ' | sed 's/^$/-/')" >"$TTY"
      found=1
    done
    [[ $found -eq 1 ]] && break
  done
  shopt -u nullglob

  if [[ $found -eq 0 ]]; then
    warn "No Azure LUN symlinks found (neither data/by-lun nor scsi1)." >"$TTY"
    if have azure-nvme-id; then
      echo "  azure-nvme-id output:" >"$TTY"; azure-nvme-id 2>/dev/null | sed 's/^/    /' >"$TTY"
    else
      echo "  ${DIM}Install azure-vm-utils for LUN mapping, or pass a device path.${NC}" >"$TTY"
    fi
  fi
  echo >"$TTY"
}

# Whole disk backing / — used to keep the OS disk out of every candidate list.
root_disk_path() {
  local rootsrc rootdisk
  rootsrc=$(findmnt -no SOURCE / 2>/dev/null || true)
  [[ -n "$rootsrc" ]] || return 0
  rootdisk=$(lsblk -no PKNAME "$rootsrc" 2>/dev/null || true)
  [[ -n "$rootdisk" ]] && echo "/dev/${rootdisk}" || echo "$rootsrc"
}

# Echo one device path per disk that could serve as the data disk, OS disk always
# excluded. Azure hosts: the LUN symlinks. Anything else: unpartitioned, unmounted
# disks. Disks that already carry data are still listed — they exist, so the user
# gets asked about them instead of silently landing on the OS disk.
data_disk_candidates() {
  local base link dev rootpath osdev out=() found=0
  rootpath=$(root_disk_path)
  osdev=$(readlink -f /dev/disk/azure/os 2>/dev/null || true)
  [[ -n "$rootpath" ]] && rootpath=$(readlink -f "$rootpath")

  shopt -s nullglob
  for base in /dev/disk/azure/data/by-lun /dev/disk/azure/scsi1; do
    for link in "$base"/*; do
      [[ -b "$link" ]] || continue
      [[ "$link" == *-part* ]] && continue
      dev=$(readlink -f "$link")
      [[ -n "$rootpath" && "$dev" == "$rootpath" ]] && continue
      [[ -n "$osdev"    && "$dev" == "$osdev"    ]] && continue
      out+=("$dev"); found=1
    done
    [[ $found -eq 1 ]] && break
  done
  shopt -u nullglob

  if [[ $found -eq 0 ]]; then
    while read -r dev; do
      [[ -z "$dev" ]] && continue
      dev=$(readlink -f "$dev")
      [[ -n "$rootpath" && "$dev" == "$rootpath" ]] && continue
      [[ -n "$osdev"    && "$dev" == "$osdev"    ]] && continue
      out+=("$dev")
    done < <(lsblk -dnpo NAME,SIZE,FSTYPE,MOUNTPOINT | awk '$3=="" && $4=="" {print $1}')
  fi

  [[ ${#out[@]} -gt 0 ]] && printf '%s\n' "${out[@]}"
  return 0
}

non_azure_disk_menu() {
  local cdev candidates=() rootpath byid choice i
  declare -A MENU_BYID MENU_DEV

  rootpath=$(root_disk_path)

  while read -r cdev; do
    [[ -n "$rootpath" && "$(readlink -f "$cdev")" == "$(readlink -f "$rootpath")" ]] && continue
    candidates+=("$cdev")
  done < <(lsblk -dnpo NAME,SIZE,FSTYPE,MOUNTPOINT | awk '$3=="" && $4=="" {print $1}')

  [[ ${#candidates[@]} -gt 0 ]] || die "No unpartitioned, unmounted, non-root candidate disks found."

  echo "  ${BOLD}Non-Azure host: available data disk candidates${NC}" >"$TTY"
  printf "    %-4s %-14s %-8s %s\n" "#" DEVICE SIZE BY-ID >"$TTY"
  i=1
  for cdev in "${candidates[@]}"; do
    byid=$(find /dev/disk/by-id/ -maxdepth 1 \
            \( -lname "*/$(basename "$cdev")" -o -lname "../../$(basename "$cdev")" \) 2>/dev/null \
            | grep -v -- '-part[0-9]*$' | head -1) || true
    printf "    %-4s %-14s %-8s %s\n" "$i" "$cdev" \
      "$(lsblk -dno SIZE "$cdev" 2>/dev/null | tr -d ' ')" "${byid:-N/A}" >"$TTY"
    MENU_BYID[$i]="${byid:-$cdev}"
    MENU_DEV[$i]="$cdev"
    ((i++))
  done
  echo >"$TTY"

  local os_hint=""
  [[ "$DATA_ALLOW_OS_DISK" == "yes" ]] && os_hint=" (or 'os' to use the OS disk)"

  while true; do
    printf "  Select data disk number%s: " "$os_hint" >"$TTY"
    read -r choice <"$TTY" || true
    if [[ "$DATA_ALLOW_OS_DISK" == "yes" && "${choice,,}" == "os" ]]; then
      DATA_DISK_LUN=""
      ok "Will use the OS disk for ${DATA_MOUNT}"
      return 0
    fi
    [[ "$choice" =~ ^[0-9]+$ && -n "${MENU_BYID[$choice]:-}" ]] && break
    echo "  ${YELLOW}Invalid selection.${NC}" >"$TTY"
  done

  DATA_DISK_LUN="${MENU_BYID[$choice]}"
  ok "Selected ${MENU_DEV[$choice]} -> ${DATA_DISK_LUN}"
}

resolve_data_device() {
  local input="$1" dev="" lun=""

  # Normalise every accepted form down to a LUN number where possible
  if   [[ "$input" =~ ^[0-9]+$ ]];    then lun="$input"
  elif [[ "$input" =~ ^lun[0-9]+$ ]]; then lun="${input#lun}"
  elif [[ "$input" == /dev/disk/azure/scsi1/lun* ]];    then lun="${input##*lun}"
  elif [[ "$input" == /dev/disk/azure/data/by-lun/* ]]; then lun="${input##*/}"
  fi

  if [[ -n "$lun" ]]; then
    # (1) NVMe controllers: azure-vm-utils 80-azure-disk.rules
    dev=$(readlink -f "/dev/disk/azure/data/by-lun/${lun}" 2>/dev/null || true)
    # (2) SCSI controllers: WALinuxAgent udev rules
    [[ -b "$dev" ]] || dev=$(readlink -f "/dev/disk/azure/scsi1/lun${lun}" 2>/dev/null || true)
    # (3) azure-nvme-id, if the package is present but udev rules did not fire
    if [[ ! -b "$dev" ]] && have azure-nvme-id; then
      dev=$(azure-nvme-id 2>/dev/null | awk -F'[:,]' -v want="lun=${lun}" \
            'index($0, want) { gsub(/ /,"",$1); print $1; exit }')
      dev=$(readlink -f "${dev:-/nonexistent}" 2>/dev/null || true)
    fi
    # (4) Last resort: MSFT NVMe Accelerator maps data LUN N to namespace N+2
    if [[ ! -b "$dev" ]]; then
      local cand="/dev/nvme0n$((lun+2))"
      if [[ -b "$cand" ]]; then
        dev="$cand"
        warn "No Azure udev symlink for LUN ${lun}."
        warn "  Derived ${cand} from the NVMe namespace rule (namespace = LUN + 2)."
        warn "  For reliable mapping install: apt-get install -y azure-vm-utils"
      fi
    fi
    [[ -b "$dev" ]] || { err "LUN ${lun} did not resolve to any block device."; return 1; }
  elif [[ "$input" == /dev/disk/by-id/* || "$input" == /dev/disk/by-path/* ]]; then
    # Stable non-Azure identifiers (Hyper-V, on-prem, bare metal). No warning needed.
    dev=$(readlink -f "$input" 2>/dev/null || true)
  elif [[ "$input" == /dev/* ]]; then
    dev=$(readlink -f "$input" 2>/dev/null || true)
    warn "Raw device path given. SCSI letters reorder across reboots; NVMe names can shift too."
    if [[ -d /dev/disk/azure ]]; then
      warn "  Prefer a LUN number, e.g. DATA_DISK_LUN=\"0\"."
    else
      warn "  Prefer a stable identifier: /dev/disk/by-id/<...> (run 'ls -l /dev/disk/by-id/')."
    fi
  else
    return 1
  fi

  # Device nodes can lag briefly behind udev on non-Azure hypervisors (Hyper-V especially).
  # Give it a short, bounded settle window instead of failing on a transient miss.
  if [[ -n "$dev" && ! -b "$dev" ]]; then
    udevadm settle --timeout=5 2>/dev/null || true
    local _t=0
    while [[ ! -b "$dev" && $_t -lt 5 ]]; do sleep 1; ((_t++)); done
  fi

  [[ -n "$dev" && -b "$dev" ]] || return 1

  # Never allow the OS/root disk to be selected — works on any hypervisor.
  local rootsrc rootdisk rootdisk_path
  rootsrc=$(findmnt -no SOURCE / 2>/dev/null || true)
  if [[ -n "$rootsrc" ]]; then
    rootdisk=$(lsblk -no PKNAME "$rootsrc" 2>/dev/null || true)
    rootdisk_path=$([[ -n "$rootdisk" ]] && echo "/dev/${rootdisk}" || echo "$rootsrc")
    if [[ "$(readlink -f "$dev")" == "$(readlink -f "$rootdisk_path")" ]]; then
      err "${dev} backs the root filesystem (/). Refusing."; return 1
    fi
  fi

  # Azure-specific belt-and-braces check (redundant with above on Azure, harmless elsewhere)
  local osdev; osdev=$(readlink -f /dev/disk/azure/os 2>/dev/null || true)
  if [[ -n "$osdev" && "$dev" == "$osdev" ]]; then
    err "${dev} is the OS disk. Refusing."; return 1
  fi
  echo "$dev"
}

device_state() {
  local dev="$1" tmpmnt fstype count
  fstype=$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)
  if [[ -z "$fstype" ]]; then echo "NOFS"; return 0; fi
  tmpmnt=$(mktemp -d)
  if mount -o ro "$dev" "$tmpmnt" 2>/dev/null; then
    count=$(find "$tmpmnt" -mindepth 1 -maxdepth 1 ! -name 'lost+found' 2>/dev/null | wc -l)
    if [[ "$count" -gt 0 ]]; then
      DATA_DEVICE_INFO=$(find "$tmpmnt" -mindepth 1 -maxdepth 1 ! -name 'lost+found' -printf '%f ' 2>/dev/null | head -c 400)
      umount "$tmpmnt"; rmdir "$tmpmnt"; echo "HASDATA"; return 0
    fi
    umount "$tmpmnt"; rmdir "$tmpmnt"; echo "EMPTY"; return 0
  fi
  rmdir "$tmpmnt"; echo "NOFS"
}

inspect_data_disk() {
  local input="$1" current_src mp
  if mountpoint -q "$DATA_MOUNT"; then
    current_src=$(findmnt -no SOURCE "$DATA_MOUNT")
    if [[ -z "$input" ]]; then
      DATA_DEVICE="$current_src"; DATA_ACTION="REUSE"
      ok "${DATA_MOUNT} already mounted from ${current_src}. Will reuse."; return 0
    fi
    DATA_DEVICE=$(resolve_data_device "$input") || die "Could not resolve '${input}' to a block device."
    if [[ "$(readlink -f "$current_src")" == "$(readlink -f "$DATA_DEVICE")" ]]; then
      DATA_ACTION="REUSE"; ok "${DATA_MOUNT} already mounted from ${DATA_DEVICE}. Will reuse."; return 0
    fi
    die "${DATA_MOUNT} is mounted from ${current_src}, but you specified ${DATA_DEVICE}. Refusing."
  fi

  # No disk given and none mounted: keep everything on the OS disk.
  if [[ -z "$input" ]]; then
    [[ "$DATA_ALLOW_OS_DISK" == "yes" ]] \
      || die "No data disk specified and ${DATA_MOUNT} is not mounted (DATA_ALLOW_OS_DISK is not \"yes\")."
    DATA_ACTION="OSDISK"
    DATA_DEVICE="$(root_disk_path)"
    DATA_DEVICE="${DATA_DEVICE:-OS disk}"
    warn "No data disk in use. ${DATA_MOUNT} will be a directory on the OS disk (${DATA_DEVICE})."
    warn "  Nothing is formatted and no fstab entry is added."
    return 0
  fi

  DATA_DEVICE=$(resolve_data_device "$input") || die "Could not resolve '${input}' to a block device."

  mp=$(lsblk -no MOUNTPOINT "$DATA_DEVICE" 2>/dev/null | tr -d ' ' | grep -v '^$' | head -1 || true)
  [[ -z "$mp" ]] || die "${DATA_DEVICE} is already mounted at ${mp}. Refusing to format."

  case "$(device_state "$DATA_DEVICE")" in
    NOFS)    DATA_ACTION="FORMAT"; ok "${DATA_DEVICE} has no filesystem. Will format as ${DATA_FS_TYPE}." ;;
    EMPTY)   DATA_ACTION="FORMAT"; warn "${DATA_DEVICE} has a filesystem but it is empty. Will reformat." ;;
    HASDATA) err "${DATA_DEVICE} CONTAINS DATA. Refusing to format."
             err "  Top-level entries: ${DATA_DEVICE_INFO}"
             die "Wipe it yourself or attach a different disk. There is no override." ;;
  esac
}

prepare_data_disk() {
  # OS-disk mode: just create the directory on the root filesystem. No mkfs, no fstab.
  if [[ "$DATA_ACTION" == "OSDISK" ]]; then
    CURRENT_COMPONENT="data_disk"; state_set data_disk creating
    mkdir -p "$DATA_MOUNT"
    ok "${DATA_MOUNT} created on the OS disk (no separate filesystem, no fstab entry)"
    state_set data_disk "done"; CURRENT_COMPONENT=""
    return 0
  fi
  [[ "$DATA_ACTION" == "FORMAT" ]] || { ok "Reusing existing ${DATA_MOUNT}"; return 0; }
  CURRENT_COMPONENT="data_disk"; state_set data_disk formatting

  # Re-verify right before writing. On non-Azure hypervisors (Hyper-V etc.) the device
  # node was seen earlier in Phase 3 but can transiently disappear/re-enumerate before
  # Phase 6 runs. Settle udev and retry briefly rather than trusting a stale check.
  if [[ ! -b "$DATA_DEVICE" ]]; then
    warn "${DATA_DEVICE} not present right now. Waiting for udev to settle ..."
    udevadm settle --timeout=10 2>/dev/null || true
    local _t=0
    while [[ ! -b "$DATA_DEVICE" && $_t -lt 10 ]]; do sleep 1; ((_t++)); done
  fi
  [[ -b "$DATA_DEVICE" ]] \
    || die "${DATA_DEVICE} does not exist. If this is a raw /dev/sdX path, re-run using the stable /dev/disk/by-id/... path instead (device names can shift on this hypervisor)."

  info "Formatting ${DATA_DEVICE} as ${DATA_FS_TYPE} (label ${DATA_FS_LABEL}) ..."
  "mkfs.${DATA_FS_TYPE}" -F -m 0 -L "$DATA_FS_LABEL" "$DATA_DEVICE" >/dev/null
  ok "Filesystem created"

  mkdir -p "$DATA_MOUNT"
  local uuid; uuid=$(blkid -s UUID -o value "$DATA_DEVICE")
  [[ -n "$uuid" ]] || die "Could not read UUID from ${DATA_DEVICE}"

  if ! grep -q "UUID=${uuid}" /etc/fstab 2>/dev/null; then
    cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
    echo "UUID=${uuid} ${DATA_MOUNT} ${DATA_FS_TYPE} defaults,nofail 0 2" >> /etc/fstab
    ok "fstab entry added (UUID=${uuid})"
  fi

  mount "$DATA_MOUNT"
  mountpoint -q "$DATA_MOUNT" || die "Mount of ${DATA_MOUNT} failed"
  ok "${DATA_MOUNT} mounted from ${DATA_DEVICE}"
  state_set data_disk "done"; CURRENT_COMPONENT=""
}

# =============================================================================
# SECTION 8 : TRANSPARENT HUGE PAGES
# =============================================================================

thp_current() { sed -n 's/.*\[\(.*\)\].*/\1/p' "$1" 2>/dev/null || echo "unknown"; }

detect_thp() { [[ -f "$THP_SERVICE" ]]; }

install_thp_disable() {
  CURRENT_COMPONENT=thp_disable; state_set thp_disable installing

  [[ -f "$THP_SYS_ENABLED" ]] || { warn "THP not exposed by this kernel. Skipping."; state_set thp_disable skipped; CURRENT_COMPONENT=""; return 0; }

  local before_en before_dg
  before_en=$(thp_current "$THP_SYS_ENABLED")
  before_dg=$(thp_current "$THP_SYS_DEFRAG")
  info "THP before: enabled=${before_en}  defrag=${before_dg}"
  printf 'enabled=%s\ndefrag=%s\n' "$before_en" "$before_dg" > "$THP_BASELINE"
  chmod 600 "$THP_BASELINE"

  grep -E 'AnonHugePages|MemAvailable' /proc/meminfo | sed 's/^/    /'

  echo never > "$THP_SYS_ENABLED"
  echo never > "$THP_SYS_DEFRAG"
  ok "THP set to 'never' at runtime"

  cat > "$THP_SERVICE" <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages (THP)
Documentation=https://www.percona.com/blog/transparent-huge-pages-refresher/
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=basic.target mysql.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=basic.target
EOF
  chmod 644 "$THP_SERVICE"
  systemctl daemon-reload
  systemctl enable --quiet disable-thp.service
  ok "disable-thp.service created and enabled (persists across reboots)"

  info "THP after : enabled=$(thp_current "$THP_SYS_ENABLED")  defrag=$(thp_current "$THP_SYS_DEFRAG")"
  state_set thp_disable "done"; CURRENT_COMPONENT=""
}

cleanup_thp() {
  systemctl disable --now disable-thp.service 2>/dev/null || true
  rm -f "$THP_SERVICE"
  systemctl daemon-reload
  local en="madvise" dg="madvise"
  if [[ -f "$THP_BASELINE" ]]; then
    en=$(awk -F= '/^enabled=/{print $2}' "$THP_BASELINE"); dg=$(awk -F= '/^defrag=/{print $2}' "$THP_BASELINE")
  fi
  [[ -f "$THP_SYS_ENABLED" ]] && echo "${en:-madvise}" > "$THP_SYS_ENABLED" 2>/dev/null || true
  [[ -f "$THP_SYS_DEFRAG"  ]] && echo "${dg:-madvise}" > "$THP_SYS_DEFRAG"  2>/dev/null || true
  rm -f "$THP_BASELINE"
  ok "THP restored to enabled=${en:-madvise} defrag=${dg:-madvise}, unit removed"
}

# =============================================================================
# SECTION 8b : TIMEZONE
# =============================================================================

tz_current() {
  timedatectl show -p Timezone --value 2>/dev/null \
    || cat /etc/timezone 2>/dev/null \
    || echo unknown
}

detect_timezone() { [[ "$(tz_current)" == "$TIMEZONE" ]]; }

install_timezone() {
  CURRENT_COMPONENT=timezone; state_set timezone installing

  [[ -f "/usr/share/zoneinfo/${TIMEZONE}" ]] \
    || die "Unknown timezone '${TIMEZONE}'. Pick one from: timedatectl list-timezones"

  local before; before=$(tz_current)
  info "Timezone before: ${before}"
  printf 'timezone=%s\n' "$before" > "$TZ_BASELINE"
  chmod 600 "$TZ_BASELINE"

  timedatectl set-timezone "$TIMEZONE" || die "timedatectl set-timezone ${TIMEZONE} failed"
  ok "Timezone set to ${TIMEZONE}"

  # Long-running daemons cached the old zone at start-up, so their log timestamps would
  # stay on the old offset until restarted. MySQL is started later by its own step.
  local u
  for u in rsyslog.service cron.service; do
    unit_exists "$u" && svc_active "$u" \
      && { systemctl restart "$u" 2>/dev/null || true; ok "Restarted ${u}"; }
  done

  info "Timezone after : $(tz_current)   ($(date '+%Y-%m-%d %H:%M:%S %Z %z'))"
  state_set timezone "done"; CURRENT_COMPONENT=""
}

cleanup_timezone() {
  local tz="Etc/UTC"
  [[ -f "$TZ_BASELINE" ]] && tz=$(awk -F= '/^timezone=/{print $2}' "$TZ_BASELINE")
  timedatectl set-timezone "${tz:-Etc/UTC}" 2>/dev/null || true
  rm -f "$TZ_BASELINE"
  ok "Timezone restored to ${tz:-Etc/UTC}"
}

# =============================================================================
# SECTION 9 : SYSTEM TUNING  (apt-daily, snapd)
# =============================================================================

detect_apt_daily() {
  local u
  for u in apt-daily.timer apt-daily-upgrade.timer; do
    unit_exists "$u" && [[ "$(systemctl is-enabled "$u" 2>/dev/null)" == "enabled" ]] && return 1
  done
  return 0
}

install_apt_daily() {
  CURRENT_COMPONENT=apt_daily; state_set apt_daily installing
  local u
  for u in "${APT_DAILY_UNITS[@]}"; do
    unit_exists "$u" || continue
    systemctl stop    "$u" 2>/dev/null || true
    systemctl disable "$u" 2>/dev/null || true
    ok "Stopped and disabled ${u}"
  done
  ok "apt-daily automatic updates disabled (no more dpkg-lock contention)"
  state_set apt_daily "done"; CURRENT_COMPONENT=""
}

cleanup_apt_daily() {
  local u
  for u in apt-daily.timer apt-daily-upgrade.timer; do
    unit_exists "$u" && { systemctl enable --now "$u" 2>/dev/null || true; }
  done
  ok "apt-daily timers re-enabled"
}

detect_snapd() {
  unit_exists snapd.service || return 0
  [[ "$(systemctl is-enabled snapd.service 2>/dev/null)" == "masked" ]] && return 0
  return 1
}

install_snapd_disable() {
  CURRENT_COMPONENT=snapd_disable; state_set snapd_disable installing
  if snap list canonical-livepatch &>/dev/null; then
    warn "canonical-livepatch snap is installed on this host."
    warn "  Masking snapd DISABLES kernel livepatching. Kernel CVEs will need reboots."
  fi
  local u
  for u in "${SNAPD_UNITS[@]}"; do
    unit_exists "$u" || continue
    systemctl stop    "$u" 2>/dev/null || true
    systemctl disable "$u" 2>/dev/null || true
    ok "Stopped and disabled ${u}"
  done
  systemctl mask snapd.service snapd.socket 2>/dev/null || true
  ok "snapd.service and snapd.socket masked"
  state_set snapd_disable "done"; CURRENT_COMPONENT=""
}

cleanup_snapd() {
  systemctl unmask snapd.service snapd.socket 2>/dev/null || true
  local u
  for u in snapd.socket snapd.service; do
    unit_exists "$u" && { systemctl enable --now "$u" 2>/dev/null || true; }
  done
  ok "snapd unmasked and re-enabled"
}

wait_apt_lock() {
  local i=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; do
    ((i++)); [[ $i -gt 60 ]] && { warn "apt lock still held after 5 min, continuing anyway"; return 0; }
    [[ $i -eq 1 ]] && info "Waiting for another apt process to release the dpkg lock ..."
    sleep 5
  done
  return 0
}

# =============================================================================
# SECTION 9b : AZURE FILES SMB  (multiple shares)
# =============================================================================

declare -a SMB_CRED SMB_SHARE SMB_MP SMB_ACCT SMB_HOST SMB_UNC SMB_DEST SMB_STATUS
SMB_COUNT=0

smb_add() {
  # smb_add <credfile> <sharename> <mountpoint>
  local cf="$1" sh="$2" mp="$3" acct
  [[ -f "$cf" ]] || { err "Credential file not found: ${cf}"; return 1; }
  acct=$(awk -F= '/^[[:space:]]*username[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$cf")
  [[ -n "$acct" ]] || { err "No 'username=' line in ${cf}"; return 1; }
  grep -qE '^[[:space:]]*password[[:space:]]*=' "$cf" || { err "No 'password=' line in ${cf}"; return 1; }
  [[ "$mp" == /* ]] || { err "Mount point must be an absolute path: ${mp}"; return 1; }
  local i
  for (( i=0; i<SMB_COUNT; i++ )); do
    [[ "${SMB_MP[$i]}" == "$mp" ]] && { err "Duplicate mount point: ${mp}"; return 1; }
  done
  SMB_CRED+=("$cf"); SMB_SHARE+=("$sh"); SMB_MP+=("$mp"); SMB_ACCT+=("$acct")
  SMB_HOST+=("${acct}.${SMB_ENDPOINT_SUFFIX}")
  SMB_UNC+=("//${acct}.${SMB_ENDPOINT_SUFFIX}/${sh}")
  SMB_DEST+=("${SMB_CRED_DIR}/${acct}.cred")
  SMB_STATUS+=("pending")
  SMB_COUNT=$((SMB_COUNT+1))
}

smb_load_from_config() {
  local entry cf sh mp
  [[ ${#SMB_SHARES[@]} -gt 0 ]] || return 0
  for entry in "${SMB_SHARES[@]}"; do
    IFS='|' read -r cf sh mp <<< "$entry"
    cf="${cf// /}"; sh="${sh// /}"; mp="${mp// /}"
    [[ -n "$cf" && -n "$sh" && -n "$mp" ]]       || die "Bad SMB_SHARES entry (need cred|share|mountpoint): ${entry}"
    smb_add "$cf" "$sh" "$mp" || die "SMB_SHARES entry rejected: ${entry}"
  done
}

smb_prompt() {
  local cf sh mp more
  while true; do
    echo >"$TTY"
    echo "  ${BOLD}SMB share #$((SMB_COUNT+1))${NC}" >"$TTY"
    ask "Path to *.cred file" cf
    ask "Azure file share name" sh
    ask "Mount point (absolute path)" mp
    if smb_add "$cf" "$sh" "$mp"; then
      ok "Added: //$(awk -F= '/username/{gsub(/[[:space:]]/,"",$2);print $2;exit}' "$cf").${SMB_ENDPOINT_SUFFIX}/${sh} -> ${mp}"
    else
      warn "Entry rejected, try again."; continue
    fi
    printf "  Add another share? [y/N]: " >"$TTY"
    read -r more <"$TTY" || true
    [[ "$more" =~ ^[Yy]$ ]] || break
  done
}

install_smb_shares() {
  local i okc=0 failc=0
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cifs-utils     || { err "cifs-utils install failed"; state_set smb_shares failed; return 1; }
  ok "cifs-utils installed"
  install -d -m 0700 -o root -g root "$SMB_CRED_DIR"

  for (( i=0; i<SMB_COUNT; i++ )); do
    echo
    info "[$((i+1))/${SMB_COUNT}] ${SMB_UNC[$i]}  ->  ${SMB_MP[$i]}"

    if port_open "${SMB_HOST[$i]}" 445; then ok "  TCP 445 reachable on ${SMB_HOST[$i]}"
    else warn "  TCP 445 NOT reachable on ${SMB_HOST[$i]} (check storage account firewall / NSG)"
    fi

    install -m 0600 -o root -g root "${SMB_CRED[$i]}" "${SMB_DEST[$i]}"
    ok "  Credentials at ${SMB_DEST[$i]} (0600 root)"

    mkdir -p "${SMB_MP[$i]}"
    local line="${SMB_UNC[$i]} ${SMB_MP[$i]} cifs ${SMB_OPTS},credentials=${SMB_DEST[$i]} 0 0"
    if grep -Fq "${SMB_UNC[$i]} ${SMB_MP[$i]} " /etc/fstab 2>/dev/null; then
      info "  fstab entry already present"
    else
      cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
      echo "$line" >> /etc/fstab
      ok "  fstab entry added"
    fi

    if mount "${SMB_MP[$i]}" 2>&1; then
      ok "  Mounted"
      local probe="${SMB_MP[$i]}/.provision_write_test"
      if echo ok > "$probe" 2>/dev/null && rm -f "$probe" 2>/dev/null; then ok "  Write test passed"
      else warn "  Mounted but not writable"; fi
      SMB_STATUS[$i]="ok"; okc=$((okc+1))
    else
      err "  Mount FAILED. Diagnose: dmesg | grep -i cifs | tail -20"
      SMB_STATUS[$i]="failed"; failc=$((failc+1))
    fi
  done

  echo
  ok "SMB result: ${okc} mounted, ${failc} failed of ${SMB_COUNT}"
  if [[ $failc -gt 0 ]]; then state_set smb_shares failed; return 1; fi
  state_set smb_shares "done"; return 0
}

cleanup_smb_shares() {
  local i
  [[ $SMB_COUNT -gt 0 ]] || { warn "No SMB shares known in this run, nothing to unmount."; return 0; }
  cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
  for (( i=0; i<SMB_COUNT; i++ )); do
    mountpoint -q "${SMB_MP[$i]}" 2>/dev/null &&       { umount "${SMB_MP[$i]}" 2>/dev/null || umount -l "${SMB_MP[$i]}" 2>/dev/null || true; }
    sed -i "\| ${SMB_MP[$i]} cifs |d" /etc/fstab 2>/dev/null || true
    rm -f "${SMB_DEST[$i]}" 2>/dev/null || true
    ok "Removed mount, fstab entry and credentials for ${SMB_MP[$i]}"
  done
}

# =============================================================================
# SECTION 10 : DETECTION
# =============================================================================

detect_mysql() {
  pkg_installed mysql-community-server || have mysqld || unit_exists mysql.service \
    || { [[ -d "$MYSQL_DATADIR" ]] && [[ -n "$(ls -A "$MYSQL_DATADIR" 2>/dev/null)" ]]; }
}
detect_xtrabackup() { pkg_installed "$PXB_PKG" || have xtrabackup; }
detect_node()       { [[ -f "$NODE_BIN" ]] || unit_exists node_exporter.service; }
detect_smb() {
  local i
  [[ $SMB_COUNT -gt 0 ]] || return 1
  for (( i=0; i<SMB_COUNT; i++ )); do
    mountpoint -q "${SMB_MP[$i]}" 2>/dev/null && return 0
    grep -q " ${SMB_MP[$i]} cifs " /etc/fstab 2>/dev/null && return 0
  done
  return 1
}

comp_detect() {
  case "$1" in
    timezone)      detect_timezone ;;
    apt_daily)     detect_apt_daily ;;
    snapd_disable) detect_snapd ;;
    thp_disable)   detect_thp ;;
    mysql)         detect_mysql ;;
    xtrabackup)    detect_xtrabackup ;;
    node_exporter) detect_node ;;
    smb_shares)    detect_smb ;;
    *)             pkg_installed "${COMP_PKG[$1]}" ;;
  esac
}

scan_installed() {
  local c
  for c in "${COMPONENTS[@]}"; do
    SELECTED[$c]=${COMP_DEFAULT[$c]}
    if comp_detect "$c"; then INSTALLED[$c]=1; SELECTED[$c]=0; else INSTALLED[$c]=0; fi
  done
}

any_selected() { local c; for c in "${COMPONENTS[@]}"; do [[ ${SELECTED[$c]} -eq 1 ]] && return 0; done; return 1; }

# =============================================================================
# PHASE 1 : PREFLIGHT
# =============================================================================

PROFILE=""; VM_SIZE=""; RAM_GB=0; VCPU=0

preflight() {
  phase "PHASE 1 : PREFLIGHT"

  [[ $EUID -eq 0 ]] || die "Must run as root:  sudo bash $0"
  ok "Running as root"

  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Another provisioning run is in progress (lock: ${LOCK_FILE})"
  ok "Lock acquired"

  [[ -f /etc/os-release ]] || die "Cannot read /etc/os-release"
  . /etc/os-release
  [[ "${VERSION_CODENAME:-}" == "noble" ]] \
    || die "This script targets Ubuntu 24.04 (noble). Detected: ${PRETTY_NAME:-unknown}"
  ok "OS: ${PRETTY_NAME}"

  [[ "$(dpkg --print-architecture)" == "amd64" ]] \
    || die "amd64 required. Detected: $(dpkg --print-architecture)"
  ok "Architecture: amd64"

  local cmd
  for cmd in curl wget tar dpkg apt-get systemctl timedatectl openssl sha256sum gpg flock \
             awk sed lsblk blkid findmnt mountpoint "mkfs.${DATA_FS_TYPE}"; do
    have "$cmd" || die "Required command missing: ${cmd}"
  done
  ok "All required commands present"

  if [[ ! -d /dev/disk/azure/data/by-lun && ! -d /dev/disk/azure/scsi1 ]]; then
    warn "No Azure LUN symlinks present. If this VM uses NVMe, install azure-vm-utils"
    warn "  for reliable disk identification:  apt-get install -y azure-vm-utils"
  fi

  local tmpavail
  tmpavail=$(df -BG --output=avail /tmp | tail -1 | tr -dc '0-9')
  [[ ${tmpavail} -ge 5 ]] || die "Need at least 5 GB free on /tmp (have ${tmpavail} GB)"
  ok "/tmp has ${tmpavail} GB free"

  RAM_GB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
  VCPU=$(nproc)

  VM_SIZE=$(curl -s --max-time 5 --noproxy '*' -H "Metadata:true" \
    "http://169.254.169.254/metadata/instance/compute/vmSize?api-version=2021-02-01&format=text" 2>/dev/null || true)

  if [[ -n "$VM_SIZE" && -n "${VM_SIZE_PROFILE[$VM_SIZE]:-}" ]]; then
    PROFILE="${VM_SIZE_PROFILE[$VM_SIZE]}"
    ok "Azure IMDS: ${VM_SIZE}  ->  profile ${PROFILE}"
  else
    [[ -n "$VM_SIZE" ]] && warn "VM size '${VM_SIZE}' not in the profile map, using RAM detection" \
                        || warn "Azure IMDS unreachable, using RAM detection"
    if   [[ $RAM_GB -le 5  ]]; then PROFILE=P1
    elif [[ $RAM_GB -le 10 ]]; then
      if [[ $VCPU -ge 4 ]]; then PROFILE=P6; else PROFILE=P2; fi
    elif [[ $RAM_GB -le 20 ]]; then PROFILE=P3
    elif [[ $RAM_GB -le 40 ]]; then PROFILE=P4
    elif [[ $RAM_GB -le 80 ]]; then PROFILE=P5
    else die "RAM ${RAM_GB} GiB is outside every profile."
    fi
    VM_SIZE="${VM_SIZE:-unknown}"
    ok "Fallback: ${VCPU} vCPU / ${RAM_GB} GiB  ->  profile ${PROFILE}"
  fi

  local host
  for host in downloads.mysql.com repo.percona.com github.com; do
    curl -sI --max-time 10 "https://${host}" >/dev/null 2>&1 \
      && ok "Reachable: ${host}" || die "Cannot reach ${host}. Check NSG / DNS / proxy."
  done

  state_init
}

# =============================================================================
# PHASE 2 : MENU
# =============================================================================

failed_components() {
  local c out=()
  for c in "${COMPONENTS[@]}"; do
    [[ "$c" == "mysql" ]] && continue
    local s; s=$(state_get "$c")
    [[ "$s" == "failed" || "$s" == "installing" ]] && out+=("$c")
  done
  echo "${out[@]:-}"
}

render_menu() {
  local i=1 c mark lastgrp="" dash
  clear 2>/dev/null || true
  echo "${BOLD}${CYAN}════════════════════════════════════════════════════════════${NC}"
  echo "${BOLD}  VM Provisioning  |  Ubuntu 24.04 (noble)  |  amd64${NC}"
  echo "${BOLD}${CYAN}════════════════════════════════════════════════════════════${NC}"
  printf "  %-14s %s\n" "VM size:"   "${VM_SIZE}"
  printf "  %-14s %s\n" "Resources:" "${VCPU} vCPU / ${RAM_GB} GiB"
  printf "  %-14s %s  (%s)\n" "Profile:" "${PROFILE}" "${PROFILE_DESC[$PROFILE]}"
  if mountpoint -q "$DATA_MOUNT"; then
    printf "  %-14s %s\n" "${DATA_MOUNT}:" "mounted ($(findmnt -no SOURCE "$DATA_MOUNT"))"
  else
    printf "  %-14s %s\n" "${DATA_MOUNT}:" "not mounted"
  fi
  echo "${BOLD}${CYAN}════════════════════════════════════════════════════════════${NC}"

  for c in "${COMPONENTS[@]}"; do
    if [[ "${COMP_GROUP[$c]}" != "$lastgrp" ]]; then
      lastgrp="${COMP_GROUP[$c]}"
      dash=$(printf '%.0s─' $(seq 1 $((44 - ${#lastgrp}))))
      printf "\n  ${DIM}── %s %s${NC}\n" "$lastgrp" "$dash"
    fi
    if [[ ${INSTALLED[$c]} -eq 1 ]]; then
      printf "  ${DIM}[ ] %2d. %-40s INSTALLED${NC}\n" "$i" "${COMP_LABEL[$c]}"
    else
      [[ ${SELECTED[$c]} -eq 1 ]] && mark="x" || mark=" "
      printf "  [%s] %2d. %s\n" "$mark" "$i" "${COMP_LABEL[$c]}"
    fi
    ((i++))
  done

  echo
  local fc; fc=$(failed_components)
  [[ -n "$fc" ]] && echo "  ${YELLOW}x. Cleanup failed components (${fc// /, })${NC}" && echo
  echo "  ${DIM}Toggle : 3        Range : 6-10       List : 1,4,9${NC}"
  echo "  ${DIM}Groups : t=Tuning  d=Database  m=Monitoring  s=Storage${NC}"
  echo "  ${DIM}         c=CLI      p=Perl/dev${NC}"
  echo "  ${DIM}All: a    None: n    Continue: Enter    Quit: q${NC}"
  echo
} >"$TTY"

toggle_one() {
  local n="$1" c
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  (( n >= 1 && n <= ${#COMPONENTS[@]} )) || return 1
  c="${COMPONENTS[$((n-1))]}"
  [[ ${INSTALLED[$c]} -eq 1 ]] && return 0
  SELECTED[$c]=$(( 1 - SELECTED[$c] ))
  return 0
}

toggle_group() {
  local grp="$1" c any_off=0
  for c in "${COMPONENTS[@]}"; do
    [[ "${COMP_GROUP[$c]}" == "$grp" ]] || continue
    [[ ${INSTALLED[$c]} -eq 1 ]] && continue
    [[ ${SELECTED[$c]} -eq 0 ]] && any_off=1
  done
  for c in "${COMPONENTS[@]}"; do
    [[ "${COMP_GROUP[$c]}" == "$grp" ]] || continue
    [[ ${INSTALLED[$c]} -eq 1 ]] && continue
    SELECTED[$c]=$any_off
  done
}

parse_selection() {
  local input="$1" tok a b i t tokens
  IFS=',' read -ra tokens <<< "$input"
  for tok in "${tokens[@]}"; do
    tok="${tok// /}"; [[ -z "$tok" ]] && continue
    if [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
      (( a <= b )) || { t=$a; a=$b; b=$t; }
      for (( i=a; i<=b; i++ )); do toggle_one "$i" || return 1; done
    elif [[ "$tok" =~ ^[0-9]+$ ]]; then
      toggle_one "$tok" || return 1
    else return 1
    fi
  done
}

RUN_CLEANUP=0

menu() {
  phase "PHASE 2 : COMPONENT SELECTION"
  scan_installed
  local choice c
  while true; do
    render_menu
    printf "  > " >"$TTY"
    read -r choice <"$TTY" || true
    choice="${choice//[[:space:]]/}"
    case "$choice" in
      "" ) any_selected && break
           echo "  ${YELLOW}Nothing selected.${NC}" >"$TTY"; sleep 1 ;;
      a|A ) for c in "${COMPONENTS[@]}"; do [[ ${INSTALLED[$c]} -eq 0 ]] && SELECTED[$c]=1; done ;;
      n|N ) for c in "${COMPONENTS[@]}"; do SELECTED[$c]=0; done ;;
      q|Q ) info "Cancelled by user."; exit 0 ;;
      x|X ) if [[ -n "$(failed_components)" ]]; then RUN_CLEANUP=1; return 0
            else echo "  ${YELLOW}No failed components.${NC}" >"$TTY"; sleep 2; fi ;;
      t|T|d|D|m|M|s|S|c|C|p|P )
            toggle_group "${GROUP_KEY[${choice,,}]}" ;;
      * )   parse_selection "$choice" \
              || { echo "  ${YELLOW}Unrecognised input: ${choice}${NC}" >"$TTY"; sleep 1; } ;;
    esac
  done

  if sel xtrabackup && ! sel mysql && [[ ${INSTALLED[mysql]} -eq 0 ]]; then
    warn "XtraBackup selected without MySQL. XtraBackup 8.4 only supports MySQL 8.4 servers."
  fi
  if sel mysql && ! sel thp_disable && [[ ${INSTALLED[thp_disable]} -eq 0 ]]; then
    warn "MySQL selected without THP disable. Percona recommends THP=never for InnoDB."
  fi
  if sel snapd_disable && snap list canonical-livepatch &>/dev/null; then
    warn "snapd masking selected, but canonical-livepatch is active on this host."
    warn "  Kernel livepatching will stop working. Deselect item 2 if you rely on it."
  fi
}

# =============================================================================
# PHASE 3 : INPUTS AND DISK INSPECTION
# =============================================================================

gather_inputs() {
  phase "PHASE 3 : INPUTS AND DISK INSPECTION"

  if sel mysql; then
    if [[ -z "$DATA_DISK_LUN" ]] && ! mountpoint -q "$DATA_MOUNT"; then
      local _candidates; _candidates=$(data_disk_candidates)
      if [[ -z "$_candidates" ]]; then
        [[ "$DATA_ALLOW_OS_DISK" == "yes" ]] \
          || die "No usable data disk attached and DATA_ALLOW_OS_DISK is not \"yes\"."
        info "No extra data disk attached. ${DATA_MOUNT} will be placed on the OS disk."
      elif [[ -d /dev/disk/azure ]]; then
        list_azure_luns
        if [[ "$DATA_ALLOW_OS_DISK" == "yes" ]]; then
          ask "Data disk LUN (e.g. 0), device path, or 'os' for the OS disk" DATA_DISK_LUN
          [[ "${DATA_DISK_LUN,,}" == "os" ]] && DATA_DISK_LUN=""
        else
          ask "Data disk LUN (e.g. 0) or device path" DATA_DISK_LUN
        fi
      else
        non_azure_disk_menu
      fi
    fi
    inspect_data_disk "$DATA_DISK_LUN"
  else
    info "MySQL not selected. Skipping data disk provisioning."
  fi

  if sel smb_shares; then
    smb_load_from_config
    if [[ $SMB_COUNT -eq 0 ]]; then
      warn "SMB_SHARES is empty. Check the entries are not commented out with '#'."
      confirm "  Enter shares interactively instead?" || die "Fix SMB_SHARES and re-run."
      smb_prompt
    fi
    local i
    for (( i=0; i<SMB_COUNT; i++ )); do
      ok "SMB [$((i+1))] ${SMB_UNC[$i]}  ->  ${SMB_MP[$i]}"
    done
  fi
}

# =============================================================================
# PHASE 4 : DETECTION GATE
# =============================================================================

detect_gate() {
  phase "PHASE 4 : DETECTION"
  local c present=()
  for c in "${COMPONENTS[@]}"; do
    sel "$c" || continue
    comp_detect "$c" && present+=("${COMP_LABEL[$c]}")
  done
  if [[ ${#present[@]} -gt 0 ]]; then
    err "The following SELECTED components are already installed:"
    local x; for x in "${present[@]}"; do err "    - ${x}"; done
    err "This script refuses to overwrite an existing installation."
    exit 1
  fi
  ok "No selected component is present. Safe to proceed."
}

# =============================================================================
# PHASE 5 : PLAN
# =============================================================================

show_plan() {
  phase "PHASE 5 : EXECUTION PLAN"
  echo "  ${BOLD}Components${NC}"
  local c lastgrp=""
  for c in "${COMPONENTS[@]}"; do
    sel "$c" || continue
    if [[ "${COMP_GROUP[$c]}" != "$lastgrp" ]]; then lastgrp="${COMP_GROUP[$c]}"; echo "    ${DIM}${lastgrp}${NC}"; fi
    printf "      %-44s INSTALL\n" "${COMP_LABEL[$c]}"
  done
  echo
  if sel mysql; then
    echo "  ${BOLD}Data disk${NC}"
    if [[ "$DATA_ACTION" == "OSDISK" ]]; then
      printf "    %-32s %s\n" "device" "${DATA_DEVICE} ${YELLOW}(OS disk, no data disk found)${NC}"
      printf "    %-32s %s\n" "action" "${YELLOW}USE OS DISK, no format, no fstab entry${NC}"
      printf "    %-32s %s\n" "path"   "${DATA_MOUNT} (plain directory on /)"
    else
      printf "    %-32s %s\n" "device" "${DATA_DEVICE}"
      if [[ "$DATA_ACTION" == "FORMAT" ]]; then
        printf "    %-32s %s\n" "action" "${RED}FORMAT as ${DATA_FS_TYPE}, ALL CONTENTS LOST${NC}"
        printf "    %-32s %s\n" "mount"  "${DATA_MOUNT} (fstab by UUID, nofail)"
      else
        printf "    %-32s %s\n" "action" "REUSE existing filesystem"
      fi
    fi
    echo
    echo "  ${BOLD}MySQL configuration (profile ${PROFILE}, ${PROFILE_DESC[$PROFILE]})${NC}"
    printf "    %-32s %s\n" "datadir"                      "${MYSQL_DATADIR}"
    printf "    %-32s %s\n" "bind-address"                 "0.0.0.0:${MYSQL_PORT}"
    printf "    %-32s %s\n" "innodb_buffer_pool_size"      "$(p BUFFER_POOL)"
    printf "    %-32s %s\n" "innodb_buffer_pool_instances" "$(p BP_INSTANCES)"
    printf "    %-32s %s\n" "innodb_redo_log_capacity"     "$(p REDO_CAPACITY)"
    printf "    %-32s %s\n" "max_connections"              "$(p MAX_CONNECTIONS)"
    printf "    %-32s %s\n" "sort_buffer_size"             "$(p SORT_BUFFER)"
    printf "    %-32s %s\n" "join_buffer_size"             "$(p JOIN_BUFFER)"
    printf "    %-32s %s\n" "tmp_table_size"               "$(p TMP_TABLE_SIZE)"
    printf "    %-32s %s\n" "table_open_cache"             "$(p TABLE_OPEN_CACHE)"
    printf "    %-32s %s\n" "open_files_limit"             "$(p OPEN_FILES_LIMIT)"
    printf "    %-32s %s\n" "accounts"                     "root@localhost, ${ADMIN_USER}@${ADMIN_HOST}"
    echo
  fi
  if sel timezone || sel apt_daily || sel snapd_disable; then
    echo "  ${BOLD}System tuning${NC}"
    sel timezone      && printf "    %-32s %s\n" "timezone" "$(tz_current) -> ${TIMEZONE}"
    sel apt_daily     && printf "    %-32s %s\n" "apt-daily timers" "stop + disable"
    sel snapd_disable && printf "    %-32s %s\n" "snapd" "${RED}stop + disable + mask (Livepatch OFF)${NC}"
    echo
  fi
  if sel thp_disable; then
    echo "  ${BOLD}Transparent Huge Pages${NC}"
    printf "    %-32s %s\n" "current enabled" "$(thp_current "$THP_SYS_ENABLED")"
    printf "    %-32s %s\n" "current defrag"  "$(thp_current "$THP_SYS_DEFRAG")"
    printf "    %-32s %s\n" "action"          "set both to 'never' + disable-thp.service"
    echo
  fi
  if sel smb_shares; then
    echo "  ${BOLD}Azure Files SMB (${SMB_COUNT} share(s))${NC}"
    local si
    for (( si=0; si<SMB_COUNT; si++ )); do
      printf "    %-2s %-46s -> %s\n" "$((si+1))." "${SMB_UNC[$si]}" "${SMB_MP[$si]}"
      printf "       %-44s    %s\n" "creds: ${SMB_DEST[$si]}" "root:root dir 0770 / file 0660"
    done
    echo
  fi
  echo "  ${YELLOW}Nothing has been written to this system yet.${NC}"
  echo
  confirm "  Proceed?" || { info "Cancelled by user."; exit 0; }
}

# =============================================================================
# PHASE 6 : STORAGE PREPARATION
# =============================================================================

prepare_storage() {
  sel mysql || return 0
  phase "PHASE 6 : STORAGE PREPARATION"
  prepare_data_disk

  local davail where="${DATA_MOUNT}"
  [[ "$DATA_ACTION" == "OSDISK" ]] && where="${DATA_MOUNT} (on the OS disk)"
  davail=$(df -BG --output=avail "$DATA_MOUNT" | tail -1 | tr -dc '0-9')
  [[ ${davail} -ge ${DATA_MIN_GB} ]] \
    || die "Need at least ${DATA_MIN_GB} GB free on ${where} (have ${davail} GB)"
  ok "${where}: ${davail} GB free"

  if [[ -d "$MYSQL_DATADIR" && -n "$(ls -A "$MYSQL_DATADIR" 2>/dev/null)" ]]; then
    die "${MYSQL_DATADIR} exists and is not empty after mounting. Refusing to continue."
  fi
  ok "${MYSQL_DATADIR} is clear"
}

# =============================================================================
# PHASE 7 : DOWNLOAD AND VERIFY
# =============================================================================

fetch_verify() {
  sel mysql || sel node_exporter || { info "No downloads required."; return 0; }
  phase "PHASE 7 : DOWNLOAD AND VERIFY"
  WORKDIR=$(mktemp -d /tmp/provision.XXXXXX); chmod 700 "$WORKDIR"
  info "Work directory: ${WORKDIR}"

  if sel mysql; then
    info "Downloading ${MYSQL_BUNDLE} ..."
    curl -fL --retry 3 --progress-bar -o "${WORKDIR}/${MYSQL_BUNDLE}" "$MYSQL_URL"
    ok "Downloaded MySQL bundle ($(du -h "${WORKDIR}/${MYSQL_BUNDLE}" | cut -f1))"
    verify_mysql_gpg
  fi

  if sel node_exporter; then
    info "Downloading ${NODE_TARBALL} ..."
    curl -fL --retry 3 --progress-bar -o "${WORKDIR}/${NODE_TARBALL}" "$NODE_URL"
    curl -fsL --retry 3 -o "${WORKDIR}/node_sha256sums.txt" "$NODE_SHA_URL"
    ( cd "$WORKDIR" && grep " ${NODE_TARBALL}\$" node_sha256sums.txt | sha256sum -c - ) \
      || die "node_exporter SHA256 mismatch."
    ok "node_exporter SHA256 verified against upstream sha256sums.txt"
  fi
}

verify_mysql_gpg() {
  if [[ "$MYSQL_GPG_REQUIRED" != "yes" ]]; then warn "GPG verification skipped by config."; return 0; fi
  info "Verifying MySQL bundle GPG signature ..."
  export GNUPGHOME="${WORKDIR}/gnupg"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"

  local imported=0 src
  for src in "${MYSQL_KEY_SOURCES[@]}"; do
    if curl -fsL --max-time 20 "$src" -o "${WORKDIR}/mysql_key.asc" 2>/dev/null; then
      gpg --batch --quiet --import "${WORKDIR}/mysql_key.asc" 2>/dev/null || true
    fi
    if gpg --batch --list-keys --with-colons 2>/dev/null | awk -F: '/^fpr:/{print $10}' | grep -qx "$MYSQL_GPG_FPR"; then
      imported=1; info "Imported Oracle build key from ${src}"; break
    fi
  done
  if [[ $imported -eq 0 ]]; then
    info "Trying keyserver ${MYSQL_KEYSERVER} ..."
    gpg --batch --quiet --keyserver "$MYSQL_KEYSERVER" --recv-keys "$MYSQL_GPG_FPR" 2>/dev/null || true
    gpg --batch --list-keys --with-colons 2>/dev/null | awk -F: '/^fpr:/{print $10}' | grep -qx "$MYSQL_GPG_FPR" && imported=1
  fi
  [[ $imported -eq 1 ]] || die "Could not obtain Oracle build key ${MYSQL_GPG_FPR}."
  ok "Oracle build key present, fingerprint matches ${MYSQL_GPG_FPR}"

  curl -fsL --retry 3 -o "${WORKDIR}/${MYSQL_BUNDLE}.asc" "$MYSQL_SIG_URL" \
    || die "Could not download the detached signature from Oracle."

  # Do NOT chain gpg's exit status through the pipe: with `set -o pipefail` active,
  # an expired signing key makes gpg exit non-zero even when the signature itself
  # is genuinely valid ("Good signature ... [expired]"). Capture output separately
  # and judge success from its content instead.
  local gpgout
  gpgout=$(gpg --batch --verify "${WORKDIR}/${MYSQL_BUNDLE}.asc" "${WORKDIR}/${MYSQL_BUNDLE}" 2>&1) || true
  echo "$gpgout" | sed 's/^/    /' >&2

  if echo "$gpgout" | grep -q "Good signature" \
     && echo "$gpgout" | grep -qi "$MYSQL_GPG_FPR"; then
    if echo "$gpgout" | grep -q "\[expired\]"; then
      warn "Oracle's signing key has expired, but the fingerprint is pinned (${MYSQL_GPG_FPR})"
      warn "  and the signature itself is cryptographically valid. Proceeding."
    fi
  else
    die "MySQL bundle signature verification FAILED."
  fi
  ok "MySQL bundle signature verified"
  unset GNUPGHOME
}

# =============================================================================
# PHASE 8 : INSTALLERS
# =============================================================================

install_apt_selected() {
  local c pkgs=() keys=()
  for c in "${COMPONENTS[@]}"; do
    [[ -n "${COMP_PKG[$c]:-}" ]] || continue
    sel "$c" || continue
    pkgs+=("${COMP_PKG[$c]}"); keys+=("$c"); state_set "$c" installing
  done
  [[ ${#pkgs[@]} -gt 0 ]] || return 0
  CURRENT_COMPONENT="${keys[0]}"
  info "Installing apt packages: ${pkgs[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"
  for c in "${keys[@]}"; do state_set "$c" "done"; done
  CURRENT_COMPONENT=""
  ok "Installed ${#pkgs[@]} apt package(s)"
}

write_mysql_conf() {
  mkdir -p "$(dirname "$MYSQL_CONF")"
  cat > "$MYSQL_CONF" <<EOF
# =============================================================
#  MySQL ${MYSQL_VERSION}  |  Ubuntu 24.04  |  Profile: ${PROFILE}
#  Azure size: ${VM_SIZE}  (${PROFILE_DESC[$PROFILE]})
#  Generated by provision.sh on $(date '+%Y-%m-%d %H:%M:%S')
#  DO NOT EDIT BY HAND
# =============================================================

[mysqld]

# -- IDENTITY & PATHS -----------------------------------------
server_id                        = 1
pid-file                         = /var/run/mysqld/mysqld.pid
socket                           = /var/run/mysqld/mysqld.sock
port                             = ${MYSQL_PORT}
datadir                          = ${MYSQL_DATADIR}
bind-address                     = 0.0.0.0

# -- NAMING & SQL BEHAVIOUR -----------------------------------
lower_case_table_names           = 1
sql_mode                         = "STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION"
log_bin_trust_function_creators  = 1
skip-name-resolve
optimizer_switch                 = condition_fanout_filter=off

# -- LOGGING --------------------------------------------------
log-error                        = ${MYSQL_LOGDIR}/error.log
log_error_verbosity              = 2
log_timestamps                   = SYSTEM

# -- BINARY LOG -----------------------------------------------
binlog_expire_logs_seconds       = 172800
max_binlog_size                  = $(p MAX_BINLOG_SIZE)
binlog_row_event_max_size        = 8K

# -- CONNECTIONS ----------------------------------------------
max_connections                  = $(p MAX_CONNECTIONS)
max_connect_errors               = 10000
back_log                         = $(p BACK_LOG)
wait_timeout                     = 600
interactive_timeout              = 600
max_allowed_packet               = 1G

# -- PER-CONNECTION BUFFERS -----------------------------------
sort_buffer_size                 = $(p SORT_BUFFER)
join_buffer_size                 = $(p JOIN_BUFFER)
read_buffer_size                 = $(p READ_BUFFER)
read_rnd_buffer_size             = $(p READ_RND_BUFFER)

# -- TEMPORARY TABLES -----------------------------------------
tmp_table_size                   = $(p TMP_TABLE_SIZE)
max_heap_table_size              = $(p TMP_TABLE_SIZE)

# -- CACHES & FILE HANDLES ------------------------------------
key_buffer_size                  = $(p KEY_BUFFER)
table_open_cache                 = $(p TABLE_OPEN_CACHE)
table_open_cache_instances       = $(p TOC_INSTANCES)
table_definition_cache           = $(p TABLE_DEF_CACHE)
open_files_limit                 = $(p OPEN_FILES_LIMIT)

# -- INNODB: MEMORY -------------------------------------------
innodb_buffer_pool_size          = $(p BUFFER_POOL)
innodb_buffer_pool_instances     = $(p BP_INSTANCES)
innodb_log_buffer_size           = $(p LOG_BUFFER)

# -- INNODB: DURABILITY & REDO --------------------------------
innodb_flush_log_at_trx_commit   = 1
innodb_redo_log_capacity         = $(p REDO_CAPACITY)

# -- INNODB: STORAGE ------------------------------------------
innodb_file_per_table            = 1
innodb_autoextend_increment      = $(p AUTOEXTEND)
innodb_open_files                = $(p INNODB_OPEN_FILES)
innodb_checksum_algorithm        = crc32

# -- INNODB: CONCURRENCY & STATS ------------------------------
innodb_concurrency_tickets       = 5000
innodb_old_blocks_time           = 1000
innodb_stats_on_metadata         = 0
innodb_stats_auto_recalc         = 0

# -- X PROTOCOL -----------------------------------------------
loose_mysqlx_port                = 33060
EOF
  chmod 644 "$MYSQL_CONF"
  ok "Wrote ${MYSQL_CONF} (profile ${PROFILE})"
}

install_mysql() {
  CURRENT_COMPONENT=mysql; state_set mysql installing
  export DEBIAN_FRONTEND=noninteractive

  local throwaway; throwaway=$(genpass)
  debconf-set-selections <<EOF
mysql-community-server mysql-community-server/root-pass password ${throwaway}
mysql-community-server mysql-community-server/re-root-pass password ${throwaway}
mysql-server mysql-server/lowercase-table-names select 1
EOF
  ok "debconf preseeded (lowercase-table-names = 1)"

  local ext="${WORKDIR}/mysql-debs"; mkdir -p "$ext"
  tar -xf "${WORKDIR}/${MYSQL_BUNDLE}" -C "$ext"
  ( shopt -s nullglob; cd "$ext" && rm -f -- *test*.deb *debug*.deb )
  ok "Bundle extracted, test and debug packages removed"

  info "Installing MySQL packages via apt ..."
  ( cd "$ext" && apt-get install -y -qq ./*.deb )
  ok "MySQL ${MYSQL_VERSION} packages installed"

  systemctl stop mysql
  rm -rf "$MYSQL_ORPHAN_DATADIR"
  ok "Stopped MySQL and removed orphan datadir ${MYSQL_ORPHAN_DATADIR}"

  mkdir -p "$MYSQL_DATADIR" "$MYSQL_BACKUPDIR" "$MYSQL_LOGDIR"
  chown mysql:mysql "$MYSQL_DATADIR" "$MYSQL_BACKUPDIR" "$MYSQL_LOGDIR"
  chmod 750 "$MYSQL_DATADIR" "$MYSQL_BACKUPDIR"
  ok "Created ${MYSQL_DATADIR} and ${MYSQL_BACKUPDIR}"

  write_mysql_conf

  mkdir -p "$(dirname "$APPARMOR_LOCAL")"; touch "$APPARMOR_LOCAL"
  if ! grep -q "^${DATA_MOUNT}/ r," "$APPARMOR_LOCAL" 2>/dev/null; then
    cat >> "$APPARMOR_LOCAL" <<EOF

# Added by provision.sh
${DATA_MOUNT}/ r,
${DATA_MOUNT}/** rwk,
EOF
    ok "AppArmor rules appended"
  fi
  if have apparmor_parser && [[ -f /etc/apparmor.d/usr.sbin.mysqld ]]; then
    apparmor_parser -r /etc/apparmor.d/usr.sbin.mysqld 2>/dev/null || warn "apparmor_parser reload returned non-zero"
    ok "AppArmor profile reloaded"
  else
    warn "AppArmor profile for mysqld not found, skipping reload"
  fi

  mkdir -p "$MYSQL_DROPIN_DIR"
  cat > "$MYSQL_DROPIN" <<EOF
[Unit]
RequiresMountsFor=${DATA_MOUNT}

[Service]
LimitNOFILE=$(p OPEN_FILES_LIMIT)
EOF
  chmod 644 "$MYSQL_DROPIN"; systemctl daemon-reload
  ok "systemd drop-in written (RequiresMountsFor=${DATA_MOUNT}, LimitNOFILE=$(p OPEN_FILES_LIMIT))"

  info "Initialising data directory ..."
  mysqld --initialize-insecure --user=mysql --datadir="$MYSQL_DATADIR" \
    || die "mysqld --initialize-insecure failed. See ${MYSQL_LOGDIR}/error.log"
  ok "Data directory initialised at ${MYSQL_DATADIR}"

  systemctl enable --quiet mysql; systemctl start mysql
  local i=0
  until mysqladmin ping --silent 2>/dev/null; do
    ((i++)); [[ $i -gt 30 ]] && die "MySQL did not become ready."
    sleep 2
  done
  ok "MySQL is running and accepting connections"

  local rootpw adminpw; rootpw=$(genpass); adminpw=$(genpass)
  mysql --user=root <<SQL
ALTER USER 'root'@'localhost'
  IDENTIFIED WITH caching_sha2_password BY '${rootpw}';
CREATE USER '${ADMIN_USER}'@'${ADMIN_HOST}'
  IDENTIFIED WITH caching_sha2_password BY '${adminpw}';
GRANT ALL PRIVILEGES ON *.* TO '${ADMIN_USER}'@'${ADMIN_HOST}' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
  ok "Accounts created: root@localhost, ${ADMIN_USER}@${ADMIN_HOST}"

  umask 077
  cat > "$CREDS_FILE" <<EOF
# MySQL credentials generated by provision.sh
# Host: $(hostname -f 2>/dev/null || hostname)   Generated: $(date '+%Y-%m-%d %H:%M:%S')
# KEEP THIS FILE SECRET. Mode 0600, root only.

[root]
user     = root
host     = localhost
password = ${rootpw}

[${ADMIN_USER}]
user     = ${ADMIN_USER}
host     = ${ADMIN_HOST}
password = ${adminpw}
grants   = ALL PRIVILEGES ON *.* WITH GRANT OPTION
note     = Also usable for xtrabackup (BACKUP_ADMIN included in GRANT ALL)
EOF
  chmod 600 "$CREDS_FILE"
  ok "Credentials written to ${CREDS_FILE} (0600)"

  cat > "$LOGROTATE_FILE" <<EOF
${MYSQL_LOGDIR}/error.log {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    create 640 mysql adm
    sharedscripts
    postrotate
        if [ -x /usr/bin/mysqladmin ]; then
            /usr/bin/mysqladmin flush-logs 2>/dev/null || true
        fi
    endscript
}
EOF
  chmod 644 "$LOGROTATE_FILE"
  ok "Log rotation configured"
  state_set mysql "done"; CURRENT_COMPONENT=""
}

install_xtrabackup() {
  CURRENT_COMPONENT=xtrabackup; state_set xtrabackup installing
  export DEBIAN_FRONTEND=noninteractive

  if ! pkg_installed percona-release; then
    info "Adding Percona repository ..."
    local tmp="${WORKDIR:-/tmp}/percona-release.deb"
    curl -fsL --retry 3 -o "$tmp" "$PERCONA_RELEASE_DEB"
    apt-get install -y -qq "$tmp"
    ok "percona-release installed"
  fi

  percona-release enable-only pxb-84-lts release
  apt-get update -qq
  ok "Repository pxb-84-lts enabled"

  info "Installing ${PXB_PKG}=${PXB_VERSION} ..."
  apt-get install -y -qq "${PXB_PKG}=${PXB_VERSION}" \
    || die "Version ${PXB_VERSION} unavailable. Check: apt-cache madison ${PXB_PKG}"

  cat > "$PXB_PIN_FILE" <<EOF
# Written by provision.sh: freeze XtraBackup at the tested version
Package: ${PXB_PKG}
Pin: version ${PXB_VERSION}
Pin-Priority: 1001
EOF
  chmod 644 "$PXB_PIN_FILE"
  ok "Version pinned via ${PXB_PIN_FILE}"
  state_set xtrabackup "done"; CURRENT_COMPONENT=""
}

install_node_exporter() {
  CURRENT_COMPONENT=node_exporter; state_set node_exporter installing

  if ! id "$NODE_USER" &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$NODE_USER"
    ok "Created system user ${NODE_USER}"
  fi

  tar -xzf "${WORKDIR}/${NODE_TARBALL}" -C "$WORKDIR"
  install -o "$NODE_USER" -g "$NODE_USER" -m 0755 \
    "${WORKDIR}/node_exporter-${NODE_VERSION}.linux-${NODE_ARCH}/node_exporter" "$NODE_BIN"
  ok "Installed ${NODE_BIN}"

  cat > "$NODE_SERVICE" <<EOF
[Unit]
Description=Prometheus Node Exporter (v${NODE_VERSION})
Documentation=https://github.com/prometheus/node_exporter
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${NODE_USER}
Group=${NODE_USER}
Restart=on-failure
RestartSec=5s

ExecStart=${NODE_BIN} \\
    --collector.systemd \\
    --collector.processes \\
    --web.listen-address=0.0.0.0:${NODE_PORT}

NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$NODE_SERVICE"
  systemctl daemon-reload
  systemctl enable --quiet node_exporter.service
  systemctl start node_exporter.service
  sleep 2
  svc_active node_exporter.service || die "node_exporter failed to start."
  ok "node_exporter ${NODE_VERSION} running on :${NODE_PORT}"
  state_set node_exporter "done"; CURRENT_COMPONENT=""
}

configure_ufw() {
  if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    sel mysql         && { ufw allow "${MYSQL_PORT}/tcp" >/dev/null; ok "UFW: allowed ${MYSQL_PORT}/tcp"; }
    sel node_exporter && { ufw allow "${NODE_PORT}/tcp"  >/dev/null; ok "UFW: allowed ${NODE_PORT}/tcp"; }
  else
    info "UFW inactive or absent. Azure NSG is your only network gate."
  fi
  return 0
}

run_install() {
  phase "PHASE 8 : INSTALLATION"

  # --- A0: timezone first, so every later log line and file timestamp uses it
  sel timezone      && install_timezone
  # --- A1: kill apt-daily FIRST, before any apt call, to avoid dpkg lock races
  sel apt_daily     && install_apt_daily
  # --- A2: snapd
  sel snapd_disable && install_snapd_disable
  # --- A3: THP, before mysqld ever starts (so no MySQL restart is needed)
  sel thp_disable   && install_thp_disable

  wait_apt_lock
  info "Refreshing apt cache ..."
  apt-get update -qq

  install_apt_selected

  sel mysql         && install_mysql
  sel xtrabackup    && install_xtrabackup
  sel node_exporter && install_node_exporter

  if sel smb_shares; then
    install_smb_shares || warn "One or more SMB mounts failed. Non-fatal; continuing."
  fi

  configure_ufw
  return 0
}

# =============================================================================
# PHASE 9 : VERIFICATION
# =============================================================================

verify_install() {
  phase "PHASE 9 : VERIFICATION"
  local fail=0 pw="" c
  [[ -f "$CREDS_FILE" ]] && pw=$(awk '/^password/{print $3; exit}' "$CREDS_FILE")

  if sel mysql; then
    svc_active mysql && ok "mysql.service active" || { err "mysql.service NOT active"; fail=1; }
    ss -lntp 2>/dev/null | grep -q ":${MYSQL_PORT} " \
      && ok "Listening on :${MYSQL_PORT}" || { err "Not listening on :${MYSQL_PORT}"; fail=1; }
    ok "Server version: $(mysql --user=root --password="$pw" -N -B -e "SELECT VERSION();" 2>/dev/null || echo unreachable)"
    local var out
    for var in datadir lower_case_table_names innodb_buffer_pool_size \
               innodb_redo_log_capacity max_connections innodb_checksum_algorithm; do
      out=$(mysql --user=root --password="$pw" -N -B -e "SHOW VARIABLES LIKE '${var}';" 2>/dev/null | awk '{print $2}')
      printf "    %-32s %s\n" "${var}" "${out:-?}"
    done
    if [[ "$DATA_ACTION" == "OSDISK" ]]; then
      ok "${DATA_MOUNT} source: $(findmnt -no SOURCE -T "$DATA_MOUNT" 2>/dev/null || echo '?') (OS disk, no dedicated data disk)"
    else
      ok "${DATA_MOUNT} source: $(findmnt -no SOURCE "$DATA_MOUNT" 2>/dev/null || echo '?')"
    fi
  fi

  if sel timezone; then
    local tznow; tznow=$(tz_current)
    [[ "$tznow" == "$TIMEZONE" ]] \
      && ok "Timezone: ${tznow}  ($(date '+%Z %z'))" \
      || { err "Timezone is ${tznow}, expected ${TIMEZONE}"; fail=1; }
  fi

  if sel apt_daily; then
    local u st
    for u in apt-daily.timer apt-daily-upgrade.timer; do
      # is-enabled prints the state on stdout AND exits non-zero for
      # disabled/masked units, so capture stdout only, then default it.
      st=$(systemctl is-enabled "$u" 2>/dev/null || true); st="${st:-absent}"
      [[ "$st" == "enabled" ]] && { err "${u} is still enabled"; fail=1; } || ok "${u}: ${st}"
    done
  fi

  if sel snapd_disable; then
    local st
    st=$(systemctl is-enabled snapd.service 2>/dev/null || true); st="${st:-absent}"
    [[ "$st" == "masked" || "$st" == "absent" || "$st" == "disabled" ]] \
      && ok "snapd.service: ${st}" || { err "snapd.service is ${st}"; fail=1; }
  fi

  if sel thp_disable; then
    local e d
    e=$(thp_current "$THP_SYS_ENABLED"); d=$(thp_current "$THP_SYS_DEFRAG")
    [[ "$e" == "never" && "$d" == "never" ]] \
      && ok "THP: enabled=${e} defrag=${d}" || { err "THP not fully disabled (enabled=${e} defrag=${d})"; fail=1; }
    systemctl is-enabled --quiet disable-thp.service \
      && ok "disable-thp.service enabled at boot" || { err "disable-thp.service not enabled"; fail=1; }
    printf "    %-32s %s\n" "AnonHugePages" "$(awk '/AnonHugePages/{print $2, $3}' /proc/meminfo)"
    printf "    %-32s %s\n" "compact_stall" "$(awk '/compact_stall/{print $2}' /proc/vmstat)"
    printf "    %-32s %s\n" "MemAvailable"  "$(awk '/MemAvailable/{print $2, $3}' /proc/meminfo)"
  fi

  if sel xtrabackup; then
    have xtrabackup && ok "$(xtrabackup --version 2>&1 | grep -m1 'xtrabackup version')" \
                    || { err "xtrabackup not on PATH"; fail=1; }
  fi

  if sel node_exporter; then
    svc_active node_exporter.service && ok "node_exporter.service active" \
                                     || { err "node_exporter.service NOT active"; fail=1; }
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${NODE_PORT}/metrics" 2>/dev/null || echo 000)
    [[ "$code" == "200" ]] && ok "node_exporter /metrics returns 200" || warn "node_exporter /metrics returned ${code}"
  fi

  if sel smb_shares; then
    local i
    for (( i=0; i<SMB_COUNT; i++ )); do
      if mountpoint -q "${SMB_MP[$i]}" 2>/dev/null; then
        ok "SMB [$((i+1))] ${SMB_MP[$i]}  ($(df -h --output=avail "${SMB_MP[$i]}" | tail -1 | tr -d ' ') free)"
      else
        warn "SMB [$((i+1))] NOT mounted at ${SMB_MP[$i]} (non-fatal)"
      fi
    done
  fi

  for c in "${COMPONENTS[@]}"; do
    [[ -n "${COMP_PKG[$c]:-}" ]] || continue
    sel "$c" || continue
    pkg_installed "${COMP_PKG[$c]}" && ok "package present: ${COMP_PKG[$c]}" \
                                    || { err "package MISSING: ${COMP_PKG[$c]}"; fail=1; }
  done

  if [[ $fail -ne 0 ]]; then
    err "One or more verification checks failed. Review the lines marked ERROR above."
    err "Installed components are NOT rolled back. Fix the reported items and re-run"
    err "only the affected components."
    exit 1
  fi
}

# =============================================================================
# PHASE 10 : REPORT
# =============================================================================

report() {
  phase "PHASE 10 : SUMMARY"
  echo
  echo "  ${GREEN}${BOLD}INSTALLATION COMPLETE${NC}"
  echo
  printf "  %-24s %s\n" "Host"    "$(hostname -f 2>/dev/null || hostname)"
  printf "  %-24s %s (%s)\n" "VM size" "${VM_SIZE}" "${PROFILE_DESC[$PROFILE]}"
  printf "  %-24s %s\n" "Profile" "${PROFILE}"
  echo
  sel mysql && {
    printf "  %-24s %s\n" "Data disk" "${DATA_DEVICE} -> ${DATA_MOUNT} (${DATA_ACTION})"
    printf "  %-24s %s\n" "MySQL"     "${MYSQL_VERSION}"
    printf "  %-24s %s\n" "  datadir" "${MYSQL_DATADIR}"
    printf "  %-24s %s\n" "  config"  "${MYSQL_CONF}"
    printf "  %-24s %s\n" "  backups" "${MYSQL_BACKUPDIR}"
    printf "  %-24s %s\n" "  listen"  "0.0.0.0:${MYSQL_PORT}"
  }
  sel timezone      && printf "  %-24s %s\n" "Timezone" "${TIMEZONE} ($(date '+%Z %z'))"
  sel apt_daily     && printf "  %-24s %s\n" "apt-daily" "disabled"
  sel snapd_disable && printf "  %-24s %s\n" "snapd" "masked (Livepatch OFF)"
  sel thp_disable   && printf "  %-24s %s\n" "THP" "never (disable-thp.service enabled)"
  sel xtrabackup    && printf "  %-24s %s\n" "XtraBackup" "${PXB_VERSION}"
  sel node_exporter && printf "  %-24s %s\n" "node_exporter" "${NODE_VERSION} on :${NODE_PORT}"
  if sel smb_shares; then
    local si
    printf "  %-24s %s\n" "SMB shares" "${SMB_COUNT}"
    for (( si=0; si<SMB_COUNT; si++ )); do
      printf "  %-24s %s -> %s (%s)\n" "  [$((si+1))]" "${SMB_UNC[$si]}" "${SMB_MP[$si]}" "${SMB_STATUS[$si]}"
    done
  fi
  local c pkgline=""
  for c in "${COMPONENTS[@]}"; do
    [[ -n "${COMP_PKG[$c]:-}" ]] || continue
    sel "$c" && pkgline+="${COMP_PKG[$c]} "
  done
  [[ -n "$pkgline" ]] && printf "  %-24s %s\n" "apt packages" "$pkgline"
  echo
  printf "  %-24s %s\n" "Credentials" "${CREDS_FILE}  (0600)"
  printf "  %-24s %s\n" "Log"         "${LOG_FILE}"
  printf "  %-24s %s\n" "State"       "${STATE_FILE}"
  echo
  echo "  ${YELLOW}${BOLD}POST-INSTALL CHECKLIST${NC}"
  echo "   1. cat ${CREDS_FILE}   and store both passwords in your vault"
  echo "   2. Open 3306 and 9100 to trusted sources only in the Azure NSG"
  echo "   3. Reboot, then: systemctl is-active mysql node_exporter disable-thp"
  echo "      and: systemctl is-enabled apt-daily.timer snapd.service"
  echo "   4. Confirm ${DATA_MOUNT} and any SMB mount return after reboot"
  echo "   5. grep AnonHugePages /proc/meminfo   (should be near zero)"
  echo "   6. Add this host to your Prometheus scrape config"
  echo "   7. Schedule ANALYZE TABLE, innodb_stats_auto_recalc is off"
  echo
}

# =============================================================================
# CLEANUP MODE
# =============================================================================

run_cleanup() {
  phase "CLEANUP : PURGE FAILED COMPONENTS"
  local fc; fc=$(failed_components)
  [[ -n "$fc" ]] || { info "Nothing to clean up."; exit 0; }

  echo "  The following will be PURGED:" >"$TTY"
  local c
  for c in $fc; do echo "    - ${COMP_LABEL[$c]}  (state: $(state_get "$c"))" >"$TTY"; done
  echo >"$TTY"
  echo "  ${GREEN}MySQL and the data disk are never touched by cleanup.${NC}" >"$TTY"
  echo >"$TTY"
  local reply
  printf "  Type 'yes' to proceed: " >"$TTY"
  read -r reply <"$TTY"
  [[ "$reply" == "yes" ]] || { info "Cancelled."; exit 0; }

  export DEBIAN_FRONTEND=noninteractive
  for c in $fc; do
    case "$c" in
      xtrabackup)
        apt-get purge -y -qq "$PXB_PKG" 2>/dev/null || true
        rm -f "$PXB_PIN_FILE"; ok "Purged ${PXB_PKG} and removed pin" ;;
      node_exporter)
        systemctl disable --now node_exporter.service 2>/dev/null || true
        rm -f "$NODE_SERVICE" "$NODE_BIN"; systemctl daemon-reload
        id "$NODE_USER" &>/dev/null && userdel "$NODE_USER" 2>/dev/null || true
        ok "Removed node_exporter" ;;
      thp_disable)
        cleanup_thp ;;
      timezone)
        cleanup_timezone ;;
      apt_daily)
        cleanup_apt_daily ;;
      snapd_disable)
        cleanup_snapd ;;
      smb_shares)
        smb_load_from_config
        [[ $SMB_COUNT -gt 0 ]] || smb_prompt
        cleanup_smb_shares ;;
      *)
        if [[ -n "${COMP_PKG[$c]:-}" ]]; then
          apt-get purge -y -qq "${COMP_PKG[$c]}" 2>/dev/null || true
          ok "Purged ${COMP_PKG[$c]}"
        fi ;;
    esac
    state_set "$c" pending
  done
  apt-get autoremove -y -qq 2>/dev/null || true
  ok "Cleanup complete. Re-run this script to reinstall."
  exit 0
}

# =============================================================================
# MAIN
# =============================================================================

main() {
  echo
  echo "${BOLD}${CYAN}  provision.sh v3  |  started $(date '+%Y-%m-%d %H:%M:%S')${NC}"
  preflight
  menu
  [[ $RUN_CLEANUP -eq 1 ]] && run_cleanup
  gather_inputs
  detect_gate
  show_plan
  prepare_storage
  fetch_verify
  run_install
  verify_install
  report
}

main "$@"