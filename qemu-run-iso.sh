#!/bin/bash
# Copyright (c) 2026. Triveni Digital LLC, All rights reserved.

# This script runs the Triveni Digital System ISO in a QEMU virtual machine with hardware acceleration.
# The docker-create-iso.sh script calls this script right after running with the -d option, which forces 
# the deletion of any existing virtual hard drive and creates a new one.

set -e

# ==========================================
# Configuration Variables
# ==========================================
VHD_IMAGE="triveni-test-vm.qcow2"
VHD_DISKSIZE="200G"
VHD_CPUS="8,sockets=1,cores=8,threads=1"
VHD_MEMORY=8192
SSH_FORWARD_PORT=2122
HTTP_FORWARD_PORT=2180
FORCE_DELETE=false
REUSE_EXISTING=false
DISABLE_NETWORK=false

check_qemu_ping_permissions() {
    local range_file="/proc/sys/net/ipv4/ping_group_range"
    local group_id
    local range_min
    local range_max

    [ -r "$range_file" ] || return 0

    group_id=$(id -g)
    read -r range_min range_max < "$range_file"

    if [ "$group_id" -lt "$range_min" ] || [ "$group_id" -gt "$range_max" ]; then
        echo "WARNING: QEMU user networking cannot forward ping for group $group_id."
        echo "Current net.ipv4.ping_group_range: $range_min $range_max"
        echo "Temporary fix:"
        echo "  sudo sysctl -w net.ipv4.ping_group_range=\"0 2147483647\""
        echo "Persistent fix:"
        echo "  echo 'net.ipv4.ping_group_range = 0 2147483647' | sudo tee /etc/sysctl.d/99-qemu-ping.conf"
        echo "  sudo sysctl --system"
    fi
}

check_ssh_forward_port() {
    if command -v ss >/dev/null 2>&1 &&
        ss -ltnH "sport = :$SSH_FORWARD_PORT" | grep -q .; then
        echo "ERROR: Host port $SSH_FORWARD_PORT is already in use; SSH forwarding cannot start." >&2
        return 1
    fi
}

check_http_forward_port() {
    if command -v ss >/dev/null 2>&1 &&
        ss -ltnH "sport = :$HTTP_FORWARD_PORT" | grep -q .; then
        echo "ERROR: Host port $HTTP_FORWARD_PORT is already in use; HTTP forwarding cannot start." >&2
        return 1
    fi
}

# ==========================================
# Argument Parsing (Catches the -d, -r, and -n flags)
# ==========================================
while getopts "drn" opt; do
    case ${opt} in
        d )
            FORCE_DELETE=true
            ;;
        r )
            REUSE_EXISTING=true
            ;;
        n )
            DISABLE_NETWORK=true
            ;;
        \? )
            echo "Usage: $0 [-d | -r] [-n]"
            exit 1
            ;;
    esac
done

if [ "$FORCE_DELETE" = true ] && [ "$REUSE_EXISTING" = true ]; then
    echo "❌ Error: -d and -r cannot be used together."
    echo "Usage: $0 [-d | -r] [-n]"
    exit 1
fi

# ==========================================
# 1. Locate the Compiled ISO
# ==========================================
echo "🔍 Searching for the compiled installation ISO..."

