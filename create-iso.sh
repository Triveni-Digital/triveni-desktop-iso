#!/bin/bash


set -euo pipefail

readonly DIST="dist"
readonly BUILD_DIR="build"
readonly USER_DATA_YAMLS=("legacy-auto-clean" "legacy-auto-upgrade" "legacy-manual-clean" "legacy-manual-upgrade" \
                          "uefi-auto-clean" "uefi-auto-upgrade" "uefi-manual-clean" "uefi-manual-upgrade")

ISO_IN=""
DEB_DIRS=""
ISO_OUT=""
ISO_DESC="triveni_desktop_24.04"
BUILD_TIMESTAMP=""
INSTALL_MENU_TITLE="Install Triveni Digital System"
WORK_DIR=""
ROOTFS_DIR=""
ROOTFS_SQUASHFS=""
ISO_DIR=""
RESOLV_BACKUP=""
declare -a DEB_FILES=()
declare -a PRODUCT_NAMES=()

log() { echo "[create-offline-iso] $*"; }
die() { echo "[create-offline-iso][error] $*" >&2; exit 1; }

cleanup_rootfs_mounts() {
    umount -R "$ROOTFS_DIR/run" 2>/dev/null || true
    umount -R "$ROOTFS_DIR/sys" 2>/dev/null || true
    umount -R "$ROOTFS_DIR/proc" 2>/dev/null || true
    umount "$ROOTFS_DIR/dev/pts" 2>/dev/null || true
    umount "$ROOTFS_DIR/dev" 2>/dev/null || true
    rm -f "$ROOTFS_DIR/etc/resolv.conf"
    if [ -e "$RESOLV_BACKUP" ]; then
        mv "$RESOLV_BACKUP" "$ROOTFS_DIR/etc/resolv.conf"
    fi
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "This script must be run as root"
}

usage() {
    cat <<EOF
Usage: $0 -i <base_iso> -p <deb_dir[:deb_dir...]>
EOF
}

require_commands() {
    local cmd
    for cmd in dpkg dpkg-deb xorriso unsquashfs find md5sum fdisk dd awk grep sed stat mount umount chroot; do
        command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
    done
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -i) [ "$#" -ge 2 ] || die "Missing value for -i"; ISO_IN="$2"; shift 2 ;;
            -p) [ "$#" -ge 2 ] || die "Missing value for -p"; DEB_DIRS="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown argument: $1" ;;
        esac
    done
}

validate_inputs() {
    [ -f "$ISO_IN" ] || die "Ubuntu ISO not found: $ISO_IN"
    [ -n "$DEB_DIRS" ] || die "At least one Debian directory is required via -p"
    [ -d iso/extras ] || die "Missing required directory: iso/extras"
    [ -d iso/product-scripts/os/filesystem ] || die "Missing required directory: iso/product-scripts/os/filesystem"
    [ -f iso/product-scripts/os/75-in-target-late-commands.sh ] || die "Missing required file: iso/product-scripts/os/75-in-target-late-commands.sh"
    [ -d iso/debs ] || die "Missing required directory: iso/debs"
    [ -d iso/scripts ] || die "Missing required directory: iso/scripts"
    [ -f iso/boot/grub.cfg ] || die "Missing required file: iso/boot/grub.cfg"
    [ -f iso/boot/grub_background.png ] || die "Missing required file: iso/boot/grub_background.png"
    [ -f collect-packages.sh ] || die "Missing required file: collect-packages.sh"
}

