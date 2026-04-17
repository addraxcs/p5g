#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

require_root
load_env
require_var LAN_IF
require_var LAN_GATEWAY
require_var LAN_SUBNET_MASK
require_var DHCP_RANGE_START
require_var DHCP_RANGE_END
require_var DHCP_LEASE

command -v dnsmasq >/dev/null || die "dnsmasq not installed. Run setup_prereqs.sh first."

mkdir -p /etc/dnsmasq.d

render_template "${P5R_ROOT}/configs/dnsmasq.conf.template" /etc/dnsmasq.d/p5r.conf \
    LAN_IF LAN_GATEWAY LAN_SUBNET_MASK DHCP_RANGE_START DHCP_RANGE_END DHCP_LEASE

systemctl enable --now dnsmasq

# Wait for dnsmasq to become active.
for _i in 1 2 3 4 5; do
    systemctl is-active --quiet dnsmasq && break
    sleep 1
done
systemctl is-active --quiet dnsmasq \
    || { journalctl -u dnsmasq -n 20 --no-pager >&2; die "dnsmasq failed to start."; }

log "dnsmasq active. DHCP ${DHCP_RANGE_START}-${DHCP_RANGE_END} on ${LAN_IF}"
