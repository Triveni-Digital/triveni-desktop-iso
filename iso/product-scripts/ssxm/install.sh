#!/bin/bash

trap 'exit 0' EXIT
set -e

readonly BACKUP_FILE="/var/triveni/install/backup/ssxm/ssxm_backup.tar.gz"

readonly ROOT_DIR="/var/triveni/install"

export DEBIAN_FRONTEND=noninteractive

echo "**********************************************************************"
echo "Running install-ssxm.sh (installing SSXM from /var/triveni/install/ssxm_*.deb if present)"

# Check if the script is running as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run this script as root."
    exit 1
fi

# Install only the last matching local SSXM package in ROOT_DIR, if /opt/ssxm exists.
shopt -s nullglob
ssxm_debs=("$ROOT_DIR"/ssxm_*.deb)
if [ "${#ssxm_debs[@]}" -gt 0 ]; then
    latest_ssxm="${ssxm_debs[$(( ${#ssxm_debs[@]} - 1 ))]}"
    echo "Found SSXM debs in ${ROOT_DIR}: ${ssxm_debs[*]}. Installing latest: ${latest_ssxm}"
    if ! dpkg -i "$latest_ssxm"; then
        echo "WARNING: dpkg reported dependency issues for $latest_ssxm; attempting to resolve"
        apt --fix-broken install -y --no-download || true
    fi

    # Restore SSXM configuration and license from backup if present
    if [ -f "$BACKUP_FILE" ]; then
        echo "Restoring ssxm configuration and license to target system..."
        mkdir -p /var/triveni/ssxm
        
        # Extract archive directly into /var/triveni/ssxm (removed the /target prefix)
        tar -xzf "$BACKUP_FILE" -C /var/triveni/ssxm
        chown -R 1000:1000 /var/triveni/ssxm
        
        # Clean up the temporary backup archive inside the target
        # rm -f /tmp/ssmt_backup.tar.gz
    else
        echo "WARNING: Backup archive was not found at $BACKUP_FILE. Proceeding with clean install setup."
    fi

else
    echo "Skipping SSXM install: no matching SSXM deb in ${ROOT_DIR}."
fi

exit 0
