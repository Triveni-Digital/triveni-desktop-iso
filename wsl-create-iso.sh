#!/bin/bash

set -e

# ../update-docker-mount.sh

readonly START_EPOCH="$(date +%s)"
readonly START_TIME="$(date -Is)"

report_duration() {
  local exit_status=$?
  local end_epoch end_time duration hours minutes seconds

  end_epoch="$(date +%s)"
  end_time="$(date -Is)"
  duration=$((end_epoch - START_EPOCH))
  hours=$((duration / 3600))
  minutes=$(((duration % 3600) / 60))
  seconds=$((duration % 60))

  echo "[wsl-create-iso] Start time: $START_TIME"
  echo "[wsl-create-iso] End time:   $end_time"
  printf '[wsl-create-iso] Duration:   %02d:%02d:%02d\n' "$hours" "$minutes" "$seconds"
  echo "[wsl-create-iso] Exit status: $exit_status"
}

trap report_duration EXIT

echo "[wsl-create-iso] Start time: $START_TIME"

HOST_MOUNT_DIR="/home/triveni/docker-mount"
BASE_ISO="${HOST_MOUNT_DIR}/ubuntu-24.04-desktop-amd64.iso"
DEB_DIRS="${HOST_MOUNT_DIR}/triveni-drivers/24.04/main:${HOST_MOUNT_DIR}/mt"

sudo ./create-iso.sh -i "$BASE_ISO" \
  -p "$DEB_DIRS"

trap - EXIT
report_duration

sleep 5

#./qemu-run-iso.sh -n -d
