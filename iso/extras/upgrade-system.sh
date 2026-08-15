#!/bin/bash

set -euo pipefail

readonly TARGET_KERNEL_SERIES="${TARGET_KERNEL_SERIES:-6.8.0}"

usage() {
	echo "Usage: $0"
	echo "Configures ubuntu.sources, pins the target kernel series, installs kernel meta-packages, upgrades the system, and repairs gdm3 if needed."
}

if [ "$#" -ne 0 ]; then
	usage >&2
	exit 1
fi

ensure_apt_support() {
	if ! command -v apt >/dev/null 2>&1; then
		echo "ERROR: apt is required to upgrade the system." >&2
		exit 1
	fi
}

ensure_gdm_smartcard_placeholder() {
	local pam_dir="/etc/pam.d"
	local pam_file
	local pam_files=(
		"$pam_dir/gdm-smartcard-sssd-exclusive"
		"$pam_dir/gdm-smartcard-sssd-or-password"
		"$pam_dir/gdm-smartcard-pkcs11-exclusive"
	)

	for pam_file in "${pam_files[@]}"; do
		if [ ! -e "$pam_file" ]; then
			touch "$pam_file"
		fi
	done
}

require_root() {
	if [ "$(id -u)" -ne 0 ]; then
		echo "ERROR: This script must be run as root." >&2
		exit 1
	fi
}


validate_target_kernel_series() {
	if ! printf '%s\n' "$TARGET_KERNEL_SERIES" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
		echo "ERROR: TARGET_KERNEL_SERIES must look like 6.8.0. Current value: $TARGET_KERNEL_SERIES" >&2
		exit 1
	fi
}

get_ubuntu_codename() {
	local codename=""
	if [ -r /etc/os-release ]; then
		# shellcheck disable=SC1091
		. /etc/os-release
		codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
	fi

	if [ -z "$codename" ]; then
		echo "ERROR: Unable to determine Ubuntu codename from /etc/os-release." >&2
		exit 1
	fi

	echo "$codename"
}

get_ubuntu_archive_uri() {
	local arch
	arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
	case "$arch" in
		amd64|i386)
			echo "http://archive.ubuntu.com/ubuntu"
			;;
		*)
			echo "http://ports.ubuntu.com/ubuntu-ports"
			;;
	esac
}

get_ubuntu_security_uri() {
	local arch
	arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
	case "$arch" in
		amd64|i386)
			echo "http://security.ubuntu.com/ubuntu"
			;;
		*)
			echo "http://ports.ubuntu.com/ubuntu-ports"
			;;
	esac
}

configure_ubuntu_sources() {
	local codename
	local archive_uri
	local security_uri
	local tmp_file
	local sources_file="/etc/apt/sources.list.d/ubuntu.sources"

	codename="$(get_ubuntu_codename)"
	archive_uri="$(get_ubuntu_archive_uri)"
	security_uri="$(get_ubuntu_security_uri)"
	tmp_file="$(mktemp)"

	cat >"$tmp_file" <<EOF
Types: deb
URIs: $archive_uri
Suites: $codename ${codename}-updates ${codename}-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: $security_uri
Suites: ${codename}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

	install -D -m 0644 "$tmp_file" "$sources_file"
	rm -f "$tmp_file"
}

pin_target_kernel_series() {
	local pin_file="/etc/apt/preferences.d/triveni-kernel-series.pref"
	local tmp_file

	validate_target_kernel_series
	tmp_file="$(mktemp)"

	cat >"$tmp_file" <<EOF
Package: linux-generic linux-headers-generic linux-image-generic linux-image-unsigned-generic linux-modules-extra-generic linux-generic-hwe-* linux-headers-generic-hwe-* linux-image-generic-hwe-* linux-image-unsigned-generic-hwe-* linux-modules-extra-generic-hwe-* linux-image-[0-9]* linux-headers-[0-9]* linux-modules-[0-9]* linux-modules-extra-[0-9]*
Pin: version ${TARGET_KERNEL_SERIES}-*
Pin-Priority: 1001
EOF

	install -D -m 0644 "$tmp_file" "$pin_file"
	rm -f "$tmp_file"
	echo "Pinned kernel packages to the ${TARGET_KERNEL_SERIES}.x release family."
}

install_kernel_meta_packages() {
	ensure_gdm_smartcard_placeholder
	apt update
	apt install -y linux-generic linux-headers-generic
}

ensure_gdm_smartcard_placeholder() {
	local pam_dir="/etc/pam.d"
	local pam_file
	local pam_files=(
		"$pam_dir/gdm-smartcard-sssd-exclusive"
		"$pam_dir/gdm-smartcard-sssd-or-password"
		"$pam_dir/gdm-smartcard-pkcs11-exclusive"
	)

	for pam_file in "${pam_files[@]}"; do
		if [ ! -e "$pam_file" ]; then
			touch "$pam_file"
		fi
	done
}

repair_gdm_if_needed() {
	local gdm_status=""
	ensure_gdm_smartcard_placeholder

	if ! command -v dpkg-query >/dev/null 2>&1; then
		return 0
	fi

	gdm_status=$(dpkg-query -W -f='${Status}' gdm3 2>/dev/null || true)
	if [ -z "$gdm_status" ]; then
		return 0
	fi

	if [ "$gdm_status" != "install ok installed" ]; then
		echo "Repairing gdm3 package configuration..."
		dpkg --configure -a
		apt install --reinstall -y gdm3
	fi
}

run_triveni_rebuild_helpers() {
	local helper
	local kernel_dir
	local kernel_version
	local helpers_found=0
	local kernels_found=0

	for helper in /usr/local/sbin/triveni-*-driver-rebuild; do
		[ -x "$helper" ] || continue
		helpers_found=1
		for kernel_dir in /lib/modules/${TARGET_KERNEL_SERIES}-*; do
			[ -d "$kernel_dir" ] || continue
			kernels_found=1
			kernel_version="${kernel_dir##*/}"
			echo "Running $(basename "$helper") for kernel $kernel_version"
			"$helper" "$kernel_version" || true
		done
		if [ "$kernels_found" -eq 0 ]; then
			echo "No installed kernels found matching ${TARGET_KERNEL_SERIES}-*; skipping $(basename "$helper")"
		fi
	done

	if [ "$helpers_found" -eq 0 ]; then
		echo "No Triveni rebuild helpers found in /usr/local/sbin"
	fi
}

upgrade_system() {
	ensure_apt_support
	require_root
	configure_ubuntu_sources
	pin_target_kernel_series
	ensure_gdm_smartcard_placeholder
	install_kernel_meta_packages

	apt update
	apt upgrade -y
	run_triveni_rebuild_helpers
	repair_gdm_if_needed
}

upgrade_system
