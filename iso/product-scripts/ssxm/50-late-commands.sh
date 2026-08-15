#!/bin/bash

set -euo pipefail

readonly SOURCE_FILE="/tmp/backup/ssxm_backup.tar.gz"
TARGET_BASE="/target/var/triveni/install/backup"

if [ "${1:-}" = "--no-restore" ]; then
	TARGET_BASE="/target/var/triveni/install/backup.bak"
elif [ -n "${1:-}" ]; then
	echo "ERROR: Unknown option: $1"
	exit 1
fi

TARGET_DIR="$TARGET_BASE/ssxm"

echo "Copying SSXM backup into $TARGET_DIR"

if [ ! -f "$SOURCE_FILE" ]; then
	echo "No SSXM backup found at $SOURCE_FILE"
	exit 0
fi

mkdir -p "$TARGET_DIR"
cp -a "$SOURCE_FILE" "$TARGET_DIR/"

echo "SSXM backup copied to $TARGET_DIR"
exit 0