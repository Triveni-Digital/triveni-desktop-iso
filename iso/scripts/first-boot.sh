#!/bin/bash

# No `set -e`: a failing component must never abort the rest of first boot.
set -uo pipefail

readonly LOG_FILE="/var/log/triveni-install.log"
readonly INSTALL_ROOT="/var/triveni/install"
readonly FIRST_BOOT_ROOT="$INSTALL_ROOT/first-boot.sh"
readonly FIRST_BOOT_SERVICE="$INSTALL_ROOT/first-boot.service"
readonly COMPONENT_ROOT="$INSTALL_ROOT/product-scripts"
readonly STAMP_DIR="/var/lib/triveni"
readonly STAMP_FILE="$STAMP_DIR/.first-boot-complete"
readonly SERVICE_NAME="first-boot.service"
readonly UNATTENDED_UPGRADE="/usr/bin/unattended-upgrade"
readonly SAVED_UNATTENDED_UPGRADE="${UNATTENDED_UPGRADE}.triveni-original"
readonly OFFLINE_APT_CONFIG="/etc/apt/apt.conf.d/00-triveni-install-offline"
readonly EMPTY_SOURCEPARTS_DIR="/var/lib/triveni/empty-sources.list.d"

notify_status() {
    if command -v systemd-notify >/dev/null 2>&1 && systemd-notify --booted >/dev/null 2>&1; then
        systemd-notify --status="$*" >/dev/null 2>&1 || true
    fi
}

mkdir -p "$STAMP_DIR" || true
mkdir -p /var/log || true
exec > >(tee -a "$LOG_FILE") 2>&1

echo "**********************************************************************"
echo "Running first-boot.sh"
echo "[first-boot] Preparing first-boot tasks"
notify_status "Starting first-boot setup"

if [ -f "$STAMP_FILE" ]; then
    echo "[first-boot] First-boot tasks already completed, exiting"
    rm -f "$OFFLINE_APT_CONFIG"
    rm -rf "$EMPTY_SOURCEPARTS_DIR"
    notify_status "First-boot already complete"
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    exit 0
fi

if [ -f "$SAVED_UNATTENDED_UPGRADE" ]; then
    mv -f "$SAVED_UNATTENDED_UPGRADE" "$UNATTENDED_UPGRADE" || true
fi

echo "[first-boot] Scanning for component installers under $COMPONENT_ROOT"
notify_status "Scanning first-boot components"

install_scripts=()
total_scripts=0
failed_scripts=0

shopt -s nullglob
remaining_candidates=()
while IFS= read -r -d '' install_script; do
    remaining_candidates+=("$install_script")
done < <(find "$COMPONENT_ROOT" -type f -name '*first-boot.sh' ! -path "$COMPONENT_ROOT/first-boot.sh" -print0)
shopt -u nullglob

if [ "${#remaining_candidates[@]}" -gt 0 ]; then
    mapfile -t remaining_sorted < <(
        for install_script in "${remaining_candidates[@]}"; do
            printf '%s\t%s\n' "$(basename "$install_script")" "$install_script"
        done | sort | awk -F '\t' '{print $2}'
    )
    for install_script in "${remaining_sorted[@]}"; do
        if [ "$install_script" = "$FIRST_BOOT_ROOT" ]; then
            continue
        fi
        install_scripts+=("$install_script")
    done
fi

echo "[first-boot] Found ${#install_scripts[@]} component first-boot script(s)"

if [ "${#install_scripts[@]}" -eq 0 ]; then
    echo "[first-boot][warn] No component *first-boot.sh files found under $COMPONENT_ROOT"
    notify_status "No component installers found"
else
    total_scripts="${#install_scripts[@]}"
    current_script=0
    for install_script in "${install_scripts[@]}"; do
        current_script=$((current_script + 1))
        display_name="${install_script#"$COMPONENT_ROOT"/}"
        echo "[first-boot] Step ${current_script}/${total_scripts}: running $install_script"
        notify_status "Step ${current_script}/${total_scripts}: running ${display_name}"
        if ! "$install_script" -y; then
            failed_scripts=$((failed_scripts + 1))
            echo "[first-boot][warn] Component install failed: $install_script"
            notify_status "Step ${current_script}/${total_scripts}: ${display_name} failed"
        else
            echo "[first-boot] Step ${current_script}/${total_scripts}: completed $install_script"
            notify_status "Step ${current_script}/${total_scripts}: ${display_name} complete"
        fi
    done
fi

echo "[first-boot] Completed component first-boot scan: ${total_scripts} script(s), ${failed_scripts} failure(s)."
rm -f "$OFFLINE_APT_CONFIG"
rm -rf "$EMPTY_SOURCEPARTS_DIR"
echo "[first-boot] Restored normal apt source selection"

if [ "$failed_scripts" -ne 0 ]; then
    echo "[first-boot][error] First-boot tasks failed; keeping installer payloads for retry"
    notify_status "First-boot failed: ${failed_scripts} component(s)"
    exit 1
fi

echo "[first-boot] Writing completion stamp"
notify_status "Finalizing first-boot setup"
if ! touch "$STAMP_FILE"; then
    echo "[first-boot][error] Could not write completion stamp; keeping installer payloads for retry"
    notify_status "First-boot failed: completion stamp"
    exit 1
fi

echo "[first-boot] Removing completed first-boot installer payloads"
if ! rm -rf "$COMPONENT_ROOT" || ! rm -f "$FIRST_BOOT_SERVICE" "$FIRST_BOOT_ROOT"; then
    rm -f "$STAMP_FILE"
    echo "[first-boot][error] Could not remove every first-boot installer payload"
    notify_status "First-boot failed: installer payload cleanup"
    exit 1
fi
systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true

echo "[first-boot] First-boot tasks completed"
notify_status "First-boot complete, rebooting"
echo "[first-boot] Rebooting to finish setup"

if command -v systemd-notify >/dev/null 2>&1 && systemd-notify --booted >/dev/null 2>&1; then
    systemd-notify --ready --status="First-boot complete" >/dev/null 2>&1 || true
fi

if command -v systemctl >/dev/null 2>&1; then
    systemctl --no-block reboot || true
else
    reboot &
fi

exit 0
