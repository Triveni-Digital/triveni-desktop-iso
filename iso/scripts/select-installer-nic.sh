#!/bin/bash

# This early-command must never fail the installer. Best-effort only.
set -uo pipefail

readonly AUTOINSTALL_FILE="/autoinstall.yaml"
readonly LOG_FILE="/var/log/triveni-installer-nic.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "**********************************************************************"
echo "Running select-installer-nic.sh"

get_udev_property() {
	local nic="$1"
	local key="$2"

	udevadm info -q property -p "/sys/class/net/$nic" 2>/dev/null | awk -F= -v key="$key" '$1 == key { print $2; exit }'
}

is_physical_ethernet() {
	local nic="$1"

	[[ -d "/sys/class/net/$nic/device" ]] || return 1
	[[ "$nic" != "lo" ]] || return 1
	[[ -f "/sys/class/net/$nic/type" ]] || return 1
	[[ "$(cat "/sys/class/net/$nic/type")" = "1" ]] || return 1
	return 0
}

is_usb_interface() {
	local nic="$1"
	local bus
	local device_path

	bus=$(get_udev_property "$nic" "ID_BUS")
	device_path=$(readlink -f "/sys/class/net/$nic/device" 2>/dev/null || true)

	if [ "$bus" = "usb" ] || echo "$device_path" | grep -q '/usb'; then
		echo "[installer-nic] Excluding $nic: USB network interface"
		return 0
	fi

	return 1
}

is_excluded_pci_interface() {
	local nic="$1"
	local pci_path
	local pci_slot
	local pci_desc

	pci_path=$(readlink -f "/sys/class/net/$nic/device" 2>/dev/null || true)
	[[ -n "$pci_path" ]] || return 1
	pci_slot=$(basename "$pci_path")
	pci_desc=$(lspci -s "$pci_slot" 2>/dev/null || true)

	if echo "$pci_desc" | grep -Eqi 'napatech|accolade'; then
		echo "[installer-nic] Excluding $nic ($pci_slot): $pci_desc"
		return 0
	fi

	return 1
}

is_onboard_interface() {
	local nic="$1"

	if [ -n "$(get_udev_property "$nic" "ID_NET_NAME_ONBOARD")" ]; then
		return 0
	fi

	if [ -n "$(get_udev_property "$nic" "ID_NET_LABEL_ONBOARD")" ]; then
		return 0
	fi

	return 1
}

pick_best_nic() {
	local nic
	local score

	[ "$#" -gt 0 ] || return 1

	for nic in "$@"; do
		score=0

		# Multi-function add-in NICs often end with f0/f1; de-prioritize them.
		if [[ "$nic" =~ f[0-9]+$ ]]; then
			score=$((score + 100))
		fi

		printf '%03d\t%03d\t%s\n' "$score" "${#nic}" "$nic"
	done | sort -k1,1n -k2,2n -k3,3 | awk 'NR==1 {print $3}'
}

pick_installer_nic() {
	local nic
	local selected
	local -a onboard=()
	local -a preferred=()
	local -a fallback=()

	for nic in $(ls /sys/class/net | sort); do
		is_physical_ethernet "$nic" || continue
		if is_usb_interface "$nic"; then
			continue
		fi
		if is_excluded_pci_interface "$nic"; then
			continue
		fi

		if is_onboard_interface "$nic"; then
			onboard+=("$nic")
			continue
		fi

		case "$nic" in
			eno*|em*)
				preferred+=("$nic")
				;;
			en*|eth*)
				fallback+=("$nic")
				;;
		esac
		
	done

	if [ "${#onboard[@]}" -gt 0 ]; then
		selected="$(pick_best_nic "${onboard[@]}")"
		echo "$selected"
		return 0
	fi

	if [ "${#preferred[@]}" -gt 0 ]; then
		selected="$(pick_best_nic "${preferred[@]}")"
		echo "$selected"
		return 0
	fi

	if [ "${#fallback[@]}" -gt 0 ]; then
		selected="$(pick_best_nic "${fallback[@]}")"
		echo "$selected"
		return 0
	fi

	return 1
}

rewrite_autoinstall_network() {
	local nic="$1"
	local tmp_file

	tmp_file=$(mktemp)
	if ! python3 - "$AUTOINSTALL_FILE" "$tmp_file" "$nic" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
nic = sys.argv[3]

text = source.read_text()
old = """  network:\n    version: 2\n    ethernets: {}\n"""
new = f"""  network:\n    version: 2\n    ethernets:\n      installer-nic:\n        match:\n          name: {nic}\n        dhcp4: true\n        optional: true\n"""

if old not in text:
    print("[installer-nic] Expected default network block not found; leaving autoinstall network config unchanged")
    target.write_text(text)
    raise SystemExit(0)

target.write_text(text.replace(old, new, 1))
PY
	then
		echo "[installer-nic] Failed to rewrite autoinstall network config; continuing without rewrite"
		rm -f "$tmp_file"
		return 0
	fi

	if [ -s "$tmp_file" ]; then
		mv "$tmp_file" "$AUTOINSTALL_FILE" || {
			echo "[installer-nic] Could not replace $AUTOINSTALL_FILE; continuing without rewrite"
			rm -f "$tmp_file"
			return 0
		}
	else
		rm -f "$tmp_file"
	fi
}

if [ ! -f "$AUTOINSTALL_FILE" ]; then
	echo "[installer-nic] Autoinstall file not found: $AUTOINSTALL_FILE"
	exit 0
fi

if installer_nic=$(pick_installer_nic); then
	echo "[installer-nic] Selected installer NIC: $installer_nic"
	rewrite_autoinstall_network "$installer_nic" || true
else
	echo "[installer-nic] No safe installer NIC found; leaving installer network config unchanged"
fi

exit 0