#!/usr/bin/env bash
#
# setup_ap_mode.sh
# Turn the pi's built-in wireless radio into an access point.
# - Assigns a static IP to LAN_IF (wlan0) via systemd-networkd.
# - Writes /etc/hostapd/hostapd.conf from the template.
# - Unmanages the interface from NetworkManager if NM is running.
# - Enables and starts hostapd.
#
# Prereqs: setup_prereqs.sh (installs hostapd + iw), .env filled with:
#   LAN_IF, LAN_GATEWAY, LAN_SUBNET, WIFI_SSID, WIFI_PASSPHRASE,
#   WIFI_COUNTRY, WIFI_CHANNEL.
#
# Idempotent. Safe to re-run after editing .env.

set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

require_root
load_env
require_var LAN_IF
require_var LAN_GATEWAY
require_var LAN_SUBNET
require_var WIFI_SSID
require_var WIFI_PASSPHRASE
require_var WIFI_COUNTRY
require_var WIFI_CHANNEL

# Sanity: LAN_IF must be wireless for AP mode.
if ! command -v iw >/dev/null 2>&1; then
    die "iw not installed. Run setup_prereqs.sh."
fi
if ! iw dev "${LAN_IF}" info >/dev/null 2>&1; then
    die "LAN_IF=${LAN_IF} is not a wireless device. For AP mode use wlan0 (check: iw dev)."
fi
command -v hostapd >/dev/null || die "hostapd not installed. Run setup_prereqs.sh."

