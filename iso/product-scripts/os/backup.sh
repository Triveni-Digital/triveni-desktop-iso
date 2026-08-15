#!/bin/bash

set -euo pipefail

readonly BACKUP_ROOT="/tmp/backup/os"
readonly MANIFEST_FILE="$BACKUP_ROOT/restore-items.tsv"

echo "**********************************************************************"
echo "Running os-backup.sh (backing up OS users/groups/network configuration)"

mkdir -p "$BACKUP_ROOT"
: > "$MANIFEST_FILE"

append_manifest() {
	local kind="$1"
	local source_rel="$2"
	local target_path="$3"
	local label="$4"

	printf '%s|%s|%s|%s\n' "$kind" "$source_rel" "$target_path" "$label" >> "$MANIFEST_FILE"
}

backup_file() {
	local source_path="$1"
	local source_rel="$2"
	local target_path="$3"
	local label="$4"

	if [ -f "$source_path" ]; then
		mkdir -p "$(dirname "$BACKUP_ROOT/$source_rel")"
		cp -a "$source_path" "$BACKUP_ROOT/$source_rel"
		append_manifest "file" "$source_rel" "$target_path" "$label"
		echo "Saved file: $source_path"
	else
		echo "Skipping missing file: $source_path"
	fi
}

backup_dir() {
	local source_path="$1"
	local source_rel="$2"
	local target_path="$3"
	local label="$4"

	if [ -d "$source_path" ]; then
		mkdir -p "$BACKUP_ROOT/$source_rel"
		cp -a "$source_path"/. "$BACKUP_ROOT/$source_rel"/
		append_manifest "dir" "$source_rel" "$target_path" "$label"
		echo "Saved directory: $source_path"
	else
		echo "Skipping missing directory: $source_path"
	fi
}

# Network configuration
backup_dir /etc/netplan etc/netplan /etc/netplan "Netplan configuration"
backup_dir /etc/NetworkManager etc/NetworkManager /etc/NetworkManager "NetworkManager configuration"
backup_dir /etc/systemd/network etc/systemd/network /etc/systemd/network "systemd-networkd configuration"
backup_dir /etc/systemd/resolved.conf.d etc/systemd/resolved.conf.d /etc/systemd/resolved.conf.d "systemd-resolved drop-ins"
backup_dir /etc/network/interfaces.d etc/network/interfaces.d /etc/network/interfaces.d "ifupdown interfaces.d"
backup_dir /etc/wpa_supplicant etc/wpa_supplicant /etc/wpa_supplicant "wpa_supplicant configuration"

backup_file /etc/NetworkManager/NetworkManager.conf etc/NetworkManager/NetworkManager.conf /etc/NetworkManager/NetworkManager.conf "NetworkManager main config"
backup_file /etc/network/interfaces etc/network/interfaces /etc/network/interfaces "ifupdown interfaces file"
backup_file /etc/systemd/resolved.conf etc/systemd/resolved.conf /etc/systemd/resolved.conf "systemd-resolved main config"
backup_file /etc/hostname etc/hostname /etc/hostname "Hostname"
backup_file /etc/hosts etc/hosts /etc/hosts "Hosts file"
backup_file /etc/resolv.conf etc/resolv.conf /etc/resolv.conf "Resolver configuration"
backup_file /etc/udev/rules.d/70-persistent-net.rules etc/udev/rules.d/70-persistent-net.rules /etc/udev/rules.d/70-persistent-net.rules "Persistent net udev rules"

# Users and groups
backup_file /etc/passwd etc/passwd /etc/passwd "User accounts (passwd)"
backup_file /etc/shadow etc/shadow /etc/shadow "User passwords (shadow)"
backup_file /etc/group etc/group /etc/group "Group definitions"
backup_file /etc/gshadow etc/gshadow /etc/gshadow "Group passwords (gshadow)"
backup_file /etc/subuid etc/subuid /etc/subuid "Subuid mappings"
backup_file /etc/subgid etc/subgid /etc/subgid "Subgid mappings"

cp -a /cdrom/scripts/product-scripts/os/restore.sh "$BACKUP_ROOT/restore.sh"
chmod 0755 "$BACKUP_ROOT/restore.sh"

echo "OS backup bundle created at $BACKUP_ROOT"

exit 0
