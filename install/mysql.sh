!/bin/bash
=============================================================================
setup_mysql_single.sh
ONE-TIME MySQL 8.4.4 Installation & Configuration Script
Ubuntu 22.04 | Single Instance | Data Disk: /Data
=============================================================================

# set -e  # Exit on any error

─────────────────────────────────────────────
CONFIGURATION — Edit these if needed
─────────────────────────────────────────────
# BUNDLE_PATH="/home/vm/mysql-server_8.4.4-1ubuntu22.04_amd64.deb-bundle.tar"
# EXTRACT_DIR="/home/vm/mysql-debs"
# MYSQL_CONF="/etc/mysql/mysql.conf.d/mysqld.cnf"
# DATADIR="/Data/mysql"
# ROOT_PASSWORD=""   # <-- Default password (you will be told to change this)
# APPARMOR_LOCAL="/etc/apparmor.d/local/usr.sbin.mysqld"

─────────────────────────────────────────────
COLOR HELPERS
─────────────────────────────────────────────
# RED='\033[0;31m'
# GREEN='\033[0;32m'
# YELLOW='\033[1;33m'
# CYAN='\033[0;36m'
# BOLD='\033[1m'
# NC='\033[0m'

# info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
# success() { echo -e "${GREEN}[OK]${NC} $1"; }
# warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
# error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
# section() { echo -e "\n${BOLD}${CYAN}════════════════════════════════════════${NC}"; echo -e "${BOLD}${CYAN} $1${NC}"; echo -e "${BOLD}${CYAN}════════════════════════════════════════${NC}"; }

─────────────────────────────────────────────
MUST RUN AS ROOT
─────────────────────────────────────────────
# if [ "$EUID" -ne 0 ]; then
  # error "Please run as root: sudo bash setup_mysql_single.sh"
# fi

=============================================================================
STEP 1: Extract .tar bundle
=============================================================================
# section "STEP 1: Extracting MySQL .deb bundle"

# if [ ! -f "$BUNDLE_PATH" ]; then
  # error "Bundle not found at: $BUNDLE_PATH"
# fi

# mkdir -p "$EXTRACT_DIR"
# tar -xf "$BUNDLE_PATH" -C "$EXTRACT_DIR"
# success "Extracted to $EXTRACT_DIR"
# info "Files found:"
# ls "$EXTRACT_DIR"/*.deb 2>/dev/null | xargs -I{} basename {}

=============================================================================
STEP 2: Install dependencies
=============================================================================
# section "STEP 2: Installing dependencies"

# info "Updating apt cache..."
# apt-get update -qq

# info "Installing libaio1 and libmecab2..."
# apt-get install -y libaio1 libmecab2 libicu70 || apt-get install -y libaio1 libicu70
# success "Dependencies installed"

=============================================================================
STEP 3: Install .deb packages in correct order
=============================================================================
# section "STEP 3: Installing MySQL 8.4.4 packages"

# cd "$EXTRACT_DIR"

# DEB_ORDER=(
  # "mysql-common"
  # "mysql-community-client-plugins"
  # "mysql-community-client-core"
  # "mysql-community-client"
  # "mysql-client"
  # "mysql-community-server-core"
  # "mysql-community-server"
  # "mysql-server"
# )

# for pkg in "${DEB_ORDER[@]}"; do
  # DEB_FILE=$(ls ${pkg}_*.deb 2>/dev/null | head -1)
  # if [ -n "$DEB_FILE" ]; then
    # info "Installing $DEB_FILE ..."
    # DEBIAN_FRONTEND=noninteractive dpkg -i "$DEB_FILE" || true
  # else
    # warn "Package not found for: $pkg (may be combined in another deb, continuing)"
  # fi
# done

# info "Fixing any dependency issues..."
# apt-get install -f -y -qq
# success "MySQL 8.4.4 packages installed"

=============================================================================
STEP 4: Stop MySQL immediately (before any initialization)
=============================================================================
# section "STEP 4: Stopping MySQL before configuration"

# systemctl stop mysql 2>/dev/null || true
# sleep 2
# success "MySQL stopped"

=============================================================================
STEP 5: Create single data directory
=============================================================================
# section "STEP 5: Creating data directory"

# mkdir -p "$DATADIR"
# success "Created: $DATADIR"

=============================================================================
STEP 6: Configure mysqld.cnf BEFORE initialization
=============================================================================
# section "STEP 6: Configuring mysqld.cnf"

# info "Backing up original config..."
# cp "$MYSQL_CONF" "${MYSQL_CONF}.bak.$(date +%Y%m%d%H%M%S)"

# cat > "$MYSQL_CONF" << EOF

MySQL 8.4.4 Configuration
Managed by setup_mysql_single.sh
Single instance — datadir: $DATADIR


