#!/bin/bash

# No `set -e`: a failing copy step or product script must never abort the install.
set -uo pipefail

readonly EARLY_LOG_FILE="/var/log/triveni-install.log"
readonly TARGET_LOG_FILE="/target/var/log/triveni-install.log"
readonly LOG_FILE="/var/log/triveni-install.log"
readonly TARGET_INSTALL_ROOT="/target/var/triveni/install"
readonly TARGET_PRODUCT_SCRIPTS_ROOT="$TARGET_INSTALL_ROOT/product-scripts"
readonly TARGET_FIRST_BOOT_SCRIPT="$TARGET_INSTALL_ROOT/first-boot.sh"
readonly TARGET_FIRST_BOOT_SERVICE="$TARGET_INSTALL_ROOT/first-boot.service"
readonly TARGET_DRIVERS_ROOT="/target/var/triveni/drivers"
readonly TARGET_RESOURCES_ROOT="/target/var/triveni/install"

NO_RESTORE=false
SKIP_PRODUCT_SCRIPTS=false

mkdir -p /var/log || true
exec > >(tee -a "$LOG_FILE") 2>&1

echo "**********************************************************************"
echo "Running late-commands.sh"

parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--no-restore)
				NO_RESTORE=true
				;;
			--skip-product-scripts)
				SKIP_PRODUCT_SCRIPTS=true
				;;
			-h|--help)
				echo "Usage: $0 [--no-restore] [--skip-product-scripts]"
				echo "  --no-restore  Copy product backups into /target/var/triveni/install/backup.bak"
				exit 0
				;;
			*)
				echo "ERROR: Unknown option: $1"
				echo "Usage: $0 [--no-restore] [--skip-product-scripts]"
				exit 1
				;;
			esac
		shift
	done
}

copy_target_log() {
	mkdir -p /target/var/log || true
	if [ -f "$EARLY_LOG_FILE" ]; then
		cp -a "$EARLY_LOG_FILE" "$TARGET_LOG_FILE" || true
	else
		: > "$TARGET_LOG_FILE" || true
	fi
}

copy_install_payloads() {
	echo "Copying install payloads into $TARGET_INSTALL_ROOT"
	mkdir -p "$TARGET_INSTALL_ROOT"
	cp -Ra /cdrom/pool/install/* "$TARGET_INSTALL_ROOT"
	chmod +x "$TARGET_INSTALL_ROOT"/*.sh 2>/dev/null || true
}

copy_driver_payloads() {
	if [ -d /cdrom/pool/install/drivers ]; then
		echo "Copying driver payloads into $TARGET_DRIVERS_ROOT"
		mkdir -p "$TARGET_DRIVERS_ROOT"
		cp -Ra /cdrom/pool/install/drivers/. "$TARGET_DRIVERS_ROOT/"
		find "$TARGET_DRIVERS_ROOT" -maxdepth 1 -type f -name "*.sh" -exec chmod +x {} +
	fi
}

copy_resources() {
	echo "Copying OS resources into $TARGET_RESOURCES_ROOT"
	mkdir -p "$TARGET_RESOURCES_ROOT"
		cp -Ra /cdrom/pool/os-extras/extras/. "$TARGET_RESOURCES_ROOT/"
	find "$TARGET_RESOURCES_ROOT" -maxdepth 1 -type f -name "*.sh" -exec chmod +x {} +
}

install_first_boot_service() {
	if [ -f "$TARGET_FIRST_BOOT_SERVICE" ]; then
		echo "Installing first-boot.service into target systemd configuration"
		mkdir -p /target/etc/systemd/system
		mkdir -p /target/etc/systemd/system/graphical.target.wants
		cp -a "$TARGET_FIRST_BOOT_SERVICE" /target/etc/systemd/system/first-boot.service
		chmod 0644 /target/etc/systemd/system/first-boot.service
		ln -sf /etc/systemd/system/first-boot.service /target/etc/systemd/system/graphical.target.wants/first-boot.service
	fi
}

copy_first_boot_payloads() {
	if [ -f /cdrom/scripts/first-boot.sh ]; then
		echo "Copying first-boot.sh into $TARGET_FIRST_BOOT_SCRIPT"
		mkdir -p "$TARGET_INSTALL_ROOT"
		cp -a /cdrom/scripts/first-boot.sh "$TARGET_FIRST_BOOT_SCRIPT"
		chmod +x "$TARGET_FIRST_BOOT_SCRIPT"
	fi

	if [ -f /cdrom/scripts/first-boot.service ]; then
		echo "Copying first-boot.service into $TARGET_FIRST_BOOT_SERVICE"
		mkdir -p "$TARGET_INSTALL_ROOT"
		cp -a /cdrom/scripts/first-boot.service "$TARGET_FIRST_BOOT_SERVICE"
		chmod 0644 "$TARGET_FIRST_BOOT_SERVICE"
	fi
}

copy_product_scripts() {
	if [ -d /cdrom/scripts/product-scripts ]; then
		echo "Copying product-scripts into $TARGET_PRODUCT_SCRIPTS_ROOT"
		mkdir -p "$TARGET_INSTALL_ROOT"
		cp -Ra /cdrom/scripts/product-scripts "$TARGET_INSTALL_ROOT/"
		find "$TARGET_PRODUCT_SCRIPTS_ROOT" -type f -name "*.sh" -exec chmod +x {} +
		install_first_boot_service
	fi
}

collect_product_scripts() {
	shopt -s nullglob
	late_command_scripts=(/cdrom/scripts/product-scripts/*/*late-commands.sh)
	shopt -u nullglob

	if [ "${#late_command_scripts[@]}" -eq 0 ]; then
		echo "No *late-commands.sh scripts found under /cdrom/scripts/product-scripts/."
		return 0
	fi

	mapfile -t sorted_late_command_scripts < <(
		for late_command_script in "${late_command_scripts[@]}"; do
			printf '%s\t%s\n' "$(basename "$late_command_script")" "$late_command_script"
		done | sort | awk -F '\t' '{print $2}'
	)
}

