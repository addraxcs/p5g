#!/usr/bin/env bash
#
# setup_vpn.sh
# Install WireGuard and route ALL LAN traffic through wg0 with a kill switch.
# Reads VPN and WG_ variables from .env.
#
# Usage:  sudo ./scripts/setup_vpn.sh
# Revert: sudo ./scripts/rollback.sh

set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

require_root
load_env

require_var WAN_IF
require_var LAN_IF
require_var WG_PRIVATE_KEY
require_var WG_ADDRESS
require_var WG_PEER_PUBLIC_KEY
require_var WG_ENDPOINT
require_var WG_DNS

VPN_IF="${VPN_IF:-wg0}"
WG_ALLOWED_IPS="${WG_ALLOWED_IPS:-0.0.0.0/0}"
WG_PERSISTENT_KEEPALIVE="${WG_PERSISTENT_KEEPALIVE:-25}"

# 1. Install wireguard-tools
log "installing wireguard-tools"
apt-get install -y wireguard-tools >/dev/null

# 2. Render wg0.conf (0600 — contains private key)
log "rendering /etc/wireguard/${VPN_IF}.conf"
mkdir -p /etc/wireguard
render_template \
    "${P5R_ROOT}/configs/wireguard/wg0.conf.template" \
    "/etc/wireguard/${VPN_IF}.conf" \
    WG_PRIVATE_KEY WG_ADDRESS WG_DNS \
    WG_PEER_PUBLIC_KEY WG_ENDPOINT \
    WG_ALLOWED_IPS WG_PERSISTENT_KEEPALIVE
chmod 0600 "/etc/wireguard/${VPN_IF}.conf"

# 3. Ensure wg-quick starts after nftables so the kill-switch ruleset is
# active before the tunnel comes up. Without this ordering, a reboot race
# could briefly forward LAN traffic to WAN before wg0 is ready.
mkdir -p "/etc/systemd/system/wg-quick@${VPN_IF}.service.d"
cat >"/etc/systemd/system/wg-quick@${VPN_IF}.service.d/10-p5r-ordering.conf" <<EOF
[Unit]
After=nftables.service
Wants=nftables.service
EOF
chmod 0644 "/etc/systemd/system/wg-quick@${VPN_IF}.service.d/10-p5r-ordering.conf"

log "enabling wg-quick@${VPN_IF}"
systemctl daemon-reload
systemctl enable "wg-quick@${VPN_IF}"
systemctl restart "wg-quick@${VPN_IF}"

# Wait up to 10 s for the interface to appear
for i in $(seq 1 10); do
    if ip link show "${VPN_IF}" &>/dev/null; then
        log "${VPN_IF} interface is up"
        break
    fi
    sleep 1
    [[ "${i}" -lt 10 ]] || die "${VPN_IF} did not come up after 10 seconds — check 'wg show' and journalctl"
done

# 4. Apply VPN-mode nftables ruleset with kill switch
log "applying VPN-mode nftables ruleset (kill switch: LAN -> ${VPN_IF} only)"
render_template \
    "${P5R_ROOT}/configs/nftables-vpn.conf.template" \
    /etc/nftables.conf \
    WAN_IF LAN_IF VPN_IF

# Inject management interface SSH rule (same logic as setup_nat.sh)
if [[ -n "${MGMT_IF:-}" && "${MGMT_IF}" != "${LAN_IF}" && "${MGMT_IF}" != "${WAN_IF}" ]]; then
    log "allowing SSH on MGMT_IF=${MGMT_IF}"
    mgmt_rule="iifname \"${MGMT_IF}\" tcp dport 22 ct state new accept"
else
    mgmt_rule="# no MGMT_IF configured"
fi
sed -i "s|__MGMT_RULE__|${mgmt_rule}|" /etc/nftables.conf

log "validating ruleset syntax"
nft -c -f /etc/nftables.conf

log "applying ruleset"
nft -f /etc/nftables.conf

# 5. Basic connectivity check through the tunnel
log "checking tunnel connectivity"
if ping -c 2 -W 4 -I "${VPN_IF}" 1.1.1.1 &>/dev/null; then
    log "tunnel connectivity OK"
else
    log "WARNING: ping through ${VPN_IF} failed"
    log "The interface is up but traffic may not be flowing."
    log "Check: wg show | ip route | journalctl -u wg-quick@${VPN_IF}"
fi

log ""
log "VPN setup complete."
log "  Tunnel    : ${VPN_IF}"
log "  Endpoint  : ${WG_ENDPOINT}"
log "  AllowedIPs: ${WG_ALLOWED_IPS}"
log "  Kill switch active: forwarding to ${WAN_IF} is blocked"
log ""
log "Run 'wg show' to inspect the tunnel."
log "Run 'sudo ./scripts/rollback.sh' to revert."
