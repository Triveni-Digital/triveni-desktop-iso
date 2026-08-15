#!/bin/bash

set -euo pipefail

readonly SOURCE_FILE="/tmp/backup/ssmt_backup.tar.gz"
TARGET_BASE="/target/var/triveni/install/backup"

if [ "${1:-}" = "--no-restore" ]; then
	TARGET_BASE="/target/var/triveni/install/backup.bak"
elif [ -n "${1:-}" ]; then
	echo "ERROR: Unknown option: $1"
	exit 1
fi

TARGET_DIR="$TARGET_BASE/ssmt"

echo "Copying SSMT backup into $TARGET_DIR"

if [ ! -f "$SOURCE_FILE" ]; then
	echo "No SSMT backup found at $SOURCE_FILE"
	exit 0
fi

mkdir -p "$TARGET_DIR"
cp -a "$SOURCE_FILE" "$TARGET_DIR/"

echo "SSMT backup copied to $TARGET_DIR"
exit 0