#!/bin/bash

# Runs last in the in-target stage. The triveni-drivers postinst calls
# configure_ubuntu_sources, which replaces sources.list with archive.ubuntu.com and
# leaves a machine that has no network pointing at repositories it cannot reach.

set -uo pipefail

export LC_ALL=C

readonly APT_BACKUP_DIR="/var/triveni/apt-backup"
readonly REPO_DEST="/var/triveni/packages"
readonly SOURCES_FILE="/etc/apt/sources.list.d/triveni-offline.list"
readonly EMPTY_SOURCEPARTS_DIR="/var/lib/triveni/empty-sources.list.d"

warn() { echo "[apt-restore][warn] $*" >&2; }
log() { echo "[apt-restore] $*"; }

echo "**********************************************************************"
echo "Running os/90-in-target-late-commands.sh (restoring apt configuration)"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "This script must run as root" >&2
    exit 1
fi

if [ -d "$APT_BACKUP_DIR" ]; then
    if [ -f "$APT_BACKUP_DIR/sources.list" ]; then
        cp -a "$APT_BACKUP_DIR/sources.list" /etc/apt/sources.list ||
            warn "Could not restore /etc/apt/sources.list"
    fi
    if [ -d "$APT_BACKUP_DIR/sources.list.d" ]; then
        rm -rf /etc/apt/sources.list.d
        cp -a "$APT_BACKUP_DIR/sources.list.d" /etc/apt/sources.list.d ||
            warn "Could not restore /etc/apt/sources.list.d"
    fi
    log "Restored apt configuration from $APT_BACKUP_DIR"
else
    warn "No apt backup at $APT_BACKUP_DIR; leaving current configuration alone"
fi

# Re-assert the offline repo even if the backup was missing or incomplete.
if [ -f "$REPO_DEST/Packages" ]; then
    mkdir -p /etc/apt/sources.list.d
    printf 'deb [trusted=yes] file:%s ./\n' "$REPO_DEST" > "$SOURCES_FILE"
    log "Offline repository re-registered at $REPO_DEST"
fi

# google-chrome and the drivers installer both add repos that stall without network.
rm -f /etc/apt/sources.list.d/google-chrome.list \
    /etc/apt/sources.list.d/google-chrome.sources \
    "$EMPTY_SOURCEPARTS_DIR/google-chrome.list" \
    "$EMPTY_SOURCEPARTS_DIR/google-chrome.sources"

exit 0
