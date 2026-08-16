#!/bin/bash

set -euo pipefail

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root. Please use sudo."
    exit 1
fi


export DEBIAN_FRONTEND=noninteractive

readonly LOCAL_CHROME_DIR="/var/triveni/install"
readonly SOURCES_FILE="/etc/apt/sources.list.d/triveni-offline.list"
readonly EMPTY_SOURCEPARTS_DIR="/var/lib/triveni/empty-sources.list.d"

# Pinning apt to the offline repo keeps this from reaching the network, without
# --no-download, which cannot install from a file: repo's relative Filename.
readonly APT_OPTS=(
	-o Dpkg::Use-Pty=0
	-o APT::Color=0
	-o Acquire::Retries=0
	-o APT::Get::List-Cleanup=0
	-o Dir::Etc::sourcelist="$SOURCES_FILE"
	-o Dir::Etc::sourceparts="$EMPTY_SOURCEPARTS_DIR"
)


echo "**********************************************************************"
echo "Running chrome/in-target-late-commands.sh"

require_commands() {
	local cmd
	for cmd in apt-get dpkg; do
		command -v "$cmd" >/dev/null 2>&1 || {
			echo "Missing required command: $cmd" >&2
			exit 1
		}
	done
}

find_local_chrome_deb() {
	local -a local_debs=()

	shopt -s nullglob
	local_debs=("$LOCAL_CHROME_DIR"/google-chrome*.deb)
	shopt -u nullglob

	if [ "${#local_debs[@]}" -gt 0 ]; then
		echo "${local_debs[0]}"
		return 0
	fi

	return 1
}

disable_chrome_repo_sources() {
	# google-chrome postinst may add a dl.google.com apt source; disable it
	# so subsequent installer apt updates do not depend on that host.
	rm -f /etc/apt/sources.list.d/google-chrome.list
	rm -f /etc/apt/sources.list.d/google-chrome.sources
	rm -f "$EMPTY_SOURCEPARTS_DIR/google-chrome.list"
	rm -f "$EMPTY_SOURCEPARTS_DIR/google-chrome.sources"
}

main() {
	require_commands
	mkdir -p "$EMPTY_SOURCEPARTS_DIR"

	if dpkg -s google-chrome-stable >/dev/null 2>&1; then
		echo "[chrome/in-target-late-commands] Google Chrome already installed"
		exit 0
	fi

	if local_deb=$(find_local_chrome_deb); then
		echo "[chrome/in-target-late-commands] Installing Chrome from local package: $local_deb"
		if apt-get "${APT_OPTS[@]}" install -y "$local_deb"; then
			disable_chrome_repo_sources
			echo "[chrome/in-target-late-commands] Google Chrome installed successfully from local package"
			exit 0
		fi
		echo "[chrome/in-target-late-commands] Local Chrome package install failed"
		exit 1
	fi

	echo "[chrome/in-target-late-commands] Local Chrome package not found; skipping offline installation"
}

main "$@"