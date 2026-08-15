#!/bin/bash

# Runs first in the in-target stage so every later product script (and the first-boot
# product installers) finds its dependencies already installed, with no network.

set -uo pipefail

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

readonly REPO_SRC="/cdrom/packages"
readonly REPO_DEST="/var/triveni/packages"
readonly SOURCES_FILE="/etc/apt/sources.list.d/triveni-offline.list"
readonly OFFLINE_APT_CONFIG="/etc/apt/apt.conf.d/00-triveni-install-offline"
readonly OFFLINE_APT_CONFIG_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/filesystem/etc/apt/apt.conf.d/00-triveni-install-offline"
readonly KERNEL_PIN_FILE="/etc/apt/preferences.d/99-kernel-6.8-only.pref"
readonly UNATTENDED_UPGRADE="/usr/bin/unattended-upgrade"

# Restricting apt to the local repository guarantees no step can stall on the network.
readonly APT_OPTS=(
    -o Dpkg::Use-Pty=0
    -o APT::Color=0
    -o Acquire::Retries=0
    -o APT::Get::List-Cleanup=0
    -o Dir::Etc::sourcelist="$SOURCES_FILE"
    -o Dir::Etc::sourceparts=/dev/null
)

warn() { echo "[offline-packages][warn] $*" >&2; }
log() { echo "[offline-packages] $*"; }

echo "**********************************************************************"
echo "Running os/10-in-target-late-commands.sh (installing offline dependencies)"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "This script must run as root" >&2
    exit 1
fi

repo_dir=""
if [ -f "$REPO_SRC/Packages" ]; then
    log "Copying offline repository to $REPO_DEST"
    mkdir -p "$REPO_DEST"
    cp -a "$REPO_SRC"/. "$REPO_DEST/" || warn "Could not fully copy the offline repository"
    repo_dir="$REPO_DEST"
elif [ -f "$REPO_DEST/Packages" ]; then
    repo_dir="$REPO_DEST"
else
    warn "No offline repository found at $REPO_SRC or $REPO_DEST; skipping"
    exit 0
fi

printf 'deb [trusted=yes] file:%s ./\n' "$repo_dir" > "$SOURCES_FILE"

# This applies to apt calls launched by package maintainer scripts too.
if [ -f "$OFFLINE_APT_CONFIG_SRC" ]; then
    mkdir -p "$(dirname "$OFFLINE_APT_CONFIG")"
    cp -a "$OFFLINE_APT_CONFIG_SRC" "$OFFLINE_APT_CONFIG"
    log "Restricted apt to the offline repository until first boot completes"
else
    warn "Offline apt configuration is missing: $OFFLINE_APT_CONFIG_SRC"
fi

# The triveni-drivers postinst rewrites sources.list to archive.ubuntu.com; snapshot
# the working configuration now so os/90 can put it back afterwards.
readonly APT_BACKUP_DIR="/var/triveni/apt-backup"
if [ ! -d "$APT_BACKUP_DIR" ]; then
    mkdir -p "$APT_BACKUP_DIR"
    [ -f /etc/apt/sources.list ] && cp -a /etc/apt/sources.list "$APT_BACKUP_DIR/sources.list"
    [ -d /etc/apt/sources.list.d ] && cp -a /etc/apt/sources.list.d "$APT_BACKUP_DIR/sources.list.d"
    log "Backed up apt configuration to $APT_BACKUP_DIR"
fi

if [ -f "$repo_dir/kernel-pin.pref" ]; then
    mkdir -p "$(dirname "$KERNEL_PIN_FILE")"
    cp -a "$repo_dir/kernel-pin.pref" "$KERNEL_PIN_FILE"
fi

apt-get "${APT_OPTS[@]}" update || warn "Could not index the offline repository"

install_packages=()
if [ -f "$repo_dir/install-list" ]; then
    while IFS= read -r package; do
        [ -n "$package" ] || continue
        install_packages+=("$package")
    done < "$repo_dir/install-list"
fi

if [ "${#install_packages[@]}" -gt 0 ]; then
    log "Installing ${#install_packages[@]} package(s) from the offline repository"
    if ! apt-get "${APT_OPTS[@]}" -y --no-install-recommends install "${install_packages[@]}"; then
        warn "Bulk install failed; retrying individually"
        for package in "${install_packages[@]}"; do
            apt-get "${APT_OPTS[@]}" -y --no-install-recommends install "$package" ||
                warn "Could not install: $package"
        done
    fi
else
    warn "Offline repository has no install-list"
fi

apt-get "${APT_OPTS[@]}" -y -f install || warn "Dependency repair step reported errors"

if ! compgen -G '/boot/vmlinuz-6.8.*-generic' >/dev/null; then
    echo "[offline-packages][error] No bootable 6.8 generic kernel was installed" >&2
    exit 1
fi

held_kernel_packages="$(dpkg-query -W -f='${binary:Package}\n' \
    'linux-image-6.8.*' 'linux-headers-6.8.*' 'linux-modules-6.8.*' 'linux-modules-extra-6.8.*' 2>/dev/null)"
if [ -n "$held_kernel_packages" ]; then
    # shellcheck disable=SC2086
    apt-mark hold $held_kernel_packages || warn "Could not hold the 6.8 kernel packages"
fi

update-initramfs -u -k all || warn "Could not update the initramfs"

if [ -x "$UNATTENDED_UPGRADE" ] && [ ! -f "${UNATTENDED_UPGRADE}.triveni-original" ]; then
    mv "$UNATTENDED_UPGRADE" "${UNATTENDED_UPGRADE}.triveni-original"
    cat > "$UNATTENDED_UPGRADE" <<'UNATTENDED_UPGRADE_STUB'
#!/bin/sh
exit 0
UNATTENDED_UPGRADE_STUB
    chmod 755 "$UNATTENDED_UPGRADE"
fi

log "Offline dependency installation complete"
exit 0