shopt -s nullglob
ISOS=("dist"/*.iso)
shopt -u nullglob

if [ ${#ISOS[@]} -eq 0 ]; then
    echo "❌ Error: No ISO file found inside the dist/ folder!"
    exit 1
fi

# Pick the single most recently generated ISO file by modification time
TARGET_ISO=$(ls -t dist/*.iso | head -n 1)
echo "🎯 Target ISO identified: $TARGET_ISO"

# ==========================================
# 2. Virtual Hard Drive Lifecycle Management
# ==========================================
create_fresh_vhd() {
    echo "🗑️ Clearing old disk states..."
    rm -f "$VHD_IMAGE"
    echo "💽 Allocating a fresh $VHD_DISKSIZE virtual hard drive ($VHD_IMAGE)..."
    qemu-img create -f qcow2 "$VHD_IMAGE" "$VHD_DISKSIZE"
}

if [ -f "$VHD_IMAGE" ]; then
    if [ "$FORCE_DELETE" = true ]; then
        echo "⚡ '-d' flag detected. Bypassing prompt..."
        create_fresh_vhd
    elif [ "$REUSE_EXISTING" = true ]; then
        echo "♻️  '-r' flag detected. Reusing existing virtual drive: $VHD_IMAGE"
    else
        echo "♻️  Existing virtual drive detected. Reusing: $VHD_IMAGE"
    fi
else
    if [ "$REUSE_EXISTING" = true ]; then
        echo "❌ Error: '-r' requested but virtual drive not found: $VHD_IMAGE"
        exit 1
    fi
    echo "💽 Virtual drive not found."
    create_fresh_vhd
fi

# ==========================================
# 3. Boot the Hardware-Accelerated Instance
# ==========================================
echo "🖥️ Booting QEMU Instance on your Ryzen 7950X..."
echo "💡 Note: To release mouse focus back to Windows, press Ctrl+Alt"

if [ "$DISABLE_NETWORK" = true ]; then
    echo "🌐 Network adapters present but disconnected for this run (-n)"
    echo "SSH is unavailable because the VM has no network backend."
    echo "HTTP is unavailable because the VM has no network backend."
else
    check_qemu_ping_permissions
    check_ssh_forward_port
    check_http_forward_port
fi

echo "💡💡💡 Enable clipboard integration via the SPICE agent for better copy-paste support."
echo "sudo apt install -y spice-vdagent"
echo "sudo systemctl enable --now spice-vdagentd"

qemu_cmd=(
    qemu-system-x86_64
    -enable-kvm
    -cpu host
    -smp "$VHD_CPUS"
    -m "$VHD_MEMORY"
    -drive file="$VHD_IMAGE",if=virtio,cache=writeback
    -cdrom "$TARGET_ISO"
    -device virtio-vga,xres=1024,yres=768
    # -vga std
    -display gtk,zoom-to-fit=on
    -chardev qemu-vdagent,id=ch1,name=vdagent,clipboard=on
    -device virtio-serial-pci
    -device virtserialport,chardev=ch1,id=ch1,name=com.redhat.spice.0
)

if [ "$REUSE_EXISTING" = true ]; then
        echo "📀 Forcing one-time boot from ISO for reuse flow (-r)"
        qemu_cmd+=(
            -boot once=d,menu=on
        )
fi

if [ "$DISABLE_NETWORK" = true ]; then
        qemu_cmd+=(
            -nic none
            -device virtio-net-pci,mac=52:54:00:12:34:56
            -device virtio-net-pci,mac=52:54:00:12:34:57
            -device virtio-net-pci,mac=52:54:00:12:34:58
            -device virtio-net-pci,mac=52:54:00:12:34:59
        )
else
        echo "SSH after the installed system has booted:"
        echo "  ssh -p $SSH_FORWARD_PORT triveni@127.0.0.1"
        echo "HTTP after the installed system has booted:"
        echo "  http://127.0.0.1:$HTTP_FORWARD_PORT"
        qemu_cmd+=(
            -netdev user,id=net0,net=10.0.2.0/24
            -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56
            -netdev user,id=net1,net=192.168.2.10/24,hostfwd=tcp:127.0.0.1:${SSH_FORWARD_PORT}-:22
            -device virtio-net-pci,netdev=net1,mac=52:54:00:12:34:57
            -netdev user,id=net2,net=192.168.2.20/24,hostfwd=tcp:127.0.0.1:${HTTP_FORWARD_PORT}-:80
            -device virtio-net-pci,netdev=net2,mac=52:54:00:12:34:58
            -netdev user,id=net3,net=192.168.2.30/24
            -device virtio-net-pci,netdev=net3,mac=52:54:00:12:34:59
        )
fi

"${qemu_cmd[@]}"