collect_debian_files() {
    local deb_dir deb_file package_name
    local -a deb_dirs=()
    local -A seen_products=()

    IFS=':' read -r -a deb_dirs <<< "$DEB_DIRS"
    for deb_dir in "${deb_dirs[@]}"; do
        [ -n "$deb_dir" ] || die "DEB_DIRS contains an empty directory path"
        [ -d "$deb_dir" ] || die "Debian directory not found: $deb_dir"
        shopt -s nullglob
        local debs=("$deb_dir"/*.deb)
        shopt -u nullglob
        [ "${#debs[@]}" -gt 0 ] || die "No .deb files found in $deb_dir"

        for deb_file in "${debs[@]}"; do
            package_name="$(basename "$deb_file")"
            [[ "$package_name" == *_*.deb ]] || die "Invalid Debian filename: $deb_file"
            package_name="${package_name%%_*}"
            [[ "$package_name" =~ ^[A-Za-z0-9][A-Za-z0-9+.-]*$ ]] || die "Invalid Debian filename: $deb_file"
            DEB_FILES+=("$deb_file")
            if [ -z "${seen_products[$package_name]+x}" ]; then
                seen_products[$package_name]=1
                PRODUCT_NAMES+=("$package_name")
            fi
        done
    done

    mapfile -t DEB_FILES < <(printf '%s\n' "${DEB_FILES[@]}" | LC_ALL=C sort)
}

print_debian_files() {
    log "Debian packages to install:"
    local deb_file
    for deb_file in "${DEB_FILES[@]}"; do
        printf '%s\n' "$(basename "$deb_file")"
    done
}

compute_output_name() {
    local deb_file package_name version
    for deb_file in "${DEB_FILES[@]}"; do
        package_name="$(dpkg-deb -f "$deb_file" Package)"
        version="$(dpkg-deb -f "$deb_file" Version)"
        [ "$ISO_DESC" = "streamscope-offline" ] || ISO_DESC="${ISO_DESC}__"
        ISO_DESC="${ISO_DESC}${package_name}_${version}"
    done
    BUILD_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
    ISO_OUT="$DIST/${ISO_DESC}_${BUILD_TIMESTAMP}.iso"
}

prepare_workspace() {
    WORK_DIR="$PWD/$BUILD_DIR/offline-iso-work"
    ISO_DIR="$PWD/$BUILD_DIR/iso"
    rm -rf "$PWD/$BUILD_DIR"
    mkdir -p "$PWD/$BUILD_DIR"
    mkdir -p "$WORK_DIR" "$ISO_DIR" "$DIST"
    rm -f "$DIST"/*.iso
    xorriso -osirrox on -indev "$ISO_IN" -extract / "$ISO_DIR"
    chmod -R +w "$ISO_DIR"
}

prepare_product_scripts() {
    mkdir -p "$WORK_DIR/target-product-scripts"
    cp -a iso/product-scripts/. "$WORK_DIR/target-product-scripts/"
    apply_product_script_overrides
}

apply_product_script_overrides() {
    local deb_dir deb_file product_name product_scripts_source
    local -a deb_dirs=()
    local -A replaced_products=()

    IFS=':' read -r -a deb_dirs <<< "$DEB_DIRS"
    for deb_dir in "${deb_dirs[@]}"; do
        product_scripts_source="$deb_dir/iso/24.04/desktop"
        [ -d "$product_scripts_source" ] || continue

        shopt -s nullglob
        local debs=("$deb_dir"/*.deb)
        shopt -u nullglob
        for deb_file in "${debs[@]}"; do
            product_name="$(basename "$deb_file")"
            product_name="${product_name%%_*}"
            [ -z "${replaced_products[$product_name]+x}" ] || continue
            replaced_products[$product_name]=1

            rm -rf "$WORK_DIR/target-product-scripts/$product_name"
            mkdir -p "$WORK_DIR/target-product-scripts/$product_name"
            cp -a "$product_scripts_source/." "$WORK_DIR/target-product-scripts/$product_name/"
            log "Using product scripts from $product_scripts_source for $product_name"
        done
    done
}

validate_autoinstall_kernel_packages() {
    local manifest="$ISO_DIR/casper/filesystem.manifest"
    local profile
    local kernel_package

    [ -f "$manifest" ] || die "Base ISO is missing $manifest"

    for profile in "${USER_DATA_YAMLS[@]}"; do
        kernel_package="$(awk '
            /^  kernel:$/ {in_kernel=1; next}
            in_kernel && /^    package:/ {print $2; exit}
            in_kernel && /^  [^ ]/ {exit}
        ' "iso/boot/${profile}-user-data.yaml")"
        [ -n "$kernel_package" ] || die "Missing kernel.package in profile: $profile"
        grep -q "^${kernel_package}[[:space:]]" "$manifest" ||
            die "Profile $profile requests $kernel_package, but it is not installed in the base ISO"
    done

    log "Validated autoinstall kernel package against the base ISO"
}

stage_payloads() {
    mkdir -p "$ISO_DIR/pool/install" "$ISO_DIR/pool/os-extras"
    cp -Ra iso/extras "$ISO_DIR/pool/os-extras/"
    cp -Ra iso/scripts/. "$ISO_DIR/scripts/" 2>/dev/null || true
    mkdir -p "$ISO_DIR/scripts/product-scripts"
    cp -a "$WORK_DIR/target-product-scripts/." "$ISO_DIR/scripts/product-scripts/"

    cp -a "${DEB_FILES[@]}" "$ISO_DIR/pool/install/"
    find iso/debs -maxdepth 1 -type f -name '*.deb' -exec cp -a {} "$ISO_DIR/pool/install/" \;

    mkdir -p "$ISO_DIR/nocloud"
    local profile
    for profile in "${USER_DATA_YAMLS[@]}"; do
        [ -f "iso/boot/${profile}-user-data.yaml" ] || die "Missing user-data: iso/boot/${profile}-user-data.yaml"
        mkdir -p "$ISO_DIR/nocloud/$profile"
        : > "$ISO_DIR/nocloud/$profile/meta-data"
        cp -a "iso/boot/${profile}-user-data.yaml" "$ISO_DIR/nocloud/$profile/user-data"
    done

    mkdir -p "$ISO_DIR/scripts"
    cp -a iso/scripts/. "$ISO_DIR/scripts/"
    find "$ISO_DIR/scripts" -type f -name '*.sh' -exec chmod +x {} +
    cp -a iso/boot/grub.cfg iso/boot/grub_background.png "$ISO_DIR/boot/grub/"
}

collect_product_package_groups() {
    local dependencies_file product_name deb_file deb_filename generated_script

    for product_name in "${PRODUCT_NAMES[@]}"; do
        generated_script="$WORK_DIR/target-product-scripts/$product_name/50-in-target-late-commands.sh"
        mkdir -p "$(dirname "$generated_script")"
        cat > "$generated_script" <<'EOF'
#!/bin/bash
set -euo pipefail
readonly PRODUCT_DEB_DIR="/var/triveni/install"
readonly SOURCES_FILE="/etc/apt/sources.list.d/triveni-offline.list"
# Pinned to the offline repo rather than using --no-download, which fails on a
# file: repo's relative Filename.
readonly APT_OPTS=(
    -o Dpkg::Use-Pty=0
    -o APT::Color=0
    -o Acquire::Retries=0
    -o APT::Get::List-Cleanup=0
    -o Dir::Etc::sourcelist="$SOURCES_FILE"
    -o Dir::Etc::sourceparts=/dev/null
)
EOF
        for deb_file in "${DEB_FILES[@]}"; do
            deb_filename="$(basename "$deb_file")"
            [ "${deb_filename%%_*}" = "$product_name" ] || continue
            printf 'apt-get "${APT_OPTS[@]}" install -y --reinstall "$PRODUCT_DEB_DIR/%s"\n' "$deb_filename" >> "$generated_script"
        done
        chmod +x "$generated_script"
    done

    # Every product directory is scanned, not just the ones named after a deb, so
    # support-only components such as nvidia can declare dependencies too.
    : > "$WORK_DIR/product-package-groups"
    shopt -s nullglob
    for dependencies_file in "$WORK_DIR"/target-product-scripts/*/dependencies; do
        awk '
            {
                sub(/[[:space:]]*#.*/, "")
                gsub(/^[[:space:]]+|[[:space:]]+$/, "")
                if ($0 != "") print
            }
        ' "$dependencies_file" >> "$WORK_DIR/product-package-groups"
    done
    shopt -u nullglob
    sort -u -o "$WORK_DIR/product-package-groups" "$WORK_DIR/product-package-groups"
    [ -s "$WORK_DIR/product-package-groups" ] || die "No dependency entries found in product manifests"
}

# The hand-maintained dependency files cannot drift out of sync with what the product
# packages actually require, so take the declared dependencies from the debs as well.
collect_product_deb_dependencies() {
    local deb_file
    for deb_file in "${DEB_FILES[@]}"; do
        dpkg-deb -f "$deb_file" Pre-Depends Depends 2>/dev/null |
            sed -E 's/^(Pre-)?Depends:[[:space:]]*//' |
            tr ',' '\n' |
            sed -E 's/\([^)]*\)//g; s/[[:space:]]*\|[[:space:]]*/|/g; s/^[[:space:]]+|[[:space:]]+$//g' |
            awk 'NF' >> "$WORK_DIR/product-package-groups"
    done
    sort -u -o "$WORK_DIR/product-package-groups" "$WORK_DIR/product-package-groups"
}

# Optional per-product "dependencies-cache-only" files list packages that must ship on
# the ISO but must not be installed, because they conflict with one another (NVIDIA
# driver branches, for example). The target picks the one matching its hardware.
collect_cache_only_packages() {
    local dependencies_file

    : > "$WORK_DIR/product-package-cache-only"
    shopt -s nullglob
    for dependencies_file in "$WORK_DIR"/target-product-scripts/*/dependencies-cache-only; do
        awk '
            {
                sub(/[[:space:]]*#.*/, "")
                gsub(/^[[:space:]]+|[[:space:]]+$/, "")
                if ($0 != "") print
            }
        ' "$dependencies_file" >> "$WORK_DIR/product-package-cache-only"
    done
    shopt -u nullglob
    sort -u -o "$WORK_DIR/product-package-cache-only" "$WORK_DIR/product-package-cache-only"
}

