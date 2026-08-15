#!/bin/bash

# No `set -e`: a failing product script must never abort the rest of the install.
set -uo pipefail

readonly LOG_FILE="/var/log/triveni-install.log"
readonly PRODUCT_SCRIPTS_ROOT="/var/triveni/install/product-scripts"

mkdir -p /var/log || true
exec > >(tee -a "$LOG_FILE") 2>&1

on_exit() {
	local rc=$?
	echo "[install-in-target] Exit code: $rc at $(date -Is 2>/dev/null || date)"
}
trap on_exit EXIT

echo "**********************************************************************"
echo "Running in-target-late-commands.sh (executing product in-target late command scripts)"
echo "[install-in-target] Start time: $(date -Is 2>/dev/null || date)"
echo "[install-in-target] Root filesystem source: $(findmnt -n -o SOURCE / 2>/dev/null || echo unknown)"

require_root() {
	if [ "${EUID:-$(id -u)}" -ne 0 ]; then
		echo "This script must run as root" >&2
		exit 1
	fi
}

require_commands() {
	command -v find >/dev/null 2>&1 || {
		echo "Missing required command: find" >&2
		exit 1
	}
}

collect_in_target_scripts() {
	shopt -s nullglob
	in_target_scripts=("$PRODUCT_SCRIPTS_ROOT"/*/*in-target-late-commands.sh)
	shopt -u nullglob

	if [ "${#in_target_scripts[@]}" -eq 0 ]; then
		echo "[install-in-target] No *in-target-late-commands.sh files found under $PRODUCT_SCRIPTS_ROOT"
		return 0
	fi

	mapfile -t sorted_in_target_scripts < <(
		for in_target_script in "${in_target_scripts[@]}"; do
			printf '%s\t%s\n' "$(basename "$in_target_script")" "$in_target_script"
		done | sort | awk -F '\t' '{print $2}'
	)
}

execute_in_target_scripts() {
	local in_target_script
	local total_scripts=0
	local failed_scripts=0

	echo "[install-in-target] Scanning product in-target late command scripts"
	sorted_in_target_scripts=()
	collect_in_target_scripts

	if [ "${#sorted_in_target_scripts[@]}" -eq 0 ]; then
		echo "[install-in-target] No product in-target late command scripts to execute"
		return 0
	fi

	total_scripts="${#sorted_in_target_scripts[@]}"

	for in_target_script in "${sorted_in_target_scripts[@]}"; do
		echo "[install-in-target] Running $in_target_script"
		if ! "$in_target_script"; then
			echo "[install-in-target] WARNING: Script failed, continuing: $in_target_script"
			failed_scripts=$((failed_scripts + 1))
		fi
	done

	echo "[install-in-target] Completed product in-target late command scan: ${total_scripts} script(s), ${failed_scripts} failure(s)."
}

main() {
	require_root
	require_commands

	echo "[install-in-target] uname -r: $(uname -r 2>/dev/null || echo unknown)"
	execute_in_target_scripts
	echo "[install-in-target] Completed at: $(date -Is 2>/dev/null || date)"
	exit 0
}

main "$@"