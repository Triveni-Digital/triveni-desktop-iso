#!/bin/bash

# Interactive post-install cleanup, run by hand. Nothing here is automated and no
# step runs without an explicit answer. Pass -y to accept the defaults in brackets.

set -uo pipefail

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

readonly REPO_DIR="/var/triveni/packages"
readonly SOURCES_FILE="/etc/apt/sources.list.d/triveni-offline.list"
readonly DRIVER_PACKAGES_DIR="/var/triveni/drivers/packages"
readonly INSTALL_DIR="/var/triveni/install"
readonly APT_BACKUP_DIR="/var/triveni/apt-backup"
readonly KEEP_LOCALE="en"

ASSUME_DEFAULTS=false
OFFLINE_REPO_DEFAULT="n"

warn() { echo "  [warn] $*" >&2; }
info() { echo "  $*"; }
effect() {
    local line first=true
    for line in "$@"; do
        if [ "$first" = true ]; then
            printf '    Effect: %s\n' "$line"
            first=false
        else
            printf '            %s\n' "$line"
        fi
    done
}

usage() {
    cat <<EOF
Usage: $0 [-y]
  -y  accept the default answer for every prompt
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -y|--yes) ASSUME_DEFAULTS=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "This script must run as root (use sudo)." >&2
    exit 1
fi

confirm() {
    local prompt="$1" default="$2" reply
    if [ "$ASSUME_DEFAULTS" = true ]; then
        [ "$default" = "y" ]
        return
    fi
    if [ "$default" = "y" ]; then
        read -r -p "$prompt [Y/n] " reply
    else
        read -r -p "$prompt [y/N] " reply
    fi
    reply="${reply:-$default}"
    case "$reply" in
        [Yy]*) return 0 ;;
        *) return 1 ;;
    esac
}

set_offline_repo_default() {
    if command -v curl >/dev/null 2>&1 &&
        curl -fsS --connect-timeout 3 --max-time 5 -o /dev/null https://archive.ubuntu.com/ubuntu/; then
        OFFLINE_REPO_DEFAULT="y"
    fi
}

human_size() {
    [ -e "$1" ] || { echo "0"; return; }
    du -sh "$1" 2>/dev/null | cut -f1
}

human_bytes() {
    numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0} bytes"
}

dir_bytes() {
    [ -e "$1" ] || { echo 0; return; }
    du -sb "$1" 2>/dev/null | cut -f1
}

file_bytes() {
    local total=0 path
    for path in "$@"; do
        [ -e "$path" ] && total=$((total + $(stat -c%s "$path" 2>/dev/null || echo 0)))
    done
    echo "$total"
}

# dpkg reports Installed-Size in KiB.
package_bytes() {
    [ "$#" -gt 0 ] || { echo 0; return; }
    dpkg-query -W -f='${Installed-Size}\n' "$@" 2>/dev/null |
        awk '{total += $1} END {print (total + 0) * 1024}'
}

# apt reads the repo index, so after deleting any deb the index has to be rebuilt or
# apt will offer packages whose files are gone.
reindex_repo() {
    local repo_deb
    ( cd "$REPO_DIR" || exit 1
      : > Packages
      for repo_deb in *.deb; do
          [ -e "$repo_deb" ] || continue
          dpkg-deb -f "$repo_deb" >> Packages
          printf 'Filename: ./%s\n' "$repo_deb" >> Packages
          printf 'Size: %s\n' "$(stat -c%s "$repo_deb")" >> Packages
          printf 'SHA256: %s\n' "$(sha256sum "$repo_deb" | cut -d' ' -f1)" >> Packages
          printf '\n' >> Packages
      done
      gzip -9c Packages > Packages.gz )
    apt-get -o Dir::Etc::sourcelist="$SOURCES_FILE" -o Dir::Etc::sourceparts=/dev/null \
        -o APT::Get::List-Cleanup=0 update >/dev/null 2>&1 ||
        warn "Could not refresh the apt index"
}

