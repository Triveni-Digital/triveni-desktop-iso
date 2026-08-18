#!/bin/bash

set -euo pipefail

echo "**********************************************************************"
echo "Running triveni-drivers/first-boot.sh"

if dpkg --audit | grep -q .; then
	echo "[triveni-drivers/first-boot] Repairing incomplete package configuration"
	if ! dpkg --configure -a; then
		echo "[triveni-drivers/first-boot][error] Incomplete packages could not be configured" >&2
		exit 1
	fi
fi

# Prevent boot-time spam when nouveau owns the GPU before NVIDIA modules are ready.
if systemctl list-unit-files nvidia-persistenced.service >/dev/null 2>&1; then
	systemctl stop nvidia-persistenced.service >/dev/null 2>&1 || true
	systemctl mask --runtime nvidia-persistenced.service >/dev/null 2>&1 || true
fi

shopt -s nullglob
declare -a driver_packages=(/var/triveni/install/triveni-drivers_*_amd64.deb)
shopt -u nullglob

if [ ${#driver_packages[@]} -eq 0 ]; then
	echo "ERROR: no driver package found in /var/triveni/install" >&2
	exit 1
fi

mapfile -t driver_packages < <(printf '%s\n' "${driver_packages[@]}" | sort -V)
selected_driver_package="${driver_packages[${#driver_packages[@]}-1]}"

if [ ${#driver_packages[@]} -gt 1 ]; then
	echo "WARNING: found ${#driver_packages[@]} driver packages in /var/triveni/install; installing ${selected_driver_package}" >&2
fi

if ! apt install -y --reinstall "$selected_driver_package"; then
	echo "ERROR: failed to install $selected_driver_package" >&2
	exit 1
fi

# The package postinst cannot install the bundled driver packages while dpkg holds its lock.
if ! /opt/triveni-drivers/install.sh -y; then
	echo "ERROR: failed to install detected driver packages" >&2
	exit 1
fi
