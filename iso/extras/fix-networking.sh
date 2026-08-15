#!/bin/bash

# Repairs interface naming on an installed system. The active Ethernet interface
# configured for DHCP becomes eth00; all remaining Ethernet interfaces become
# eth01, eth02, and so on. MAC-based systemd link files preserve the names after
# reboot, and active NetworkManager profiles are updated to follow the new names.

set -euo pipefail

readonly LINK_DIR="/etc/systemd/network"

log() { echo "[fix-networking] $*"; }
die() { echo "[fix-networking][error] $*" >&2; exit 1; }

require_root() {
	[ "$(id -u)" -eq 0 ] || die "This script must be run as root"
}

require_commands() {
	local command_name
	for command_name in ip nmcli sort awk grep; do
		command -v "$command_name" >/dev/null 2>&1 || die "Required command not found: $command_name"
	done
}

active_connection_uuid() {
	local iface="$1"
	local uuid

	uuid="$(nmcli -g GENERAL.CON-UUID device show "$iface" 2>/dev/null || true)"
	[ "$uuid" != "--" ] || uuid=""
	printf '%s\n' "$uuid"
}

uses_dhcp() {
	local iface="$1"
	local uuid
	local method

	uuid="$(active_connection_uuid "$iface")"
	[ -n "$uuid" ] || return 1
	method="$(nmcli -g ipv4.method connection show "$uuid" 2>/dev/null || true)"
	[ "$method" = "auto" ]
}

collect_ethernet_interfaces() {
	local iface
	local iface_path

	for iface_path in /sys/class/net/*; do
		iface="${iface_path##*/}"
		[ "$iface" != "lo" ] || continue
		[ -d "$iface_path/device" ] || continue
		[ -f "$iface_path/type" ] || continue
		[ "$(<"$iface_path/type")" = "1" ] || continue
		case "$iface" in
			ens*|eno*|enp*|eth*) printf '%s\n' "$iface" ;;
		esac
	done | sort
}

find_dhcp_interface() {
	local iface
	local route_iface

	route_iface="$(ip -4 route show default proto dhcp 2>/dev/null |
		awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')"
	if [ -n "$route_iface" ] && uses_dhcp "$route_iface"; then
		printf '%s\n' "$route_iface"
		return 0
	fi

	for iface in "$@"; do
		if uses_dhcp "$iface"; then
			printf '%s\n' "$iface"
			return 0
		fi
	done

	return 1
}

write_link_file() {
	local final_name="$1"
	local mac_address="$2"

	cat > "$LINK_DIR/10-persistent-net-${final_name}.link" <<EOF
[Match]
MACAddress=$mac_address

[Link]
Name=$final_name
EOF
}

names_are_normalized() {
	local index=0
	local iface

	for iface in "$@"; do
		[ "$iface" = "eth0${index}" ] || return 1
		index=$((index + 1))
	done

	return 0
}

main() {
	local dhcp_iface
	local iface
	local index=0
	local final_name
	local mac_address
	local temporary_name
	local uuid
	local dhcp_uuid=""
	local -a interfaces=()
	local -a ordered_interfaces=()
	local -a temporary_names=()

	require_root
	require_commands
	mapfile -t interfaces < <(collect_ethernet_interfaces)
	[ "${#interfaces[@]}" -gt 0 ] || die "No supported Ethernet interfaces were found"

	if uses_dhcp eth00; then
		dhcp_iface="eth00"
	else
		dhcp_iface="$(find_dhcp_interface "${interfaces[@]}")" ||
			die "No active Ethernet interface configured for DHCP was found"
	fi
	log "DHCP interface detected: $dhcp_iface"

	ordered_interfaces+=("$dhcp_iface")
	for iface in "${interfaces[@]}"; do
		[ "$iface" = "$dhcp_iface" ] || ordered_interfaces+=("$iface")
	done

	if names_are_normalized "${ordered_interfaces[@]}"; then
		log "eth00 uses DHCP and all Ethernet interfaces are already normalized"
		exit 0
	fi

	mkdir -p "$LINK_DIR"
	rm -f "$LINK_DIR"/10-persistent-net-*.link

	for iface in "${ordered_interfaces[@]}"; do
		final_name="eth0${index}"
		mac_address="$(<"/sys/class/net/$iface/address")"
		write_link_file "$final_name" "$mac_address"

		uuid="$(active_connection_uuid "$iface")"
		if [ -n "$uuid" ]; then
			nmcli connection modify "$uuid" \
				connection.interface-name "$final_name" \
				802-3-ethernet.mac-address "$mac_address"
			if [ "$iface" = "$dhcp_iface" ]; then
				dhcp_uuid="$uuid"
			fi
		fi
		index=$((index + 1))
	done

	# Rename through collision-free temporary names so an existing eth00 can move.
	index=0
	for iface in "${ordered_interfaces[@]}"; do
		temporary_name="trvtmp${index}"
		temporary_names+=("$temporary_name")
		nmcli device disconnect "$iface" >/dev/null 2>&1 || true
		ip link set dev "$iface" down
		ip link set dev "$iface" name "$temporary_name"
		index=$((index + 1))
	done

	index=0
	for temporary_name in "${temporary_names[@]}"; do
		final_name="eth0${index}"
		ip link set dev "$temporary_name" name "$final_name"
		ip link set dev "$final_name" up
		nmcli device set "$final_name" managed yes >/dev/null 2>&1 || true
		log "$temporary_name -> $final_name"
		index=$((index + 1))
	done

	nmcli connection reload
	if [ -n "$dhcp_uuid" ]; then
		nmcli connection up "$dhcp_uuid" ifname eth00
	else
		nmcli device connect eth00
	fi

	log "Networking repaired; DHCP interface is now eth00"
	ip -br address
}

main "$@"
