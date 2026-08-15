#!/bin/bash

set -euo pipefail

echo "**********************************************************************"
echo "Running triveni-drivers/first-boot.sh"

# Prevent boot-time spam when nouveau owns the GPU before NVIDIA modules are ready.
if systemctl list-unit-files nvidia-persistenced.service >/dev/null 2>&1; then
	systemctl stop nvidia-persistenced.service >/dev/null 2>&1 || true
	systemctl mask --runtime nvidia-persistenced.service >/dev/null 2>&1 || true
fi

if [ -x /var/triveni/install/drivers/install.sh ]; then
	/var/triveni/install/drivers/install.sh -y
else
	echo "[warn] Missing driver installer: /var/triveni/install/drivers/install.sh"
fi