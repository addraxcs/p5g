#!/usr/bin/env bash
#
# setup_nat.sh
# Enable IPv4 forwarding and install the nftables ruleset.
# Reads WAN_IF and LAN_IF from .env.
#
# Idempotent. Rollback: sudo ./scripts/rollback.sh

set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

require_root
load_env
require_var WAN_IF
require_var LAN_IF

# 1. sysctl
log "installing sysctl forwarding config"
install -m 0644 "${P5R_ROOT}/configs/sysctl-forward.conf" /etc/sysctl.d/99-p5r-forward.conf
sysctl --system >/dev/null

fwd="$(sysctl -n net.ipv4.ip_forward || echo 0)"
[[ "${fwd}" == "1" ]] || die "net.ipv4.ip_forward is ${fwd}, expected 1"
log "forwarding enabled"

# 2. nftables
log "rendering nftables ruleset for WAN=${WAN_IF} LAN=${LAN_IF}"
render_template "${P5R_ROOT}/configs/nftables.conf.template" /etc/nftables.conf WAN_IF LAN_IF

# Optional management interface rule.
if [[ -n "${MGMT_IF:-}" && "${MGMT_IF}" != "${LAN_IF}" && "${MGMT_IF}" != "${WAN_IF}" ]]; then
    log "allowing SSH on MGMT_IF=${MGMT_IF}"
    mgmt_rule="iifname \"${MGMT_IF}\" tcp dport 22 ct state new accept"
else
    log "no MGMT_IF set (or it overlaps LAN/WAN); management via LAN/console only"
    mgmt_rule="# no MGMT_IF configured"
fi
# Substitute the placeholder left by render_template.
sed -i "s|__MGMT_RULE__|${mgmt_rule}|" /etc/nftables.conf

# Validate before applying. Avoid leaving the box in a half-broken state.
log "validating ruleset syntax"
nft -c -f /etc/nftables.conf

log "applying ruleset"
nft -f /etc/nftables.conf

log "enabling nftables at boot"
systemctl enable --now nftables

log "nat done. Current ruleset:"
nft list ruleset
