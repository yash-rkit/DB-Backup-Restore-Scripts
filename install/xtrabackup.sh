#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  Percona XtraBackup 8.4 Installer (Dynamic Arch + OS)
#  Supports Ubuntu 20.04 / 22.04 / 24.04 (arm64, amd64)
# ============================================================

# --- Detect Ubuntu codename ---
CODENAME=$(lsb_release -sc)

# --- Detect architecture (e.g., amd64, arm64) ---
ARCH=$(dpkg --print-architecture)

echo "Detected Ubuntu release: $CODENAME"
echo "Detected architecture: $ARCH"

# --- Validate supported architectures ---
if [[ "$ARCH" != "arm64" && "$ARCH" != "amd64" ]]; then
    echo "Unsupported architecture: $ARCH"
    echo "Supported architectures: arm64, amd64"
    exit 1
fi

# --- Define version variables ---
# Current as of Jan 2026 per docs.percona.com/percona-xtrabackup/8.4/release-notes/
# Check https://docs.percona.com/percona-xtrabackup/8.4/release-notes/release-notes.html for newer releases
VERSION="8.4.0-5"
PACKAGE_VER="8.4.0-5-1"

# --- Map Ubuntu codename ---
case "$CODENAME" in
  focal|jammy|noble)
    ;;
  *)
    echo "Unsupported Ubuntu release: $CODENAME"
    echo "Supported versions: 20.04 (focal), 22.04 (jammy), 24.04 (noble)"
    exit 1
    ;;
esac

# --- Map Percona's actual architecture folder names ---
# Percona uses 'aarch64' for arm64, and 'x86_64' for amd64
if [[ "$ARCH" == "arm64" ]]; then
    PERCONA_ARCH="aarch64"
elif [[ "$ARCH" == "amd64" ]]; then
    PERCONA_ARCH="x86_64"
fi

# --- Construct base URL dynamically ---
BASE_URL="https://downloads.percona.com/downloads/Percona-XtraBackup-8.4/Percona-XtraBackup-${VERSION}/binary/debian/${CODENAME}/${PERCONA_ARCH}"

# --- Construct package name ---
PKG_FILE="percona-xtrabackup-84_${PACKAGE_VER}.${CODENAME}_${ARCH}.deb"
FULL_URL="${BASE_URL}/${PKG_FILE}"

echo "Download URL: $FULL_URL"
echo "Downloading Percona XtraBackup package..."
curl -fLO "$FULL_URL"

# --- Refresh apt cache (needed so apt-get -f install below can resolve deps) ---
echo "Refreshing apt cache..."
sudo apt-get update -qq

# --- Install package (dpkg first, then let apt resolve dependencies) ---
# Official Percona method: dpkg -i, then apt-get install -f to pull in
# whatever's missing (libmysqlclient, libssl, libcurl, libev, libgcrypt, zlib, etc.)
echo "Installing Percona XtraBackup..."
sudo dpkg -i "$PKG_FILE" || sudo apt-get install -f -y

# --- Verify installation ---
echo
echo "Installation complete!"
if command -v xtrabackup >/dev/null 2>&1; then
    xtrabackup --version
else
    echo "xtrabackup command not found. Check logs above."
    exit 1
fi

# --- Cleanup ---
rm -f "$PKG_FILE"

# --- Success message ---
echo
echo "Percona XtraBackup ${VERSION} successfully installed on Ubuntu ${CODENAME} (${ARCH})"
echo "You can now use the 'xtrabackup' command."