prepare_rootfs() {
    if [ -f "$ISO_DIR/casper/filesystem.squashfs" ]; then
        ROOTFS_SQUASHFS="$ISO_DIR/casper/filesystem.squashfs"
    elif [ -f "$ISO_DIR/casper/minimal.squashfs" ]; then
        ROOTFS_SQUASHFS="$ISO_DIR/casper/minimal.squashfs"
    else
        die "Base ISO has no supported target filesystem under casper/"
    fi
    log "Preparing target filesystem: $ROOTFS_SQUASHFS"
    ROOTFS_DIR="$WORK_DIR/rootfs"
    unsquashfs -d "$ROOTFS_DIR" "$ROOTFS_SQUASHFS"

    mkdir -p "$ROOTFS_DIR/tmp/triveni-extras" "$ROOTFS_DIR/tmp/triveni-products"
    cp -a "$WORK_DIR/product-package-groups" "$ROOTFS_DIR/tmp/product-package-groups"
    cp -a "$WORK_DIR/product-package-cache-only" "$ROOTFS_DIR/tmp/product-package-cache-only"
    cp -a "${DEB_FILES[@]}" "$ROOTFS_DIR/tmp/triveni-products/"
    find iso/debs -maxdepth 1 -type f -name '*.deb' -exec cp -a {} "$ROOTFS_DIR/tmp/triveni-extras/" \;
    cp -a collect-packages.sh "$ROOTFS_DIR/tmp/collect-packages.sh"
}

