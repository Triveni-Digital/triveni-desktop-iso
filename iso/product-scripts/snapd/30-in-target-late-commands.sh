#!/bin/bash

# Removes snapd before the system ever boots, so first-boot seeding never starts.
# Seeding the nine snaps in the base image contacts the store to validate assertions,
# and snapd.seeded.service has no timeout, so offline it blocks boot indefinitely.

set -uo pipefail

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

readonly SOURCES_FILE="/etc/apt/sources.list.d/triveni-offline.list"
readonly SNAPD_PIN_FILE="/etc/apt/preferences.d/99-no-snapd.pref"

readonly APT_OPTS=(
    -o Dpkg::Use-Pty=0
    -o APT::Color=0
    -o Acquire::Retries=0
    -o APT::Get::List-Cleanup=0
    -o Dir::Etc::sourcelist="$SOURCES_FILE"
    -o Dir::Etc::sourceparts=/dev/null
)

readonly SNAPD_UNITS=(
    snapd.seeded.service
    snapd.service
    snapd.socket
    snapd.autoimport.service
    snapd.core-fixup.service
    snapd.recovery-chooser-trigger.service
    snapd.apparmor.service
    snapd.snap-repair.timer
    snapd.snap-repair.service
    snapd.mounts.target
    snapd.mounts-pre.target
)

warn() { echo "[snapd-removal][warn] $*" >&2; }
log() { echo "[snapd-removal] $*"; }

echo "**********************************************************************"
echo "Running snapd/30-in-target-late-commands.sh (removing snapd)"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "This script must run as root" >&2
    exit 1
fi

# Masked first so boot stays unblocked even if the purge below fails.
for unit in "${SNAPD_UNITS[@]}"; do
    systemctl mask "$unit" >/dev/null 2>&1 || true
done
log "Masked ${#SNAPD_UNITS[@]} snapd unit(s)"

if dpkg -s snapd >/dev/null 2>&1; then
    if apt-get "${APT_OPTS[@]}" -y purge snapd; then
        log "Purged snapd"
    else
        warn "Could not purge snapd; the masked units will keep it from blocking boot"
    fi
else
    log "snapd is not installed"
fi

for snap_dir in /var/lib/snapd /var/cache/snapd /var/snap /snap /root/snap; do
    [ -e "$snap_dir" ] || continue
    rm -rf "$snap_dir" || warn "Could not remove $snap_dir"
done
rm -rf /etc/skel/snap

mkdir -p "$(dirname "$SNAPD_PIN_FILE")"
cat > "$SNAPD_PIN_FILE" <<'PIN'
Package: snapd
Pin: release *
Pin-Priority: -1
PIN

log "snapd removed and pinned out"
exit 0
