#!/bin/bash

set -euo pipefail

readonly LOG_FILE="/var/log/triveni-install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

readonly AUTO_UPGRADES_FILE="/etc/apt/apt.conf.d/20auto-upgrades"
readonly WAIT_ONLINE_FILE="/etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service"

echo "**********************************************************************"
echo "Running finalize-os.sh (executing finalize-os commands in target environment)"

log() {
  echo "[finalize-os] $*"
}

warn() {
  echo "[finalize-os][warn] $*"
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "This script must run as root." >&2
    exit 1
  fi
}

require_commands() {
  local missing=0
  for cmd in sed dpkg-reconfigure; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log "Missing required command: $cmd" >&2
      missing=1
    fi
  done
  if [ "$missing" -ne 0 ]; then
    exit 1
  fi
}

require_bootable_kernel() {
  if ! compgen -G '/boot/vmlinuz-6.8.*-generic' >/dev/null; then
    echo "No bootable 6.8 generic kernel was installed." >&2
    exit 1
  fi
}

run_systemctl_disable() {
  local service_name="$1"

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl not found; skipping disable for $service_name"
    return 0
  fi

  if ! systemctl disable "$service_name" >/dev/null 2>&1; then
    warn "systemctl disable $service_name failed; this is expected in installer chroots without active systemd"
  fi
}

configure_grub() {
  local grub_params
  if command -v dmidecode >/dev/null 2>&1 && dmidecode 2>/dev/null | grep -qE "Product Name: X9SCL/X9SCM|Product Name: X11SSH-F"; then
    grub_params="bootdegraded=true nomodeset"
  else
    grub_params="bootdegraded=true"
  fi

  if [ ! -f /etc/default/grub ]; then
    warn "/etc/default/grub not found; skipping GRUB tuning"
    return
  fi

  if ! command -v update-grub >/dev/null 2>&1; then
    warn "update-grub not found; skipping GRUB tuning"
    return
  fi

  sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*$/GRUB_CMDLINE_LINUX_DEFAULT="'"$grub_params"'"/' /etc/default/grub
  sed -i 's/^GRUB_TIMEOUT=.*$/GRUB_TIMEOUT=3/' /etc/default/grub
  if grep -q "GRUB_RECORDFAIL_TIMEOUT=" /etc/default/grub; then
    sed -i 's/^GRUB_RECORDFAIL_TIMEOUT=.*$/GRUB_RECORDFAIL_TIMEOUT=3/' /etc/default/grub
  else
    sed -i '/^GRUB_TIMEOUT=.*$/a GRUB_RECORDFAIL_TIMEOUT=3' /etc/default/grub
  fi

  if ! update-grub; then
    warn "update-grub failed; continuing without regenerating GRUB config"
  fi
}

configure_update_policy() {
  if [ -f "$AUTO_UPGRADES_FILE" ]; then
    sed -i 's/^APT::Periodic::Update-Package-Lists "1";/APT::Periodic::Update-Package-Lists "0";/' "$AUTO_UPGRADES_FILE"
    sed -i 's/^APT::Periodic::Unattended-Upgrade "1";/APT::Periodic::Unattended-Upgrade "0";/' "$AUTO_UPGRADES_FILE"
  else
    warn "$AUTO_UPGRADES_FILE not found; skipping unattended-upgrades tuning"
  fi
}

configure_network_timeouts() {
  if [ -f /etc/dhcp/dhclient.conf ]; then
    sed -i 's/^timeout 300;/timeout 15;/' /etc/dhcp/dhclient.conf
  else
    warn "/etc/dhcp/dhclient.conf not found"
  fi

  if [ -f "$WAIT_ONLINE_FILE" ]; then
    sed -i 's/^TimeoutStartSec=5min/TimeoutStartSec=15/' "$WAIT_ONLINE_FILE"
  else
    warn "$WAIT_ONLINE_FILE not found"
  fi
}

