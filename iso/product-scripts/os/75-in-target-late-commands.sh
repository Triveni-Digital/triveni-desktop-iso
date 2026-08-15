#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly FILESYSTEM_OVERLAY="$SCRIPT_DIR/filesystem"

[ -d "$FILESYSTEM_OVERLAY" ] || {
    echo "Missing filesystem overlay: $FILESYSTEM_OVERLAY" >&2
    exit 1
}

echo "Applying OS filesystem overlay"
for entry in "$FILESYSTEM_OVERLAY"/*; do
    name="$(basename "$entry")"
    if [ "$name" = "share" ]; then
        mkdir -p /usr/share
        cp -a "$entry/." /usr/share/
    else
        cp -a "$entry" /
    fi
done