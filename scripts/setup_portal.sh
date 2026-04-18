#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

require_root
load_env
require_var LAN_GATEWAY
require_var PORTAL_USER
require_var PORTAL_PASS

log "installing flask"
if ! python3 -c "import flask" 2>/dev/null; then
    apt-get install -y python3-flask
fi

PORTAL_BIN=/usr/local/bin/p5r-portal

log "installing portal script to ${PORTAL_BIN}"
install -m 0755 "${P5R_ROOT}/portal/app.py" "${PORTAL_BIN}"

log "writing p5r-portal.service"
cat >/etc/systemd/system/p5r-portal.service <<EOF
[Unit]
Description=p5g config portal
After=network.target hostapd.service
Wants=hostapd.service

[Service]
Type=simple
Environment=PORTAL_BIND=${LAN_GATEWAY}
Environment=PORTAL_PORT=80
Environment=PORTAL_USER=${PORTAL_USER}
Environment=PORTAL_PASS=${PORTAL_PASS}
Environment=P5R_ROOT=${P5R_ROOT}
Environment=P5R_ENV=${P5R_ENV}
ExecStart=/usr/bin/python3 ${PORTAL_BIN}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

log "adding firewall allow for portal on LAN (port 80)"
# The nftables ruleset already allows LAN inbound for SSH and DNS.
# Port 80 on LAN_IF needs an explicit allow if not already present.
if nft list ruleset 2>/dev/null | grep -q "tcp dport 80"; then
    log "port 80 rule already present in nftables, skipping"
else
    log "note: run setup_nat.sh to ensure port 80 is allowed on LAN_IF"
fi

systemctl daemon-reload
systemctl enable --now p5r-portal.service
systemctl --no-pager status p5r-portal.service || true

log "portal available at http://${LAN_GATEWAY}/"
