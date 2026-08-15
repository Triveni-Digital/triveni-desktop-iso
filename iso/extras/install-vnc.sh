#!/bin/bash

################################################################################
# Script: install_x11vnc_final.sh
# Description: Fully automated, bulletproof setup for x11vnc mirroring.
#              Handles GDM3 display shifting (:0 to :1), user token handoffs,
#              disables Wayland, bypasses MIT-SHM errors, and survives reboots.
################################################################################

set -e

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root. Please use sudo."
    exit 1
fi

echo "========================================================================"
echo "Step 1: Cleaning up old TigerVNC packages & installing x11vnc..."
echo "========================================================================"
apt-get update
apt-get install -y x11vnc

echo "========================================================================"
echo "Step 2: Forcing X11 for the Login Screen (Disabling Wayland)..."
echo "========================================================================"
GDM_CUSTOM_CONF="/etc/gdm3/custom.conf"
if [ -f "$GDM_CUSTOM_CONF" ]; then
    sed -i 's/^#WaylandEnable=false/WaylandEnable=false/' "$GDM_CUSTOM_CONF"
    if ! grep -q "^WaylandEnable=false" "$GDM_CUSTOM_CONF"; then
        echo "[daemon]" >> "$GDM_CUSTOM_CONF"
        echo "WaylandEnable=false" >> "$GDM_CUSTOM_CONF"
    fi
    echo "Wayland has been disabled in $GDM_CUSTOM_CONF."
else
    echo "Warning: GDM3 configuration file not found. Skipping Wayland disable."
fi

echo "========================================================================"
echo "Step 3: Creating System-Wide VNC Password..."
echo "========================================================================"
mkdir -p /etc/x11vnc
echo "Please enter the password you want to use for VNC connections:"
x11vnc -storepasswd /etc/x11vnc/vncpwd
chmod 600 /etc/x11vnc/vncpwd

echo "========================================================================"
echo "Step 4: Creating the Dynamic Session Tracker Wrapper Script..."
echo "========================================================================"
WRAPPER_FILE="/usr/local/bin/x11vnc-wrapper.sh"

cat > "$WRAPPER_FILE" << 'EOF'
#!/bin/bash

# 1. Find the newest active Xauthority token based on modification time
AUTHORITY=$(find /run/user/ -name Xauthority -printf "%T@ %p\n" 2>/dev/null | sort -n | tail -n 1 | awk '{print $2}')

# 2. Look at the filesystem sockets to find the true, active display number (e.g., X1 becomes :1)
SOCKET_FILE=$(ls /tmp/.X11-unix/ | grep -E "^X[0-9]+" | head -n 1)
DISPLAY_NUM=$(echo "$SOCKET_FILE" | sed 's/X/:/')

# Fallback defaults if the directory scans return empty
[ -z "$AUTHORITY" ] && AUTHORITY=$(find /run/user/ -name Xauthority | head -n 1)
[ -z "$DISPLAY_NUM" ] && DISPLAY_NUM=":0"

echo "Using Authority: $AUTHORITY"
echo "Using Display:   $DISPLAY_NUM"

# 3. Execute x11vnc with the live variables
# -noshm handles cross-user attachment errors during handoff
exec /usr/bin/x11vnc -display "$DISPLAY_NUM" -auth "$AUTHORITY" -noshm -forever -noxdamage -repeat -rfbauth /etc/x11vnc/vncpwd -rfbport 5900 -shared
EOF

chmod +x "$WRAPPER_FILE"
echo "Wrapper script deployed to $WRAPPER_FILE."

echo "========================================================================"
echo "Step 5: Provisioning the systemd Boot Service..."
echo "========================================================================"
SERVICE_FILE="/etc/systemd/system/x11vnc.service"

cat > "$SERVICE_FILE" << 'EOF'
[Unit]
Description=x11vnc remote desktop mirroring service
Requires=display-manager.service
After=display-manager.service

[Service]
Type=simple
Environment=HOME=/root
ExecStart=/usr/local/bin/x11vnc-wrapper.sh
Restart=always
RestartSec=2

[Install]
WantedBy=graphical.target
EOF

echo "Reloading systemd and enabling the x11vnc service..."
systemctl daemon-reload
systemctl enable x11vnc.service

echo "========================================================================"
echo "SUCCESS: x11vnc environment installation complete!"
echo "IMPORTANT: You MUST reboot your system now to apply the Wayland fix."
echo "========================================================================"