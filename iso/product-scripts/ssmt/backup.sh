#!/bin/bash

readonly BACKUP_FILE="/tmp/backup/ssmt_backup.tar.gz"

# This script runs in early-commands to back up critical files before the drive is wiped.
echo "Starting SSMT backup process..."

TAR_CMD=()
if command -v tar >/dev/null 2>&1; then
    TAR_CMD=(tar)
elif command -v busybox >/dev/null 2>&1; then
    TAR_CMD=(busybox tar)
else
    echo "WARNING: No tar implementation found in installer environment; cannot create SSMT backup archive."
fi

mkdir -p /tmp/old_root
mkdir -p /tmp/backup
mkdir -p "$(dirname "$BACKUP_FILE")"

# Flag to track if we successfully found and backed up the files
BACKUP_SUCCESS=false

# Scan discovered partitions to handle varying device names (sda, vda, nvme, etc.)
parts_to_scan=()
if command -v lsblk >/dev/null 2>&1; then
    while IFS= read -r part; do
        [ -n "$part" ] || continue
        parts_to_scan+=("$part")
    done < <(lsblk -rpn -o PATH,TYPE | awk '$2=="part" {print $1}')
else
    # Fallback list if lsblk is unavailable.
    parts_to_scan=(/dev/sda2 /dev/sdb2 /dev/vda2 /dev/nvme0n1p2)
fi

if [ "${#parts_to_scan[@]}" -eq 0 ]; then
    echo "WARNING: No partitions discovered for SSMT backup scan."
fi

for part in "${parts_to_scan[@]}"; do
    if mount "$part" /tmp/old_root 2>/dev/null; then
        backup_root="/tmp/old_root/opt/ssmt"
        backup_items=()

        if [ -d "$backup_root" ]; then
            if [ -f "$backup_root/.license" ]; then
                backup_items+=(".license")
            fi
            if [ -d "$backup_root/config" ]; then
                backup_items+=("config")
            fi
        fi

        if [ "${#backup_items[@]}" -gt 0 ]; then
            echo "SSMT backup source found on $part. Attempting to create backup archive..."

            if [ "${#TAR_CMD[@]}" -eq 0 ]; then
                echo "WARNING: Skipping archive creation because tar is unavailable."
            elif "${TAR_CMD[@]}" -czf "$BACKUP_FILE" -C "$backup_root" "${backup_items[@]}" 2>&1; then
                echo "Backup archive created successfully."
                BACKUP_SUCCESS=true
            else
                echo "WARNING: Tar command encountered an error, but continuing installation anyway."
            fi

            # Lazy unmount just in case the device is busy, ensuring we don't lock the drive
            umount -l /tmp/old_root || true
            break
        fi

        umount -l /tmp/old_root || true
    fi
done

if [ "$BACKUP_SUCCESS" = false ]; then
    echo "WARNING: Could not locate or backup SSMT configuration files. Proceeding with clean install."
fi

# CRITICAL: Force an explicit exit 0 so the Ubuntu installer always continues
exit 0