#!/bin/bash

# Runs inside a chroot of the pristine target squashfs during ISO creation. Resolves
# every product dependency against the image's real package set and downloads the
# missing debs into a flat apt repository that ships on the ISO. The squashfs itself
# is never modified, so the installed system's dpkg database stays consistent.

set -uo pipefail

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

readonly REPO_DIR="/tmp/offline-repo"
readonly GROUPS_FILE="/tmp/product-package-groups"
readonly CACHE_ONLY_FILE="/tmp/product-package-cache-only"
readonly EXTRAS_DIR="/tmp/triveni-extras"
readonly KERNEL_PIN_FILE="/etc/apt/preferences.d/99-kernel-6.8-only.pref"
readonly APT_OPTS=(-o Dpkg::Use-Pty=0 -o APT::Color=0 -o Acquire::Retries=3)

warn() { echo "[collect-packages][warn] $*" >&2; }
log() { echo "[collect-packages] $*"; }

mkdir -p "$REPO_DIR"

cat > /usr/sbin/policy-rc.d <<'POLICY'
#!/bin/sh
exit 101
POLICY
chmod +x /usr/sbin/policy-rc.d

apt-get "${APT_OPTS[@]}" -o APT::Get::List-Cleanup=0 update

# Package groups use "a|b|c" to mean "first one that exists in the archive".
resolve_package() {
    local candidate
    local -a candidates
    IFS='|' read -r -a candidates <<< "$1"
    for candidate in "${candidates[@]}"; do
        candidate="$(echo "$candidate" | xargs)"
        [ -n "$candidate" ] || continue
        if apt-cache policy "$candidate" 2>/dev/null |
            awk '/Candidate:/ && $2 != "(none)" {found=1} END {exit !found}'; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

packages=()
while IFS= read -r package_group; do
    [ -n "$package_group" ] || continue
    if resolved="$(resolve_package "$package_group")"; then
        packages+=("$resolved")
    else
        warn "Unable to resolve package group: $package_group"
    fi
done < "$GROUPS_FILE"

# Pin before resolving so the downloaded upgrade set matches what the target will pick.
image_package="$(apt-cache pkgnames linux-image-6.8.0- 2>/dev/null | grep -E -- '-generic$' | sort -V | tail -n 1)"
if [ -n "$image_package" ]; then
    kernel_suffix="${image_package#linux-image-}"
    kernel_header_version="${kernel_suffix%-generic}"
    for kernel_package in "$image_package" \
        "linux-modules-$kernel_suffix" \
        "linux-modules-extra-$kernel_suffix" \
        "linux-headers-$kernel_suffix" \
        "linux-headers-$kernel_header_version"; do
        apt-cache show "$kernel_package" >/dev/null 2>&1 && packages+=("$kernel_package")
    done
else
    warn "No linux-image-6.8.0-*-generic package found"
fi

mkdir -p /etc/apt/preferences.d
cat > "$KERNEL_PIN_FILE" <<'PIN'
Package: linux-image-[0-9]* linux-headers-[0-9]* linux-modules-[0-9]* linux-modules-extra-[0-9]*
Pin: version 6.8.*
Pin-Priority: 1001

Package: linux-image-[0-9]* linux-headers-[0-9]* linux-modules-[0-9]* linux-modules-extra-[0-9]*
Pin: version *
Pin-Priority: -1
PIN

log "Downloading ${#packages[@]} resolved package(s) and their dependencies"
if [ "${#packages[@]}" -gt 0 ]; then
    apt-get "${APT_OPTS[@]}" -y --download-only install "${packages[@]}" ||
        warn "Some product dependencies could not be downloaded"
fi

# grub-pc and grub-efi-amd64 conflict, so they must be fetched one at a time and only
# cached; curtin picks whichever the target's firmware needs.
for bootloader_package in grub-pc grub-pc-bin grub-efi-amd64 grub-efi-amd64-bin \
    grub-efi-amd64-signed shim-signed; do
    apt-cache show "$bootloader_package" >/dev/null 2>&1 || continue
    apt-get "${APT_OPTS[@]}" -y --download-only install "$bootloader_package" ||
        warn "Could not cache bootloader package: $bootloader_package"
done

# Same treatment for mutually exclusive packages declared by products, such as the
# NVIDIA driver branches: cached for every supported GPU, installed by none.
if [ -f "$CACHE_ONLY_FILE" ]; then
    while IFS= read -r cache_only_group; do
        [ -n "$cache_only_group" ] || continue
        if ! cache_only_package="$(resolve_package "$cache_only_group")"; then
            warn "Unable to resolve cache-only package group: $cache_only_group"
            continue
        fi
        log "Caching (not installing): $cache_only_package"
        apt-get "${APT_OPTS[@]}" -y --download-only install "$cache_only_package" ||
            warn "Could not cache package: $cache_only_package"

        # Record PCI IDs per driver branch. The newest nvidia-driver-* versions drop
        # the Modaliases field, so take it from whichever version still publishes it.
        case "$cache_only_package" in
            *nvidia*)
                nvidia_branch="${cache_only_package##*-}"
                case "$nvidia_branch" in
                    ''|*[!0-9]*) nvidia_branch="" ;;
                esac
                if [ -n "$nvidia_branch" ] &&
                    ! grep -q "^${nvidia_branch} " "$REPO_DIR/nvidia-modaliases" 2>/dev/null; then
                    modaliases="$(apt-cache show "nvidia-driver-$nvidia_branch" 2>/dev/null |
                        grep '^Modaliases:' | head -1)"
                    if [ -n "$modaliases" ]; then
                        printf '%s %s\n' "$nvidia_branch" "${modaliases#Modaliases: }" \
                            >> "$REPO_DIR/nvidia-modaliases"
                    else
                        warn "No Modaliases published for nvidia-driver-$nvidia_branch; it cannot be auto-selected"
                    fi
                fi
                ;;
        esac
    done < "$CACHE_ONLY_FILE"
