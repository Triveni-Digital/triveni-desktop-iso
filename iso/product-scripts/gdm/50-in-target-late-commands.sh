#!/bin/bash

trap 'exit 0' EXIT
set -e

readonly GDM_CUSTOM_CONF="/etc/gdm3/custom.conf"

echo "**********************************************************************"
echo "Running install-gdm.sh (forcing Xorg for the desktop session)"

if [ "$EUID" -ne 0 ]; then
	echo "Error: Please run this script as root."
	exit 1
fi

mkdir -p "$(dirname "$GDM_CUSTOM_CONF")"

if [ ! -f "$GDM_CUSTOM_CONF" ]; then
	cat >"$GDM_CUSTOM_CONF" <<'EOF'
[daemon]
WaylandEnable=false
EOF
else
	if grep -q '^#WaylandEnable=false' "$GDM_CUSTOM_CONF"; then
		sed -i 's/^#WaylandEnable=false/WaylandEnable=false/' "$GDM_CUSTOM_CONF"
	fi

	if ! grep -q '^WaylandEnable=false' "$GDM_CUSTOM_CONF"; then
		if ! grep -q '^\[daemon\]' "$GDM_CUSTOM_CONF"; then
			printf '\n[daemon]\n' >>"$GDM_CUSTOM_CONF"
		fi
		printf 'WaylandEnable=false\n' >>"$GDM_CUSTOM_CONF"
	fi
fi

echo "Wayland disabled in $GDM_CUSTOM_CONF"

exit 0
