#!/bin/bash

# Picks the NVIDIA driver branch for the installed GPU straight from the offline
# repository's own Modaliases metadata. ubuntu-drivers cannot be used here: it
# rewrites the apt sources and needs the network.

set -uo pipefail

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_DIR="/var/triveni/packages"
readonly MODALIAS_FILE="$REPO_DIR/nvidia-modaliases"
readonly BRANCH_PACKAGES_FILE="$SCRIPT_DIR/branch-packages"
readonly SOURCES_FILE="/etc/apt/sources.list.d/triveni-offline.list"
readonly NVIDIA_VENDOR="0x10de"

readonly APT_OPTS=(
    -o Dpkg::Use-Pty=0
    -o APT::Color=0
    -o Acquire::Retries=0
    -o APT::Get::List-Cleanup=0
    -o Dir::Etc::sourcelist="$SOURCES_FILE"
    -o Dir::Etc::sourceparts=/dev/null
)

warn() { echo "[nvidia-driver][warn] $*" >&2; }
log() { echo "[nvidia-driver] $*"; }

echo "**********************************************************************"
echo "Running os/20-in-target-late-commands.sh (selecting the NVIDIA driver)"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "This script must run as root" >&2
    exit 1
fi

if [ ! -f "$MODALIAS_FILE" ]; then
    warn "No NVIDIA modalias table at $MODALIAS_FILE; skipping"
    exit 0
fi

if [ ! -f "$BRANCH_PACKAGES_FILE" ]; then
    warn "No branch package map at $BRANCH_PACKAGES_FILE; skipping"
    exit 0
fi

# Read PCI IDs from sysfs so this works without pciutils installed.
gpu_ids=()
for device_path in /sys/bus/pci/devices/*; do
    [ -r "$device_path/vendor" ] && [ -r "$device_path/device" ] || continue
    [ "$(cat "$device_path/vendor")" = "$NVIDIA_VENDOR" ] || continue
    case "$(cat "$device_path/class")" in
        0x03*) ;;
        *) continue ;;
    esac
    gpu_ids+=("$(printf '%04X' "$(cat "$device_path/device")")")
done

if [ "${#gpu_ids[@]}" -eq 0 ]; then
    log "No NVIDIA GPU detected; nothing to install"
    exit 0
fi

log "Detected NVIDIA GPU(s): ${gpu_ids[*]}"

# A single driver has to serve every GPU in the box, so keep only the branches that
# match all of them.
candidates=""
for gpu_id in "${gpu_ids[@]}"; do
    matches="$(awk -v target="d0000${gpu_id}sv" '
        index($0, target) > 0 { print $1 }
    ' "$MODALIAS_FILE" | sort -u)"

    if [ -z "$matches" ]; then
        warn "No cached NVIDIA driver supports device 10DE:$gpu_id"
        continue
    fi

    if [ -z "$candidates" ]; then
        candidates="$matches"
    else
        candidates="$(comm -12 <(printf '%s\n' "$candidates") <(printf '%s\n' "$matches"))"
    fi
done

if [ -z "$candidates" ]; then
    warn "No cached NVIDIA driver supports every detected GPU; leaving nouveau in place"
    exit 0
fi

selected_branch="$(printf '%s\n' $candidates | sort -n | tail -n 1)"

# 470 has to be installed by component, so the branch maps to a package list.
read -r -a selected_packages <<< "$(awk -v branch="$selected_branch" '
    $1 == branch { $1 = ""; sub(/^[[:space:]]+/, ""); print; exit }
' "$BRANCH_PACKAGES_FILE")"

if [ "${#selected_packages[@]}" -eq 0 ]; then
    warn "No package list defined for branch $selected_branch in $BRANCH_PACKAGES_FILE"
    exit 0
fi

log "Selected branch $selected_branch (candidates: $(printf '%s ' $candidates))"
log "Installing: ${selected_packages[*]}"

if apt-get "${APT_OPTS[@]}" -y --no-install-recommends install "${selected_packages[@]}"; then
    log "Installed NVIDIA driver branch $selected_branch"
else
    warn "Could not install NVIDIA branch $selected_branch; the system will fall back to nouveau"
fi

exit 0