execute_product_scripts() {
	echo "Starting product late-commands scan..."
	sorted_late_command_scripts=()
	collect_product_scripts
	total_scripts=0
	failed_scripts=0

	if [ "${#sorted_late_command_scripts[@]}" -eq 0 ]; then
		echo "Completed product late-commands scan."
		return 0
	fi

	total_scripts="${#sorted_late_command_scripts[@]}"

	for late_command_script in "${sorted_late_command_scripts[@]}"; do
		if [ "$SKIP_PRODUCT_SCRIPTS" = true ] && [[ "$late_command_script" == *in-target-late-commands.sh ]]; then
			echo "Skipping offline package script: $late_command_script"
			continue
		fi
		echo "Running late-commands script: $late_command_script"
		if [ "$NO_RESTORE" = true ]; then
			if TRIVENI_PARENT_LOG_REDIRECT=1 "$late_command_script" --no-restore; then
				echo "Late-commands script succeeded: $late_command_script"
			else
				echo "WARNING: Late-commands script failed: $late_command_script"
				failed_scripts=$((failed_scripts + 1))
			fi
		else
			if TRIVENI_PARENT_LOG_REDIRECT=1 "$late_command_script"; then
				echo "Late-commands script succeeded: $late_command_script"
			else
				echo "WARNING: Late-commands script failed: $late_command_script"
				failed_scripts=$((failed_scripts + 1))
			fi
		fi
	done

	echo "Completed product late-commands scan: ${total_scripts} script(s), ${failed_scripts} failure(s)."
}

main() {
	parse_args "$@"

	local failed_steps=0
	local step
	for step in copy_install_payloads copy_driver_payloads \
		copy_resources copy_first_boot_payloads copy_product_scripts; do
		if ! "$step"; then
			echo "WARNING: late-commands step failed, continuing: $step"
			failed_steps=$((failed_steps + 1))
		fi
	done

	# --skip-product-scripts only suppresses *in-target-late-commands.sh, which curtin
	# runs separately inside the target; the remaining product scripts still run here.
	execute_product_scripts || echo "WARNING: product late-commands scan reported errors"

	echo "Completed late-commands.sh: ${failed_steps} setup step failure(s)."

	# Snapshot the installer log last so the target copy includes this script's output;
	# in-target scripts append to the target copy from here on.
	sleep 1
	copy_target_log
	exit 0
}

main "$@"