#!/usr/bin/env bash
#
# rollback.sh
# Reverse everything private-5g-router installed on the pi.
# Does NOT uninstall packages. Does NOT touch SSH. Safe to run multiple times.

set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

require_root

# VPN teardown (safe no-op if VPN was never installed)
log "stopping VPN tunnel if active"
for wg_unit in $(systemctl list-units --type=service --all --no-legend 'wg-quick@*' 2>/dev/null \
    | awk '{print $1}'); do
    systemctl disable --now "${wg_unit}" 2>/dev/null || true
done
if [[ -d /etc/wireguard ]]; then
    log "removing WireGuard configs"
    rm -f /etc/wireguard/wg0.conf
    rmdir /etc/wireguard 2>/dev/null || true
fi

log "stopping and disabling services"
for unit in p5r-watchdog.timer p5r-watchdog.service p5r-wan.service; do
    systemctl disable --now "${unit}" 2>/dev/null || true
done

log "removing unit files and helpers"
rm -f /etc/systemd/system/p5r-wan.service
rm -f /etc/systemd/system/p5r-watchdog.service
rm -f /etc/systemd/system/p5r-watchdog.timer
rm -f /usr/local/bin/p5r-wan-up
rm -f /usr/local/bin/p5r-healthcheck
rm -f /etc/default/p5r
systemctl daemon-reload

log "removing systemd-networkd unit for WAN"
rm -f /etc/systemd/network/10-wan-*.network
systemctl restart systemd-networkd 2>/dev/null || true

log "stopping any manual pppd and removing peer/chat"
pkill -TERM pppd 2>/dev/null || true
rm -f /etc/ppp/peers/p5r-wwan /etc/chatscripts/p5r-wwan
for f in /etc/ppp/pap-secrets /etc/ppp/chap-secrets; do
    [[ -f "$f" ]] && sed -i "/^# p5r-begin$/,/^# p5r-end$/d" "$f" || true
done

log "flushing nftables and removing config"
nft flush ruleset 2>/dev/null || true
rm -f /etc/nftables.conf
systemctl disable --now nftables 2>/dev/null || true

log "disabling forwarding"
rm -f /etc/sysctl.d/99-p5r-forward.conf
sysctl -w net.ipv4.ip_forward=0 >/dev/null || true
sysctl -w net.ipv4.conf.all.forwarding=0 >/dev/null || true

log "removing dnsmasq drop-in if present"
rm -f /etc/dnsmasq.d/p5r.conf
systemctl restart dnsmasq 2>/dev/null || true

log "stopping hostapd and removing AP config"
systemctl disable --now hostapd 2>/dev/null || true
rm -f /etc/hostapd/hostapd.conf
rm -f /etc/systemd/system/hostapd.service.d/10-p5r-ordering.conf
rmdir /etc/systemd/system/hostapd.service.d 2>/dev/null || true
rm -f /etc/NetworkManager/conf.d/99-p5r-unmanage-lan.conf
rm -f /etc/NetworkManager/conf.d/99-p5r-unmanage-wan.conf

log "unmasking services we masked for the AP build"
for svc in wpa_supplicant.service NetworkManager-wait-online.service \
           systemd-networkd-wait-online.service; do
    if [[ "$(systemctl is-enabled "${svc}" 2>/dev/null)" == "masked" ]]; then
        systemctl unmask "${svc}" 2>/dev/null || true
    fi
done
systemctl daemon-reload

# Give NM back the wireless interface.
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    systemctl restart NetworkManager
fi

log "rollback complete. Packages left installed. Reboot to confirm clean state."
