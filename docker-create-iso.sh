#!/bin/bash

# This script builds a Docker image and runs a container to create a Triveni Digital System ISO.
# This is used to debug and test the ISO creation process in a controlled environment.
# Best to run this script inside wsl2.  Otherwise it takes like 10 minutes to run because of the 
# slow file system access on Windows.

set -e

# ==========================================
# Define Variables (Native Linux Paths)
# ==========================================
IMAGE_NAME="triveni-desktop-iso:latest"

# Everything lives locally inside the native Linux VHDX now
HOST_MOUNT_DIR="/home/triveni/docker-mount"
HOST_WORKSPACE_DIR="$(pwd)"

CONTAINER_USER_CONTENT="/mnt/userContent"
CONT_BASE_ISO="${CONTAINER_USER_CONTENT}/ubuntu-24.04-desktop-amd64.iso"
CONT_DEB_DIRS="${CONTAINER_USER_CONTENT}/mt:${CONTAINER_USER_CONTENT}/xm"
# ==========================================

echo "🐳 Building Docker image..."
docker build -f Dockerfile -t "$IMAGE_NAME" .

echo "🚀 Running ISO generator container..."
docker run --rm \
  --privileged \
  -v "${HOST_MOUNT_DIR}:${CONTAINER_USER_CONTENT}" \
  -v "${HOST_WORKSPACE_DIR}:/workspace" \
  -e BASE_ISO_FILE="$CONT_BASE_ISO" \
  -e DEB_DIRS="$CONT_DEB_DIRS" \
  "$IMAGE_NAME" \
  sh -c "ant -DBASE_ISO_FILE=\$BASE_ISO_FILE -DDEB_DIRS=\$DEB_DIRS"

./qemu-run-iso.sh -d