# WPA2 passphrase length rule.
pass_len=${#WIFI_PASSPHRASE}
if (( pass_len < 8 || pass_len > 63 )); then
    die "WIFI_PASSPHRASE must be 8..63 chars (got ${pass_len})"
fi

# Extract CIDR prefix from LAN_SUBNET (e.g. 10.77.0.0/24 -> 24).
if [[ "${LAN_SUBNET}" == */* ]]; then
    prefix="${LAN_SUBNET##*/}"
else
    die "LAN_SUBNET must be CIDR (e.g. 10.77.0.0/24), got ${LAN_SUBNET}"
fi

# Regulatory domain: set now and persist.
log "setting regulatory domain to ${WIFI_COUNTRY}"
iw reg set "${WIFI_COUNTRY}" || log "warning: iw reg set failed (continuing)"
if command -v raspi-config >/dev/null 2>&1; then
    raspi-config nonint do_wifi_country "${WIFI_COUNTRY}" || true
fi

# Soft unblock wifi. On a fresh pi the radio is sometimes rfkill-blocked.
if command -v rfkill >/dev/null 2>&1; then
    rfkill unblock wifi || true
fi

# Kill the wpa_supplicant race on Trixie.
#
# Standalone wpa_supplicant.service, enabled by default on Pi OS, registers
# a supplicant interface with NetworkManager. On boot that flips the wifi
# device's managed-type from 'external' (our keyfile-unmanaged state) to
# 'full', overriding the unmanage keyfile and racing with hostapd for the
# radio. Sometimes hostapd wins, sometimes wpa_supplicant does; the SSID
# appears or doesn't depending on timing. Mask the standalone service.
# NetworkManager has its own internal supplicant for its managed wifi
# clients and does not need this one.
if systemctl is-enabled wpa_supplicant.service >/dev/null 2>&1; then
    log "masking wpa_supplicant.service (AP-only build, prevents NM race)"
    systemctl disable --now wpa_supplicant.service || true
    systemctl mask wpa_supplicant.service || true
fi

# Don't let the box wait 90s at boot for an interface to be 'online' when
# there is no uplink yet. Headless gateway, nothing useful depends on this.
for svc in NetworkManager-wait-online.service systemd-networkd-wait-online.service; do
    if systemctl is-enabled "${svc}" >/dev/null 2>&1; then
        log "masking ${svc} (headless gateway, no desktop needs it)"
        systemctl disable --now "${svc}" || true
        systemctl mask "${svc}" || true
    fi
done

# NetworkManager hands-off. Pi OS Bookworm/Trixie ships NM by default.
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    log "telling NetworkManager to unmanage ${LAN_IF}"
    mkdir -p /etc/NetworkManager/conf.d
    cat >/etc/NetworkManager/conf.d/99-p5r-unmanage-lan.conf <<EOF
# private-5g-router: hostapd owns ${LAN_IF}. NM must not touch it.
[keyfile]
unmanaged-devices=interface-name:${LAN_IF}
EOF

    # Explicitly drop any active connection and delete any saved profile
    # that would auto-reconnect. Trixie/netplan sometimes leaves a profile
    # like `netplan-wlan0-<SSID>` that NM reactivates on every boot before
    # it reads the keyfile drop-in.
    if nmcli -t -f DEVICE device status | grep -qE "^${LAN_IF}\$"; then
        nmcli device disconnect "${LAN_IF}" 2>/dev/null || true
    fi
    while read -r con; do
        [[ -n "${con}" ]] || continue
        log "deleting NM connection: ${con}"
        nmcli connection delete "${con}" 2>/dev/null || true
    done < <(nmcli -t -f NAME,DEVICE connection show 2>/dev/null \
             | awk -F: -v ifn="${LAN_IF}" '$2==ifn {print $1}')
    # Also kill any saved wifi-type profile that matches LAN_IF by
    # interface-name in its settings (e.g. netplan-wlan0-CropGuard).
    while read -r con; do
        [[ -n "${con}" ]] || continue
        ifn=$(nmcli -t -f connection.interface-name connection show "${con}" 2>/dev/null \
              | awk -F: '{print $2}')
        if [[ "${ifn}" == "${LAN_IF}" ]]; then
            log "deleting NM connection bound to ${LAN_IF}: ${con}"
            nmcli connection delete "${con}" 2>/dev/null || true
        fi
    done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null \
             | awk -F: '$2 ~ /wireless|wifi/ {print $1}')

    systemctl restart NetworkManager
    sleep 2
fi

# Static address on wlan0 via systemd-networkd.
NET_FILE="/etc/systemd/network/20-lan-${LAN_IF}.network"
log "writing ${NET_FILE} (${LAN_GATEWAY}/${prefix})"
cat >"${NET_FILE}" <<EOF
# private-5g-router: LAN (wireless AP).
[Match]
Name=${LAN_IF}

[Network]
Address=${LAN_GATEWAY}/${prefix}
ConfigureWithoutCarrier=yes
IPv6AcceptRA=no

[Link]
RequiredForOnline=no
EOF
chmod 0644 "${NET_FILE}"

systemctl enable systemd-networkd >/dev/null
systemctl restart systemd-networkd

# Render hostapd.conf.
mkdir -p /etc/hostapd
render_template "${FARM_ROOT}/configs/hostapd.conf.template" /etc/hostapd/hostapd.conf \
    LAN_IF WIFI_SSID WIFI_PASSPHRASE WIFI_COUNTRY WIFI_CHANNEL
# Passphrase lives in this file, tighten perms.
chmod 0600 /etc/hostapd/hostapd.conf

# Point the Debian wrapper at our config.
if [[ -f /etc/default/hostapd ]]; then
    sed -i 's|^#*DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
fi

# hostapd ships masked on Debian.
systemctl unmask hostapd 2>/dev/null || true
systemctl enable hostapd

# Order hostapd after systemd-networkd and NetworkManager so the interface
# has its static address and NM has finished touching it before the AP
# tries to come up. Cheap insurance against the boot race seen on Trixie.
mkdir -p /etc/systemd/system/hostapd.service.d
cat >/etc/systemd/system/hostapd.service.d/10-p5r-ordering.conf <<'EOF'
[Unit]
After=systemd-networkd.service NetworkManager.service
Wants=systemd-networkd.service
EOF
systemctl daemon-reload

log "starting hostapd"
systemctl restart hostapd

sleep 2
if ! systemctl is-active --quiet hostapd; then
    log "hostapd failed to start. Recent logs:"
    journalctl -u hostapd -n 40 --no-pager >&2 || true
    die "hostapd not running. See docs/ap-mode.md troubleshooting."
fi

log "AP up. SSID=${WIFI_SSID} channel=${WIFI_CHANNEL} on ${LAN_IF}"
log "Interface state:"
ip -br addr show "${LAN_IF}" || true
log "Next: run setup_nat.sh (or configure dnsmasq first if you want DHCP for clients)."
