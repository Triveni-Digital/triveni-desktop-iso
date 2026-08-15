#!/bin/bash

set -u

LOG_FILE="/var/log/triveni-install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "Starting product early-commands scan..."

total_scripts=0
failed_scripts=0

shopt -s nullglob
early_command_scripts=(/cdrom/scripts/product-scripts/*/*early-commands.sh)
shopt -u nullglob

if [ "${#early_command_scripts[@]}" -eq 0 ]; then
	echo "No *early-commands.sh scripts found under /cdrom/scripts/product-scripts/."
	exit 0
fi

mapfile -t sorted_early_command_scripts < <(
	for early_command_script in "${early_command_scripts[@]}"; do
		printf '%s\t%s\n' "$(basename "$early_command_script")" "$early_command_script"
	done | sort | awk -F '\t' '{print $2}'
)

total_scripts="${#sorted_early_command_scripts[@]}"

for early_command_script in "${sorted_early_command_scripts[@]}"; do
	echo "Running early-commands script: $early_command_script"
	if TRIVENI_PARENT_LOG_REDIRECT=1 "$early_command_script"; then
		echo "Early-commands script succeeded: $early_command_script"
	else
		echo "WARNING: Early-commands script failed: $early_command_script"
		failed_scripts=$((failed_scripts + 1))
	fi
done

echo "Completed product early-commands scan: ${total_scripts} script(s), ${failed_scripts} failure(s)."
exit 0
