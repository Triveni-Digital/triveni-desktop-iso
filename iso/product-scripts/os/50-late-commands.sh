#!/bin/bash

set -euo pipefail

readonly SOURCE_ROOT="/tmp/backup/os"
TARGET_BASE="/target/var/triveni/install/backup"

if [ "${1:-}" = "--no-restore" ]; then
	TARGET_BASE="/target/var/triveni/install/backup.bak"
elif [ -n "${1:-}" ]; then
	echo "ERROR: Unknown option: $1"
	exit 1
fi

TARGET_ROOT="$TARGET_BASE/os"

echo "Copying OS backup into $TARGET_ROOT"

if [ ! -d "$SOURCE_ROOT" ]; then
	echo "No OS backup found at $SOURCE_ROOT"
	exit 0
fi

mkdir -p "$TARGET_ROOT"
cp -a "$SOURCE_ROOT"/. "$TARGET_ROOT/"

echo "OS backup copied to $TARGET_ROOT"
exit 0