print_plan() {
    local plan_row='  %3s  %-28s %-34s [%s]\n'
    local offline_repo_default="no"
    [ "$OFFLINE_REPO_DEFAULT" = "y" ] && offline_repo_default="yes"

    echo "======================================================================"
    echo "Triveni post-install cleanup"
    echo "======================================================================"
    echo "Nothing is removed without your approval. You will be asked about:"
    echo
    printf "$plan_row" "1."  "Offline package repository" "$REPO_DIR" "$offline_repo_default"
    printf "$plan_row" "1a." "Cached NVIDIA driver debs"  "keep for a later GPU swap" "no"
    printf "$plan_row" "2."  "Old kernels and modules"    "superseded by the running kernel" "yes"
    printf "$plan_row" "3."  "Unused bundled driver debs" "hardware not present" "yes"
    printf "$plan_row" "4."  "Product installer debs"     "$INSTALL_DIR/*.deb" "no"
    printf "$plan_row" "5."  "Previous-system backups"    "$INSTALL_DIR/backup.bak" "yes"
    printf "$plan_row" "6."  "Installer apt backup"       "$APT_BACKUP_DIR" "yes"
    printf "$plan_row" "7."  "apt download cache"         "/var/cache/apt/archives" "yes"
    printf "$plan_row" "8."  "Orphaned packages"          "apt-get autoremove --purge" "yes"
    printf "$plan_row" "9."  "Journal and rotated logs"   "keep the most recent 200M" "yes"
    printf "$plan_row" "10." "Crash dumps"                "/var/crash" "yes"
    printf "$plan_row" "11." "Unused language packs"      "keep '$KEEP_LOCALE' only" "no"
    echo
    echo "Values in brackets are the defaults; press Enter to accept."
    echo "======================================================================"
    echo
    printf 'Preparing...'
    sleep 2
    printf '\n\n'
}

set_offline_repo_default
print_plan

# ------------------------------------------------------------- 1. offline repo
if [ -d "$REPO_DIR" ]; then
    repo_total_bytes="$(dir_bytes "$REPO_DIR")"
    shopt -s nullglob
    nvidia_debs=("$REPO_DIR"/nvidia-*.deb "$REPO_DIR"/libnvidia-*.deb "$REPO_DIR"/xserver-xorg-video-nvidia-*.deb)
    shopt -u nullglob
    nvidia_bytes="$(file_bytes "${nvidia_debs[@]}")"
    repo_other_bytes=$((repo_total_bytes - nvidia_bytes))

    echo "[1] Offline package repository: $REPO_DIR ($(human_bytes "$repo_total_bytes"), $(ls "$REPO_DIR"/*.deb 2>/dev/null | wc -l) debs)"
    echo "    Needed only to install or repair packages without a network connection."
    effect "apt can no longer install or repair packages offline. None if this" \
           "machine has internet access, or you keep the install ISO."
    if confirm "    Remove the offline package repository? (frees $(human_bytes "$repo_other_bytes"))" "$OFFLINE_REPO_DEFAULT"; then
        effect "a later GPU swap would need internet or a reinstall to get the" \
               "matching driver branch; the drivers now installed keep working."
        if confirm "    [1a] Also remove the ${#nvidia_debs[@]} cached NVIDIA driver debs? (frees a further $(human_bytes "$nvidia_bytes"))" "n"; then
            rm -rf "$REPO_DIR"
            rm -f "$SOURCES_FILE"
            apt-get update >/dev/null 2>&1 || true
            info "Removed $REPO_DIR and unregistered the apt source"
        else
            find "$REPO_DIR" -maxdepth 1 -name '*.deb' \
                ! -name 'nvidia-*' ! -name 'libnvidia-*' ! -name 'xserver-xorg-video-nvidia-*' \
                -delete 2>/dev/null
            reindex_repo
            info "Kept NVIDIA packages ($(ls "$REPO_DIR"/*.deb 2>/dev/null | wc -l) debs, $(human_size "$REPO_DIR"))"
        fi
    else
        info "Left the repository in place"
    fi
else
    echo "[1] No offline repository at $REPO_DIR"
fi

