#!/bin/bash

set -euo pipefail

#!/bin/bash

set -euo pipefail

readonly BACKUP_ROOT="/var/triveni/install/backup/os"
readonly MANIFEST_FILE="$BACKUP_ROOT/restore-items.tsv"

echo "**********************************************************************"
echo "Running os-restore.sh (interactive restore for OS users/groups/network)"

if [ "$EUID" -ne 0 ]; then
	echo "Error: Please run this script as root."
	exit 1
fi

if [ ! -d "$BACKUP_ROOT" ]; then
	echo "WARNING: OS backup bundle not found at $BACKUP_ROOT"
	exit 0
fi

ask_yes_no() {
	local prompt="$1"
	local answer=""

	while true; do
		read -r -p "$prompt [y/N]: " answer
		case "${answer,,}" in
			y|yes)
				return 0
				;;
			n|no|"")
				return 1
				;;
			*)
				echo "Please answer y or n."
				;;
		esac
	done
}

restore_file() {
	local source_path="$1"
	local target_path="$2"

	mkdir -p "$(dirname "$target_path")"
	cp -a "$source_path" "$target_path"
	echo "Restored file: $target_path"
}

restore_dir() {
	local source_path="$1"
	local target_path="$2"

	mkdir -p "$target_path"
	cp -a "$source_path"/. "$target_path"/
	echo "Restored directory: $target_path"
}

network_changed=0

if [ ! -f "$MANIFEST_FILE" ]; then
	echo "WARNING: Restore manifest not found at $MANIFEST_FILE"
	exit 0
fi

while IFS='|' read -r kind source_rel target_path label; do
	[ -n "$kind" ] || continue
	[ -n "$source_rel" ] || continue
	[ -n "$target_path" ] || continue
	[ -n "$label" ] || label="$target_path"

	source_path="$BACKUP_ROOT/$source_rel"
	if [ ! -e "$source_path" ]; then
		echo "Skipping missing backup item: $source_path"
		continue
	fi

	if ask_yes_no "Restore ${label}?"; then
		if [ "$kind" = "dir" ]; then
			restore_dir "$source_path" "$target_path"
		else
			restore_file "$source_path" "$target_path"
		fi

		case "$target_path" in
			/etc/netplan*|/etc/NetworkManager*|/etc/systemd/network*|/etc/systemd/resolved.conf*|/etc/network/interfaces*|/etc/wpa_supplicant*|/etc/hostname|/etc/hosts|/etc/resolv.conf|/etc/udev/rules.d/70-persistent-net.rules)
				network_changed=1
				;;
		esac
	else
		echo "Skipped: $label"
	fi
done < "$MANIFEST_FILE"

chmod 0644 /etc/passwd /etc/group 2>/dev/null || true
chmod 0640 /etc/shadow /etc/gshadow 2>/dev/null || true

if [ "$network_changed" -eq 1 ]; then
	if command -v netplan >/dev/null 2>&1; then
		netplan generate || true
		netplan apply || true
	fi

	if command -v nmcli >/dev/null 2>&1; then
		nmcli general reload || true
		if systemctl is-active --quiet NetworkManager 2>/dev/null; then
			systemctl restart NetworkManager || true
		fi
	fi

	if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
		systemctl restart systemd-networkd || true
	fi

	if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
		systemctl restart systemd-resolved || true
	fi
fi

echo "Restore process completed"

exit 0