fi

shopt -s nullglob
for extra_deb in "$EXTRAS_DIR"/*.deb; do
    apt-get "${APT_OPTS[@]}" -y --download-only install "$extra_deb" ||
        warn "Could not download dependencies for $(basename "$extra_deb")"
done
shopt -u nullglob

# Cached, never installed by the in-target stage: this is what lets a later offline
# apt run satisfy a dependency that needs a newer version than the base image ships.
apt-get "${APT_OPTS[@]}" -y --download-only upgrade || warn "Could not download the full upgrade set"

shopt -s nullglob
cached_debs=(/var/cache/apt/archives/*.deb)
shopt -u nullglob
[ "${#cached_debs[@]}" -gt 0 ] || { echo "[collect-packages][error] No packages were downloaded" >&2; exit 1; }
cp -a "${cached_debs[@]}" "$REPO_DIR/"

# The product and extras debs are shipped under pool/install already; only their
# dependencies belong here, otherwise they would be carried on the ISO twice.

# Built by hand rather than with dpkg-scanpackages so dpkg-dev never has to be
# installed here, keeping this chroot an exact stand-in for the target.
log "Indexing $(find "$REPO_DIR" -maxdepth 1 -name '*.deb' | wc -l) package(s)"
(
    cd "$REPO_DIR" || exit 1
    : > Packages
    for repo_deb in *.deb; do
        dpkg-deb -f "$repo_deb" >> Packages
        printf 'Filename: ./%s\n' "$repo_deb" >> Packages
        printf 'Size: %s\n' "$(stat -c%s "$repo_deb")" >> Packages
        printf 'SHA256: %s\n' "$(sha256sum "$repo_deb" | cut -d' ' -f1)" >> Packages
        printf '\n' >> Packages
    done
    gzip -9c Packages > Packages.gz
)
[ -s "$REPO_DIR/Packages" ] || { echo "[collect-packages][error] Package index is empty" >&2; exit 1; }

printf '%s\n' "${packages[@]}" > "$REPO_DIR/install-list"
cp -a "$KERNEL_PIN_FILE" "$REPO_DIR/kernel-pin.pref"

# Nothing was installed in this chroot, so its package state still matches a freshly
# installed target. Proving the set resolves from the repo alone catches a broken ISO
# here instead of on a customer's machine.
readonly VALIDATION_LIST="/tmp/offline-repo.list"
printf 'deb [trusted=yes] file:%s ./\n' "$REPO_DIR" > "$VALIDATION_LIST"
readonly VALIDATION_OPTS=(
    "${APT_OPTS[@]}"
    -o Dir::Etc::sourcelist="$VALIDATION_LIST"
    -o Dir::Etc::sourceparts=/dev/null
    -o APT::Get::List-Cleanup=0
)

log "Verifying the offline repository can satisfy the install with no network"
apt-get "${VALIDATION_OPTS[@]}" update >/dev/null 2>&1
if apt-get "${VALIDATION_OPTS[@]}" -s -y --no-install-recommends install "${packages[@]}" >/tmp/offline-validation.log 2>&1; then
    log "Verified: $(grep -c '^Inst ' /tmp/offline-validation.log) package(s) installable offline"
else
    echo "[collect-packages][error] Offline repository cannot satisfy the install list:" >&2
    grep -E '^(E:|.*but it is not going to be installed|.*is not installable)' /tmp/offline-validation.log >&2 | head -30
    exit 1
fi

rm -f /usr/sbin/policy-rc.d
log "Offline repository ready at $REPO_DIR"