# -------------------------------------------------------------- 2. old kernels
echo
current_kernel="$(uname -r)"
current_version="${current_kernel%-generic}"
mapfile -t old_kernel_packages < <(
    dpkg-query -W -f='${Package}\n' \
        'linux-image-[0-9]*' 'linux-headers-[0-9]*' \
        'linux-modules-[0-9]*' 'linux-modules-extra-[0-9]*' 2>/dev/null |
        grep -v -- "$current_version"
)
echo "[2] Running kernel: $current_kernel"
if [ "${#old_kernel_packages[@]}" -gt 0 ]; then
    echo "    Superseded: ${old_kernel_packages[*]}"
    effect "the older kernel disappears from the GRUB menu, so you cannot boot" \
           "back into it. Confirm the running kernel is healthy first."
    if confirm "    Remove old kernel packages and their modules? (frees $(human_bytes "$(package_bytes "${old_kernel_packages[@]}")"))" "y"; then
        apt-mark unhold "${old_kernel_packages[@]}" >/dev/null 2>&1 || true
        apt-get -y purge "${old_kernel_packages[@]}" || warn "Could not remove every old kernel package"
        for module_dir in /lib/modules/*; do
            [ -d "$module_dir" ] || continue
            [ "$(basename "$module_dir")" = "$current_kernel" ] && continue
            rm -rf "$module_dir" && info "Removed stale modules: $module_dir"
        done
        update-grub >/dev/null 2>&1 || warn "Could not update grub"
    else
        info "Left old kernels in place"
    fi
else
    info "No superseded kernel packages found"
fi

# ------------------------------------------------------- 3. unused driver debs
echo
if [ -d "$DRIVER_PACKAGES_DIR" ]; then
    unused_driver_debs=()
    for driver_deb in "$DRIVER_PACKAGES_DIR"/*.deb; do
        [ -e "$driver_deb" ] || continue
        driver_package="$(dpkg-deb -f "$driver_deb" Package 2>/dev/null)"
        [ -n "$driver_package" ] || continue
        dpkg -s "$driver_package" >/dev/null 2>&1 || unused_driver_debs+=("$driver_deb")
    done
    echo "[3] Bundled driver packages: $DRIVER_PACKAGES_DIR ($(human_size "$DRIVER_PACKAGES_DIR"))"
    if [ "${#unused_driver_debs[@]}" -gt 0 ]; then
        for driver_deb in "${unused_driver_debs[@]}"; do
            echo "      not installed: $(basename "$driver_deb")"
        done
        effect "if that capture card is fitted later, its driver deb has to come" \
               "from the ISO or the network. Installed drivers are unaffected."
        if confirm "    Remove driver packages for hardware this machine does not have? (frees $(human_bytes "$(file_bytes "${unused_driver_debs[@]}")"))" "y"; then
            rm -f "${unused_driver_debs[@]}"
            info "Removed ${#unused_driver_debs[@]} unused driver package(s)"
        else
            info "Left the unused driver packages in place"
        fi
    else
        info "Every bundled driver package is installed; nothing unused"
    fi
else
    echo "[3] No bundled driver packages at $DRIVER_PACKAGES_DIR"
fi

# --------------------------------------------------- 4. product installer debs
echo
shopt -s nullglob
product_debs=("$INSTALL_DIR"/*.deb)
shopt -u nullglob
if [ "${#product_debs[@]}" -gt 0 ]; then
    echo "[4] Product installer debs in $INSTALL_DIR (${#product_debs[@]} files)"
    effect "reinstalling or repairing a product would need the ISO or internet." \
           "None if this machine has internet access, or you keep the ISO." \
           "Installed products keep running either way."
    if confirm "    Remove the product installer debs? (frees $(human_bytes "$(file_bytes "${product_debs[@]}")"))" "n"; then
        rm -f "${product_debs[@]}"
        info "Removed ${#product_debs[@]} product deb(s)"
    else
        info "Left the product debs in place"
    fi
else
    echo "[4] No product debs in $INSTALL_DIR"
fi

# ---------------------------------------------------------- 5. backup archives
echo
if [ -d "$INSTALL_DIR/backup.bak" ]; then
    echo "[5] Previous-system backups: $INSTALL_DIR/backup.bak"
    effect "configuration and licences carried over from the previous system are" \
           "gone for good. None if you have already verified this install."
    if confirm "    Remove the previous-system backup archives? (frees $(human_bytes "$(dir_bytes "$INSTALL_DIR/backup.bak")"))" "y"; then
        rm -rf "$INSTALL_DIR/backup.bak"
        info "Removed backup.bak"
    else
        info "Left backup.bak in place"
    fi
else
    echo "[5] No backup archives at $INSTALL_DIR/backup.bak"
fi

# --------------------------------------------------------- 6. installer backup
echo
if [ -d "$APT_BACKUP_DIR" ]; then
    echo "[6] Installer apt backup: $APT_BACKUP_DIR"
    effect "none. This is the installer's own snapshot of the apt configuration" \
           "and is not used once installation has finished."
    if confirm "    Remove the installer apt backup? (frees $(human_bytes "$(dir_bytes "$APT_BACKUP_DIR")"))" "y"; then
        rm -rf "$APT_BACKUP_DIR"
        info "Removed $APT_BACKUP_DIR"
    else
        info "Left the apt backup in place"
    fi
else
    echo "[6] No installer apt backup at $APT_BACKUP_DIR"
fi

# ---------------------------------------------------------------- 7. apt cache
echo
echo "[7] apt download cache: /var/cache/apt/archives"
effect "none. These are copies of packages already installed; apt fetches" \
       "them again from the offline repo or the network if ever needed."
if confirm "    Empty the apt download cache? (frees $(human_bytes "$(dir_bytes /var/cache/apt/archives)"))" "y"; then
    apt-get clean && info "Emptied the apt cache"
else
    info "Left the apt cache in place"
fi

# -------------------------------------------------------- 8. orphaned packages
echo
echo "[8] Orphaned packages (pulled in as dependencies, no longer required)"
autoremove_freed="$(apt-get -s autoremove --purge 2>/dev/null |
    sed -n 's/.*After this operation, \(.*\) disk space will be freed.*/\1/p' | tail -1)"
