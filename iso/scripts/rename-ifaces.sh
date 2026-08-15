#!/bin/bash
# shellcheck disable=SC2164
#
# This script is executed near the end of the installation process.
# It handles persistent renaming, live runtime renaming, and network configuration.
#

set -e

STRICT_NETWORK_MODE="${TRIVENI_STRICT_NETWORK:-0}"
IPV4_WAIT_SECS="${TRIVENI_IPV4_WAIT_SECS:-25}"
IPV4_WAIT_INTERVAL_SECS="${TRIVENI_IPV4_WAIT_INTERVAL_SECS:-1}"

LOG_FILE=/var/log/triveni-install.log
exec > >(tee -a "$LOG_FILE") 2>&1

echo "**********************************************************************"
echo "Running rename-ifaces.sh (renaming network interfaces)"

cleanup_installer_network_state() {
    local profile

    mkdir -p /etc/NetworkManager/system-connections

    for profile in /etc/NetworkManager/system-connections/*; do
        [ -e "$profile" ] || continue

        case "$(basename "$profile")" in
            Wired*|netplan-*|installer-*|"System "*)
                echo "Removing installer-generated NetworkManager profile: $profile"
                rm -f "$profile"
                ;;
        esac
    done

    for profile in /etc/netplan/*.yaml; do
        [ -e "$profile" ] || continue
        if grep -Eq 'installer-nic|subiquity|autoinstall' "$profile"; then
            echo "Removing installer-generated netplan file: $profile"
            rm -f "$profile"
        fi
    done
}


# Configures NetworkManager to establish a DHCP address.
# Args: interfaceName macAddress uniqueId
function configDhcp() {
    local id="$3"
    local file="/etc/NetworkManager/system-connections/$id"
    local uuid
    uuid=$(uuidgen)

    echo "
[802-3-ethernet]
duplex=full
mac-address=${2}

[connection]
id=${id}
uuid=${uuid}
type=802-3-ethernet
interface-name=${1}
autoconnect=true
autoconnect-priority=100
autoconnect-retries=0

[ipv6]
method=auto
may-fail=true

[ipv4]
method=auto
may-fail=true
never-default=false
route-metric=100
    " > "$file"
    chmod 600 "$file"
}

STATIC_INDEX=1

# Configures NetworkManager to establish a static IP address.
# Args: interfaceName macAddress uniqueId
function configStaticIp() {
    local id="$3"
    local file="/etc/NetworkManager/system-connections/$id"
    local uuid
    uuid=$(uuidgen)

    echo "
[802-3-ethernet]
duplex=full
mac-address=${2}

[connection]
id=${id}
uuid=${uuid}
type=802-3-ethernet
interface-name=${1}
autoconnect=true
autoconnect-priority=0
autoconnect-retries=0

[ipv6]
method=ignore

[ipv4]
method=manual
address1=192.168.$STATIC_INDEX.10/24
never-default=true
    " > "$file"
    chmod 600 "${file}"
    (( ++STATIC_INDEX ))
}

# Args: interfaceName macAddress uniqueId useDhcp(1|0)
function configInterface() {
    if [ "${4:-0}" -eq 1 ]; then
        configDhcp "$1" "$2" "$3"
    else
        configStaticIp "$1" "$2" "$3"
    fi
}

function map() {
    local ORG_NAME=$1
    local NEW_NAME=$2
    local MAC_ADDRESS=$3

    echo "mapping $ORG_NAME to $NEW_NAME $MAC_ADDRESS"
    echo -e "[Match]\nMACAddress=$MAC_ADDRESS\n\n[Link]\nName=$NEW_NAME" > "/etc/systemd/network/10-persistent-net-$ORG_NAME.link"
}

waitForIpv4() {
    local iface="$1"
    local waited=0

    [ -n "$iface" ] || return 1
    [ "$IPV4_WAIT_SECS" -gt 0 ] 2>/dev/null || return 1
    [ "$IPV4_WAIT_INTERVAL_SECS" -gt 0 ] 2>/dev/null || IPV4_WAIT_INTERVAL_SECS=1

    echo "[rename-ifaces] Waiting up to ${IPV4_WAIT_SECS}s for IPv4 on $iface"
    while [ "$waited" -lt "$IPV4_WAIT_SECS" ]; do
        if ip -4 addr show dev "$iface" | grep -q 'inet '; then
            echo "[rename-ifaces] IPv4 detected on $iface after ${waited}s"
            return 0
        fi
        sleep "$IPV4_WAIT_INTERVAL_SECS"
        waited=$((waited + IPV4_WAIT_INTERVAL_SECS))
    done

    echo "[rename-ifaces] WARNING: Timed out waiting for IPv4 on $iface after ${IPV4_WAIT_SECS}s"
    return 1
}

function ensureNetworkReady() {
    local primary_iface="$1"
    local default_gw=""

    echo "[rename-ifaces] Ensuring live network availability after interface rename"

    if [ -n "$primary_iface" ] && ip link show "$primary_iface" >/dev/null 2>&1; then
        ip link set dev "$primary_iface" up || true
    fi

    if [ -n "$primary_iface" ] && ip link show "$primary_iface" >/dev/null 2>&1; then
        waitForIpv4 "$primary_iface" || true
    fi

    if ! ip route show default | grep -q '^default '; then
        if [ -n "$ORIG_DEFAULT_GW" ] && [ -n "$primary_iface" ] && ip link show "$primary_iface" >/dev/null 2>&1; then
            echo "[rename-ifaces] Restoring default route via $ORIG_DEFAULT_GW on $primary_iface"
            ip route replace default via "$ORIG_DEFAULT_GW" dev "$primary_iface" || true
        fi
    fi

    if [ -n "$primary_iface" ] && ip link show "$primary_iface" >/dev/null 2>&1; then
        if ! ip -4 addr show dev "$primary_iface" | grep -q 'inet '; then
            if command -v dhclient >/dev/null 2>&1; then
                echo "[rename-ifaces] Requesting DHCP lease on $primary_iface"
                dhclient -r "$primary_iface" >/dev/null 2>&1 || true
                dhclient -4 -1 "$primary_iface" || true
            elif command -v nmcli >/dev/null 2>&1; then
                echo "[rename-ifaces] dhclient not found; requesting DHCP via NetworkManager on $primary_iface"
                nmcli device set "$primary_iface" managed yes >/dev/null 2>&1 || true
                nmcli connection reload >/dev/null 2>&1 || true
                nmcli device connect "$primary_iface" >/dev/null 2>&1 || true
            fi
        fi
    fi

    if ! getent ahostsv4 archive.ubuntu.com >/dev/null 2>&1; then
        echo "[rename-ifaces] DNS lookup failed; applying temporary resolver fallback"
        if grep -q '127.0.0.53' /etc/resolv.conf 2>/dev/null; then
            {
                echo "nameserver 1.1.1.1"
                echo "nameserver 8.8.8.8"
            } >/etc/resolv.conf || true
        fi
    fi

    echo "[rename-ifaces] Post-rename interface state"
    ip -br addr || true
    echo "[rename-ifaces] Post-rename route state"
    ip route show || true

    default_gw="$(ip route show default 2>/dev/null | awk 'NR==1 {print $3}')"

    if [ "$STRICT_NETWORK_MODE" = "1" ]; then
        echo "[rename-ifaces] Strict network validation enabled"

        if [ -z "$default_gw" ]; then
            echo "[rename-ifaces] ERROR: strict mode failed - default route is missing"
            return 1
        fi

        if ! ping -c 1 -W 2 "$default_gw" >/dev/null 2>&1; then
            echo "[rename-ifaces] ERROR: strict mode failed - gateway $default_gw unreachable"
            return 1
        fi

        if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
            echo "[rename-ifaces] ERROR: strict mode failed - internet reachability check failed"
            return 1
        fi

        if ! getent ahostsv4 archive.ubuntu.com >/dev/null 2>&1; then
            echo "[rename-ifaces] ERROR: strict mode failed - DNS resolution check failed"
            return 1
        fi
    fi

    if getent ahostsv4 archive.ubuntu.com >/dev/null 2>&1; then
        echo "[rename-ifaces] Network is ready for subsequent install steps"
    else
        echo "[rename-ifaces] WARNING: DNS resolution still failing after recovery attempts"
    fi
}

# configure NICs
cleanup_installer_network_state

ORIG_DEFAULT_IF="$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}')"
ORIG_DEFAULT_GW="$(ip route show default 2>/dev/null | awk 'NR==1 {print $3}')"
PRIMARY_RENAMED_IF=""
DHCP_SOURCE_IF=""

# find all ethernet (e*) nics
declare -A NICS
NIC_COUNT=0
for NIC in $(ls /sys/class/net/); do
    if [[ $NIC == e* ]]; then
        ADDRESS=$(</sys/class/net/$NIC/address)
        NICS[$NIC]=$ADDRESS
        NIC_COUNT=$((NIC_COUNT+1))
    else
        echo "Ignoring $NIC"
    fi
done

# sort the nics by length and name
readarray -t SORTED_NICS < <(
for str in "${!NICS[@]}"; do
    printf '%d\t%s\n' "${#str}" "$str"
done | sort -k 1,1n -k 2 | cut -f 2- )

if [ -n "$ORIG_DEFAULT_IF" ]; then
    echo "[rename-ifaces] Install-time default route interface: $ORIG_DEFAULT_IF"
fi

# swap motherboard nics for certain motherboards so that port 0 is on the left when looking at the back
if ! dmidecode -t 2 | grep -q "Product Name: X10SRA"; then
    if ! dmidecode -t 2 | grep -q "Product Name: X10DRW-i"; then
        if ! dmidecode -t 2 | grep -q "Product Name: X11DDW"; then
            # Only attempt a physical index swap if there are at least 2 NICs available
            if [ "${NIC_COUNT}" -ge 2 ]; then
                echo "Swapping default 2 NICS out of total: ${NIC_COUNT}"
                TMP=${SORTED_NICS[0]}
                SORTED_NICS[0]=${SORTED_NICS[1]}
                SORTED_NICS[1]=$TMP
            else
                echo "Single NIC detected (${NIC_COUNT}). Skipping layout swap."
            fi
        fi
    fi
fi

# Chosen after the layout swap for logging and live recovery. Persisted configuration
# assigns DHCP by final interface name, so eth00 never depends on install-time reachability.
if [ "${#SORTED_NICS[@]}" -gt 0 ]; then
    DHCP_SOURCE_IF="${SORTED_NICS[0]}"
fi
echo "[rename-ifaces] DHCP source interface before rename: ${DHCP_SOURCE_IF:-unknown} (becomes eth00)"

# map and configure the nics
NIC_COUNT=0
CONN_COUNT=1
rm -f /etc/systemd/network/10-*.link
for NIC in "${SORTED_NICS[@]}"; do
    NEW_IFACE_NAME="eth0$NIC_COUNT"
    USE_DHCP=0
    echo "Processing $NIC -> $NEW_IFACE_NAME"

    if [ "$NEW_IFACE_NAME" = "eth00" ]; then
        USE_DHCP=1
        PRIMARY_RENAMED_IF="$NEW_IFACE_NAME"
    fi
    
    # 1. Write persistent systemd link file for target machine reboots
    map "$NIC" "$NEW_IFACE_NAME" "${NICS[$NIC]}"
    
    # 2. Generate NetworkManager profiles
    configInterface "$NEW_IFACE_NAME" "${NICS[$NIC]}" "Wired_connection_$CONN_COUNT" "$USE_DHCP"

    # 3. Force immediate live runtime rename so subsequent scripts can find them right now
    echo "Flipping $NIC to $NEW_IFACE_NAME live in memory..."
    ip link set dev "$NIC" down || true
    ip link set dev "$NIC" name "$NEW_IFACE_NAME" || true
    ip link set dev "$NEW_IFACE_NAME" up || true

    # 4. FIX: Dynamically write the sysctl filter ONLY for this active, valid interface
    echo "net.ipv4.conf.$NEW_IFACE_NAME.rp_filter = 0" >> /etc/sysctl.conf

    (( ++NIC_COUNT ))
    (( ++CONN_COUNT ))
done

if [ -z "$PRIMARY_RENAMED_IF" ] && [ "${#SORTED_NICS[@]}" -gt 0 ]; then
    PRIMARY_RENAMED_IF="eth00"
fi

ensureNetworkReady "$PRIMARY_RENAMED_IF"

# update NetworkManager config to allow disconnected ifaces
mkdir -p /etc/NetworkManager/conf.d
{
    echo "[main]"
    echo "no-auto-default=*"
    echo "ignore-carrier=*"
} >/etc/NetworkManager/conf.d/triveni-digital.conf
chmod 644 /etc/NetworkManager/conf.d/triveni-digital.conf

# Stage global system-wide sysctl optimizations to the configuration file
{
    echo "net.core.wmem_max = 16777216"
    echo "net.core.rmem_max = 16777216"
    echo "net.ipv4.conf.default.rp_filter = 0"
    echo "net.ipv4.conf.all.rp_filter = 0"
} >>/etc/sysctl.conf

# 5. FIX: Running sysctl -p is now 100% safe because no ghost interfaces are evaluated!
sysctl -p

exit 0