# [mysqld]
# user            = mysql
# pid-file        = /var/run/mysqld/mysqld.pid
# socket          = /var/run/mysqld/mysqld.sock
# port            = 3306

── DATA DIRECTORY ──
# datadir         = ${DATADIR}

── CRITICAL: Must be set BEFORE first initialization ──
# lower_case_table_names = 1

── LOGGING ──
# log_error       = /var/log/mysql/error.log
# general_log     = 0
# slow_query_log  = 0

── PERFORMANCE ──
# innodb_buffer_pool_size = 1G
# max_connections         = 200
# log_bin_trust_function_creators = 1
# bind-address = 0.0.0.0
# EOF

# success "mysqld.cnf written with:"
# info "  datadir                = $DATADIR"
# info "  lower_case_table_names = 1"

=============================================================================
STEP 7: Fix AppArmor to allow /Data/* paths
=============================================================================
# section "STEP 7: Configuring AppArmor"

# if [ -f "$APPARMOR_LOCAL" ]; then
  # info "AppArmor local file exists, appending /Data/* rules..."
# else
  # info "Creating AppArmor local override file..."
  # mkdir -p "$(dirname $APPARMOR_LOCAL)"
  # touch "$APPARMOR_LOCAL"
# fi

# if ! grep -q "/Data/" "$APPARMOR_LOCAL" 2>/dev/null; then
  # cat >> "$APPARMOR_LOCAL" << EOF

Allow MySQL to use /Data/* as data directory
# /Data/ r,
# /Data/** rwk,
# EOF
  # info "AppArmor rules added"
# else
  # info "AppArmor rules already present, skipping"
# fi

# if command -v apparmor_parser &>/dev/null; then
  # apparmor_parser -r /etc/apparmor.d/usr.sbin.mysqld 2>/dev/null || true
  # success "AppArmor reloaded"
# else
  # warn "AppArmor not found — skipping (may be disabled on this VM)"
# fi

=============================================================================
STEP 8: Set ownership on data directory
=============================================================================
# section "STEP 8: Setting ownership"

# chown -R mysql:mysql "$DATADIR"
# chmod 750 "$DATADIR"
# success "Ownership set: mysql:mysql on $DATADIR"

=============================================================================
STEP 9: Initialize MySQL data directory
=============================================================================
# section "STEP 9: Initializing MySQL data directory"

# info "Running mysqld --initialize-insecure (no root password at init stage)..."
# mysqld --initialize-insecure --user=mysql --datadir="$DATADIR" 2>&1 | tee /tmp/mysql_init.log

# if [ ${PIPESTATUS[0]} -ne 0 ]; then
  # error "MySQL initialization failed. Check /tmp/mysql_init.log"
# fi
# success "Data directory initialized at $DATADIR"

=============================================================================
STEP 10: Start MySQL and set root password
=============================================================================
# section "STEP 10: Starting MySQL and setting root password"

# systemctl start mysql
# sleep 3

# if ! systemctl is-active --quiet mysql; then
  # error "MySQL failed to start. Check: journalctl -xe | grep mysql"
# fi
# success "MySQL started"

# info "Setting root password..."
# mysql -u root --connect-expired-password -e \
  # "ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PASSWORD}'; FLUSH PRIVILEGES;" 2>/dev/null

# success "Root password set"

=============================================================================
STEP 11: Verify installation
=============================================================================
# section "STEP 11: Verification"

# VERSION=$(mysql -u root -p"${ROOT_PASSWORD}" -e "SELECT VERSION();" 2>/dev/null | grep -v VERSION || echo "Could not connect")
# LCTN=$(mysql -u root -p"${ROOT_PASSWORD}" -e "SHOW VARIABLES LIKE 'lower_case_table_names';" 2>/dev/null | grep lower || echo "Could not fetch")
# DATADIR_CHECK=$(mysql -u root -p"${ROOT_PASSWORD}" -e "SHOW VARIABLES LIKE 'datadir';" 2>/dev/null | grep datadir || echo "Could not fetch")

# echo ""
# echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
# echo -e "${GREEN}  MySQL Installation Successful${NC}"
# echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
# echo -e "  Version           : $VERSION"
# echo -e "  lower_case_tables : $LCTN"
# echo -e "  Data Directory    : $DATADIR_CHECK"
# echo ""
# echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
# echo -e "${YELLOW}  !! IMPORTANT — ROOT PASSWORD !!${NC}"
# echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
# echo -e "  Current Password  : ${BOLD}${ROOT_PASSWORD}${NC}"
# echo -e "  ${RED}Change it now with:${NC}"
# echo -e "  ${BOLD}mysql -u root -p'${ROOT_PASSWORD}' -e \"ALTER USER 'root'@'localhost' IDENTIFIED BY 'YOUR_NEW_PASSWORD'; FLUSH PRIVILEGES;\"${NC}"
# echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
# echo ""