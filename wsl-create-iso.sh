#!/bin/bash

set -e

# ../update-docker-mount.sh

HOST_MOUNT_DIR="/home/triveni/docker-mount"
BASE_ISO="${HOST_MOUNT_DIR}/ubuntu-24.04-desktop-amd64.iso"
DEB_DIRS="${HOST_MOUNT_DIR}/triveni-drivers/24.04/main:${HOST_MOUNT_DIR}/mt:${HOST_MOUNT_DIR}/xm"

sudo ./create-iso.sh -i "$BASE_ISO" \
  -p "$DEB_DIRS"

sleep 5

./qemu-run-iso.sh -n -d