apply_os_extras() {
  if [ -d /cdrom/pool/os-extras ]; then
    ls -la /cdrom/pool/os-extras >/var/log/tmp-os-extras.txt || true

    if ! cp -Ra /cdrom/pool/os-extras/* /; then
      warn "Failed to copy os-extras payload; continuing"
    fi

    # Directories must be accessible (755)
    [ -d /usr/share/backgrounds/triveni ] && chmod 755 /usr/share/backgrounds/triveni || warn "/usr/share/backgrounds/triveni not found; skipping chmod"
    [ -d /usr/share/gnome-background-properties ] && chmod 755 /usr/share/gnome-background-properties || warn "/usr/share/gnome-background-properties not found; skipping chmod"

    # Files must be globally readable (644)
    [ -f /usr/share/gnome-background-properties/triveni-wallpapers.xml ] && chmod 644 /usr/share/gnome-background-properties/triveni-wallpapers.xml || warn "triveni-wallpapers.xml not found; skipping chmod"
    if compgen -G "/usr/share/backgrounds/triveni/*" >/dev/null; then
      chmod 644 /usr/share/backgrounds/triveni/*
    else
      warn "No files under /usr/share/backgrounds/triveni; skipping chmod"
    fi

  else
    warn "/cdrom/pool/os-extras not found; skipping copy"
  fi
}

seed_triveni_home() {
  if [ -d /home/triveni ] && [ -d /etc/skel ]; then
    cp -a /etc/skel/. /home/triveni/
    chown -R 1000:1000 /home/triveni
    chmod -R u+rwX /home/triveni
    chmod 750 /home/triveni
  else
    warn "Skipping /home/triveni seed (home or /etc/skel missing)"
  fi
}

fix_permissions() {
  [ -d /usr/share ] && chmod a+r /usr/share || true
  [ -d /usr/share/applications ] && chmod -R a+r /usr/share/applications || true
}

configure_gdm_login_background() {
  local bg_path="/usr/share/backgrounds/triveni/profile_picture.png"
  local gdm_db_dir="/etc/dconf/db/gdm.d"
  local gdm_conf_file="$gdm_db_dir/01-triveni-login-background"

  if [ ! -f "$bg_path" ]; then
    warn "$bg_path not found; skipping GDM login background configuration"
    return
  fi

  mkdir -p "$gdm_db_dir"
  cat >"$gdm_conf_file" <<EOF
[org/gnome/desktop/background]
picture-uri='file://$bg_path'
picture-uri-dark='file://$bg_path'
picture-options='zoom'
EOF
}

configure_login_user_avatar() {
  local username="triveni"
  local source_icon="/usr/share/backgrounds/triveni/profile_picture.png"
  local icon_dir="/var/lib/AccountsService/icons"
  local users_dir="/var/lib/AccountsService/users"
  local icon_path="$icon_dir/$username"
  local user_file="$users_dir/$username"

  if [ ! -f "$source_icon" ]; then
    warn "$source_icon not found; skipping login avatar configuration"
    return
  fi

  mkdir -p "$icon_dir" "$users_dir"
  cp -f "$source_icon" "$icon_path"
  chmod 0644 "$icon_path"

  cat >"$user_file" <<EOF
[User]
Icon=$icon_path
SystemAccount=false
EOF
  chmod 0644 "$user_file"
}

cleanup_smartcard_overrides() {
  rm -f /etc/pam.d/*smartcard* || true
  rm -f /etc/alternatives/gdm-smartcard || true

  if command -v dconf >/dev/null 2>&1; then
    dconf update >/dev/null 2>&1 || warn "dconf update failed; continuing"
  else
    warn "dconf not found; skipping smartcard cleanup database update"
  fi
}

disable_onetime_service() {
  run_systemctl_disable onetime-reboot.service
}

configure_timezone() {
  local time_zone
  if [ -r /etc/timezone ]; then
    time_zone=$(tr -d '\r ' </etc/timezone)
    [ -n "$time_zone" ] || time_zone="America/New_York"
  else
    time_zone="America/New_York"
    echo "$time_zone" >/etc/timezone
  fi

  log "Enforcing system time zone: $time_zone"

  if ! /usr/bin/ln -sf "/usr/share/zoneinfo/$time_zone" /etc/localtime; then
    warn "Failed to install timezone symlink for $time_zone; continuing"
    return 0
  fi

  if ! command -v dpkg-reconfigure >/dev/null 2>&1; then
    warn "dpkg-reconfigure not found; skipping tzdata reconfiguration"
    return 0
  fi

  if ! DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1; then
    warn "tzdata reconfiguration failed; continuing"
  fi
}

recompile_icons_and_wallpapers() {
    # recompile gsettings schemas so that the new wallpaper is available in the GNOME settings
    if [ -d /home/triveni ]; then
        chown -R 1000:1000 /home/triveni
        chmod -R u+rwX /home/triveni
        chmod 750 /home/triveni
    fi

    if [ ! -d /usr/share/glib-2.0/schemas ]; then
        warn "/usr/share/glib-2.0/schemas not found; skipping schema compilation"
        return 0
    fi

    if ! command -v glib-compile-schemas >/dev/null 2>&1; then
        warn "glib-compile-schemas not found; skipping schema compilation"
        return 0
    fi

    if ! glib-compile-schemas /usr/share/glib-2.0/schemas/; then
        warn "glib-compile-schemas failed; continuing without final schema rebuild"
    fi
}

main() {
  log "Running finalize-os.sh"
  require_root
  require_commands
  require_bootable_kernel

  configure_grub
  configure_update_policy
  configure_network_timeouts
  apply_os_extras
  configure_gdm_login_background
  configure_login_user_avatar
  seed_triveni_home
  fix_permissions
  cleanup_smartcard_overrides
  disable_onetime_service
  configure_timezone
  recompile_icons_and_wallpapers
}

main "$@"
