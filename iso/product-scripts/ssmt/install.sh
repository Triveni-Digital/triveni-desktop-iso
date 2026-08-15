#!/bin/bash

trap 'exit 0' EXIT
set -e

readonly BACKUP_FILE="/var/triveni/install/backup/ssmt/ssmt_backup.tar.gz"

readonly ROOT_DIR="/var/triveni/install"

export DEBIAN_FRONTEND=noninteractive

echo "**********************************************************************"
echo "Running install-ssmt.sh (installing SSMT from $ROOT_DIR/ssmt_*.deb if present)"

# Check if the script is running as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run this script as root."
    exit 1
fi

# Install only the last matching local SSMT package in ROOT_DIR, if /opt/ssmt exists.
shopt -s nullglob
ssmt_debs=("$ROOT_DIR"/ssmt_*.deb)
if [ "${#ssmt_debs[@]}" -gt 0 ]; then

    # SSMT requires Java 8 specifically; do not fall back to a newer JRE.
    if ! apt install -y --no-download openjdk-8-jre; then
        echo "WARNING: openjdk-8-jre installation failed (unmet dependencies); continuing so SSMT can still be installed"
    fi
    if [ -x /usr/lib/jvm/java-8-openjdk-amd64/jre/bin/java ]; then
        update-alternatives --set java /usr/lib/jvm/java-8-openjdk-amd64/jre/bin/java || true
    else
        echo "WARNING: Java 8 runtime not present at /usr/lib/jvm/java-8-openjdk-amd64; SSMT may not start"
    fi

    latest_ssmt="${ssmt_debs[$(( ${#ssmt_debs[@]} - 1 ))]}"
    echo "Found SSMT debs in ${ROOT_DIR}: ${ssmt_debs[*]}. Installing latest: ${latest_ssmt}"
    if ! dpkg -i "$latest_ssmt"; then
        echo "WARNING: dpkg reported dependency issues for $latest_ssmt; attempting to resolve"
        apt --fix-broken install -y --no-download || true
    fi
    chown 1000:1000 /opt/ssmt || true

    # Configure MT web UI on port 8080 if /opt/ssxm exists
    if [ -d "/opt/ssxm" ]; then
        echo "configuring MT web UI on port 8080"
        echo "com.triveni.jnlp.port=8080" > /opt/ssmt/server/server.properties
        chmod a+r /opt/ssmt/server/server.properties
    fi

    # Restore SSMT configuration and license from backup if present
    if [ -f "$BACKUP_FILE" ]; then
        echo "Restoring ssmt configuration and license to target system..."
        mkdir -p /opt/ssmt
        
        # Extract archive directly into /opt/ssmt (removed the /target prefix)
        tar -xzf "$BACKUP_FILE" -C /opt/ssmt/
        chown -R 1000:1000 /opt/ssmt
        
        # Clean up the temporary backup archive inside the target
        # rm -f /tmp/ssmt_backup.tar.gz
    else
        echo "WARNING: Backup archive was not found at $BACKUP_FILE. Proceeding with clean install setup."
    fi
else
    echo "Skipping SSMT install: no matching SSMT deb in ${ROOT_DIR}."
fi

exit 0