install_into_rootfs() {
    mkdir -p "$ROOTFS_DIR/etc/apt/sources.list.d.disabled"
    if [ -f "$ROOTFS_DIR/etc/apt/sources.list" ]; then
        sed -i '/^ *deb cdrom:/s/^/# disabled for online ISO preparation: /' "$ROOTFS_DIR/etc/apt/sources.list"
    fi
    find "$ROOTFS_DIR/etc/apt/sources.list.d" -maxdepth 1 -type f \
        \( -name '*.list' -o -name '*.sources' \) \
        -exec grep -l '^ *deb cdrom:' {} \; \
        -exec mv {} "$ROOTFS_DIR/etc/apt/sources.list.d.disabled/" \;

    mount --bind /dev "$ROOTFS_DIR/dev"
    mount --bind /dev/pts "$ROOTFS_DIR/dev/pts"
    mount -t proc proc "$ROOTFS_DIR/proc"
    mount -t sysfs sys "$ROOTFS_DIR/sys"
    mount -t tmpfs tmpfs "$ROOTFS_DIR/run"
    RESOLV_BACKUP="$WORK_DIR/resolv.conf"
    if [ -e "$ROOTFS_DIR/etc/resolv.conf" ] || [ -L "$ROOTFS_DIR/etc/resolv.conf" ]; then
        cp -a "$ROOTFS_DIR/etc/resolv.conf" "$RESOLV_BACKUP" 2>/dev/null || true
    fi
    trap cleanup_rootfs_mounts RETURN
    rm -f "$ROOTFS_DIR/etc/resolv.conf"
    cp -L /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"
    if chroot "$ROOTFS_DIR" /bin/bash /tmp/collect-packages.sh; then
        :
    else
        local chroot_status=$?
        cleanup_rootfs_mounts
        trap - RETURN
        die "Offline package collection failed with exit status $chroot_status"
    fi
}

