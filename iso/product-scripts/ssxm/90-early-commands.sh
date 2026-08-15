#!/bin/bash

set -euo pipefail

readonly BACKUP_SCRIPT="/cdrom/scripts/product-scripts/ssxm/backup.sh"

echo "**********************************************************************"
echo "Running ssxm/early-commands.sh"

if [ -x "$BACKUP_SCRIPT" ]; then
	"$BACKUP_SCRIPT" -y
else
	echo "[warn] Missing installer: $BACKUP_SCRIPT"
fi