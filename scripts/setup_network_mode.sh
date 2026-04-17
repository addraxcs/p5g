#!/usr/bin/env bash
#
# setup_network_mode.sh
# Path A: E3372 exposes usb0/eth1. Configure it as DHCP client via
# systemd-networkd so it behaves like any other WAN uplink.
#
# Prereq: detect_modem.sh printed MODE=network, and WAN_IF in .env is set to
# the actual interface (e.g. usb0).

set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

require_root
load_env
require_var WAN_IF

[[ "${WAN_IF}" =~ ^(ppp[0-9]+)$ ]] && die "WAN_IF=${WAN_IF} looks like PPP. Use setup_ppp_mode.sh instead."

if ! ip link show "${WAN_IF}" >/dev/null 2>&1; then
    die "interface ${WAN_IF} not present. Is the modem plugged in? Check detect_modem.sh."
fi

# Tell NetworkManager to hand WAN_IF to systemd-networkd. Trixie/Bookworm
# ship NM by default, and it will fight networkd on the same interface.
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    log "telling NetworkManager to unmanage ${WAN_IF}"
    mkdir -p /etc/NetworkManager/conf.d
    cat >/etc/NetworkManager/conf.d/99-p5r-unmanage-wan.conf <<EOF
# private-5g-router: systemd-networkd owns ${WAN_IF}.
[keyfile]
unmanaged-devices=interface-name:${WAN_IF}
EOF

    # Drop any active NM connection + delete any saved profile on WAN_IF so
    # NM does not reactivate it across a reboot.
    if nmcli -t -f DEVICE device status | grep -qE "^${WAN_IF}\$"; then
        nmcli device disconnect "${WAN_IF}" 2>/dev/null || true
    fi
    while read -r con; do
        [[ -n "${con}" ]] || continue
        log "deleting NM connection on ${WAN_IF}: ${con}"
        nmcli connection delete "${con}" 2>/dev/null || true
    done < <(nmcli -t -f NAME,DEVICE connection show 2>/dev/null \
             | awk -F: -v ifn="${WAN_IF}" '$2==ifn {print $1}')

    systemctl restart NetworkManager
    sleep 2
fi

UNIT_PATH="/etc/systemd/network/10-wan-${WAN_IF}.network"
log "writing ${UNIT_PATH}"
cat >"${UNIT_PATH}" <<EOF
# private-5g-router: WAN uplink via ${WAN_IF} (Huawei E3372 HiLink mode).
# RouteMetric=50 ensures the modem default wins over any management
# interface (e.g. eth0 plugged into unifi) whose default is at metric 100.
[Match]
Name=${WAN_IF}

[Network]
DHCP=ipv4
IPv6AcceptRA=no

[DHCPv4]
UseDNS=yes
UseRoutes=yes
RouteMetric=50
EOF
chmod 0644 "${UNIT_PATH}"

log "restarting systemd-networkd"
systemctl restart systemd-networkd

log "waiting up to 30s for ${WAN_IF} to get an IPv4 lease"
for _ in $(seq 1 30); do
    if ip -4 -br addr show "${WAN_IF}" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/'; then
        log "${WAN_IF} has an address"
        ip -4 -br addr show "${WAN_IF}"
        log "default route(s):"
        ip route | grep default || log "(no default route yet)"
        exit 0
    fi
    sleep 1
done

die "${WAN_IF} did not get an IPv4 address within 30s. Check journalctl -u systemd-networkd."
