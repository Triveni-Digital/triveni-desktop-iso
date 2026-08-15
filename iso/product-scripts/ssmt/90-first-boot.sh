#!/bin/bash

set -euo pipefail

readonly INSTALL_FILE="/var/triveni/install/product-scripts/ssmt/install.sh"

echo "**********************************************************************"
echo "Running ssmt/90-first-boot.sh"

if [ -x "$INSTALL_FILE" ]; then
	"$INSTALL_FILE" -y
else
	echo "[warn] Missing installer: $INSTALL_FILE"
fi