effect "apt removes what nothing depends on. Read the list it prints: a tool" \
       "you use by hand can appear if it arrived as a dependency."
if confirm "    Run apt-get autoremove --purge? (frees ${autoremove_freed:-nothing})" "y"; then
    apt-get -y autoremove --purge || warn "autoremove reported errors"
else
    info "Skipped autoremove"
fi

# --------------------------------------------------------------------- 9. logs
echo
echo "[9] Journal: $(journalctl --disk-usage 2>/dev/null | sed 's/^Archived and active journals //')"
journal_bytes="$(dir_bytes /var/log/journal)"
journal_freed=$((journal_bytes - 200 * 1024 * 1024))
[ "$journal_freed" -lt 0 ] && journal_freed=0
rotated_log_bytes="$(find /var/log -type f \( -name '*.gz' -o -name '*.old' -o -name '*.[0-9]' \) -printf '%s\n' 2>/dev/null |
    awk '{total += $1} END {print total + 0}')"
effect "older diagnostic history is lost, including the install log's rotated" \
       "copies. Collect any logs you still need first; logging continues."
if confirm "    Trim the journal to 200M and delete rotated logs? (frees $(human_bytes $((journal_freed + rotated_log_bytes))))" "y"; then
    journalctl --vacuum-size=200M >/dev/null 2>&1 || warn "Could not vacuum the journal"
    find /var/log -type f \( -name '*.gz' -o -name '*.old' -o -name '*.[0-9]' \) -delete 2>/dev/null
    info "Trimmed the journal and removed rotated logs"
else
    info "Left logs in place"
fi

# -------------------------------------------------------------- 10. crash dumps
echo
if [ -d /var/crash ] && [ -n "$(ls -A /var/crash 2>/dev/null)" ]; then
    echo "[10] Crash dumps: /var/crash"
    effect "pending crash reports are discarded and cannot be examined or" \
           "submitted afterwards. None if you are not chasing a crash."
    if confirm "    Remove crash dumps? (frees $(human_bytes "$(dir_bytes /var/crash)"))" "y"; then
        rm -rf /var/crash/* && info "Removed crash dumps"
    else
        info "Left crash dumps in place"
    fi
else
    echo "[10] No crash dumps in /var/crash"
fi

# ---------------------------------------------------------- 11. language packs
echo
mapfile -t extra_language_packs < <(
    dpkg-query -W -f='${Package}\n' 'language-pack-*' 2>/dev/null |
        grep -v -e "-${KEEP_LOCALE}\$" -e "-${KEEP_LOCALE}-base\$"
)
if [ "${#extra_language_packs[@]}" -gt 0 ]; then
    echo "[11] Language packs beyond '$KEEP_LOCALE': ${#extra_language_packs[@]} package(s)"
    effect "the desktop can only display '$KEEP_LOCALE'. A user who picks another" \
           "language falls back to English; menus stay untranslated."
    if confirm "    Remove language packs other than '$KEEP_LOCALE'? (frees $(human_bytes "$(package_bytes "${extra_language_packs[@]}")"))" "n"; then
        apt-get -y purge "${extra_language_packs[@]}" || warn "Could not remove every language pack"
    else
        info "Left language packs in place"
    fi
else
    echo "[11] No extra language packs installed"
fi

echo
echo "======================================================================"
echo "Cleanup complete. Free space:"
df -h / /var/triveni 2>/dev/null | sed 's/^/  /'
echo "======================================================================"