# The squashfs is deliberately left untouched: the installed system's dpkg database
# comes from the stock image layers, so anything baked in here would go unrecorded.
stage_offline_repo() {
    local repo_source="$ROOTFS_DIR/tmp/offline-repo"
    [ -d "$repo_source" ] || die "Offline repository was not produced by collect-packages.sh"
    [ -f "$repo_source/Packages" ] || die "Offline repository is missing its Packages index"

    log "Staging offline repository: $(find "$repo_source" -maxdepth 1 -name '*.deb' | wc -l) package(s), $(du -sh "$repo_source" | cut -f1)"
    rm -rf "$ISO_DIR/packages"
    mkdir -p "$ISO_DIR/packages"
    cp -a "$repo_source"/. "$ISO_DIR/packages/"
    rm -rf "$ROOTFS_DIR"
}

rebuild_md5sum() {
    local saved_ubuntu=""
    if [ -e "$ISO_DIR/ubuntu" ]; then mv "$ISO_DIR/ubuntu" "$WORK_DIR/ubuntu"; saved_ubuntu="$WORK_DIR/ubuntu"; fi
    (cd "$ISO_DIR" && find . -type f ! -name md5sum.txt ! -path './boot/*' ! -path './boot.catalog' -exec md5sum {} +) > "$ISO_DIR/md5sum.txt"
    [ -n "$saved_ubuntu" ] && mv "$saved_ubuntu" "$ISO_DIR/ubuntu"
}

extract_boot_images() {
    local info efi_start efi_size
    info="$(fdisk -l "$ISO_IN")"
    efi_start="$(echo "$info" | awk '/EFI System/ {print $2; exit}')"
    efi_size="$(echo "$info" | awk '/EFI System/ {print $4; exit}')"
    [ -n "$efi_start" ] && [ -n "$efi_size" ] || die "Could not locate EFI partition in base ISO"
    dd if="$ISO_IN" bs=1 count=432 of="$BUILD_DIR/boot_hybrid.img" status=none
    dd if="$ISO_IN" bs=512 skip="$efi_start" count="$efi_size" of="$BUILD_DIR/efi.img" status=none
    EFI_SIZE="$efi_size"
}

build_iso() {
    xorriso -as mkisofs -r -J -joliet-long -l -iso-level 4 -V StreamScope \
    --grub2-mbr "$BUILD_DIR/boot_hybrid.img" --protective-msdos-label --partition_cyl_align off \
      --partition_offset 16 --mbr-force-bootable \
    -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93e "$BUILD_DIR/efi.img" \
      -appended_part_as_gpt -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
      -c /boot.catalog -b /boot/grub/i386-pc/eltorito.img -no-emul-boot -boot-load-size 4 \
      -boot-info-table --grub2-boot-info -eltorito-alt-boot -e --interval:appended_partition_2::: \
    -no-emul-boot -boot-load-size "$EFI_SIZE" -o "$ISO_OUT" "$ISO_DIR"
}

main() {
    require_root
    require_commands
    parse_args "$@"
    validate_inputs
    collect_debian_files
    print_debian_files
    compute_output_name
    prepare_workspace
    validate_autoinstall_kernel_packages
    prepare_product_scripts
    collect_product_package_groups
    collect_product_deb_dependencies
    collect_cache_only_packages
    apply_product_script_overrides
    stage_payloads
    prepare_rootfs
    install_into_rootfs
    stage_offline_repo
    rebuild_md5sum
    extract_boot_images
    build_iso
    stat "$ISO_OUT"
    log "Created offline ISO: $ISO_OUT"
}

main "$@"
