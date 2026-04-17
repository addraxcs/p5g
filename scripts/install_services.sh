#!/usr/bin/env bash
#
# install_services.sh
# Install systemd units for WAN + watchdog. Picks the unit shape based on
# MODE (network vs ppp). Reads MODE from argv or autodetects.
#
# Usage: sudo ./install_services.sh [network|ppp]

set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

require_root
load_env
require_var WAN_IF

MODE="${1:-}"
if [[ -z "${MODE}" ]]; then
    if [[ "${WAN_IF}" == ppp* ]]; then
        MODE="ppp"
    else
        MODE="network"
    fi
fi

case "${MODE}" in
    network|ppp) ;;
    *) die "mode must be 'network' or 'ppp', got '${MODE}'" ;;
esac

log "installing services for mode=${MODE}, WAN_IF=${WAN_IF}"

# ---- /etc/default/p5r: env file for watchdog ----
cat >/etc/default/p5r <<EOF
# private-5g-router watchdog defaults. Edit and restart p5r-watchdog.timer to apply.
HEALTHCHECK_TARGET=${HEALTHCHECK_TARGET:-1.1.1.1}
HEALTHCHECK_FAILURES=${HEALTHCHECK_FAILURES:-3}
WAN_IF=${WAN_IF}
MODE=${MODE}
EOF
chmod 0644 /etc/default/p5r

# ---- /usr/local/bin/p5r-wan-up: used by network-mode oneshot ----
install -m 0755 /dev/stdin /usr/local/bin/p5r-wan-up <<'EOF'
#!/usr/bin/env bash
# Waits for the WAN interface to have an IPv4 address.
set -euo pipefail
source /etc/default/p5r
for _ in $(seq 1 60); do
    if ip -4 -br addr show "$WAN_IF" 2>/dev/null | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/'; then
        exit 0
    fi
    sleep 1
done
echo "WAN $WAN_IF did not come up in 60s" >&2
exit 1
EOF

# ---- /usr/local/bin/p5r-healthcheck ----
install -m 0755 /dev/stdin /usr/local/bin/p5r-healthcheck <<'EOF'
#!/usr/bin/env bash
# Ping HEALTHCHECK_TARGET via WAN_IF. If it fails HEALTHCHECK_FAILURES times
# in a row (counter file), restart p5r-wan.service.
set -euo pipefail
source /etc/default/p5r
TARGET="${HEALTHCHECK_TARGET:-1.1.1.1}"
MAXFAIL="${HEALTHCHECK_FAILURES:-3}"
STATE=/run/p5r/healthfail
mkdir -p /run/p5r
count=0
[[ -f "$STATE" ]] && count=$(<"$STATE")
if ping -c 1 -W 3 -I "$WAN_IF" "$TARGET" >/dev/null 2>&1; then
    echo 0 >"$STATE"
    exit 0
fi
count=$((count+1))
echo "$count" >"$STATE"
echo "healthcheck fail $count/$MAXFAIL on $WAN_IF to $TARGET" >&2
if (( count >= MAXFAIL )); then
    echo 0 >"$STATE"
    systemctl restart p5r-wan.service || true
fi
exit 1
EOF

# ---- p5r-wan.service, rendered per mode ----
WAN_UNIT=/etc/systemd/system/p5r-wan.service
if [[ "${MODE}" == "network" ]]; then
    cat >"${WAN_UNIT}" <<EOF
[Unit]
Description=private-5g-router WAN (network mode on ${WAN_IF})
After=network-pre.target systemd-networkd.service
Wants=systemd-networkd.service

[Service]
Type=oneshot
EnvironmentFile=/etc/default/p5r
ExecStart=/usr/local/bin/p5r-wan-up
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
else
    # ppp mode
    cat >"${WAN_UNIT}" <<EOF
[Unit]
Description=private-5g-router WAN (ppp mode)
After=network-pre.target
Wants=network-pre.target

[Service]
Type=simple
ExecStart=/usr/sbin/pppd call p5r-wwan nodetach
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
fi
chmod 0644 "${WAN_UNIT}"

# ---- p5r-watchdog service + timer ----
cat >/etc/systemd/system/p5r-watchdog.service <<'EOF'
[Unit]
Description=private-5g-router watchdog
After=p5r-wan.service
Wants=p5r-wan.service

[Service]
Type=oneshot
EnvironmentFile=/etc/default/p5r
ExecStart=/usr/local/bin/p5r-healthcheck
SuccessExitStatus=0 1
EOF

cat >/etc/systemd/system/p5r-watchdog.timer <<'EOF'
[Unit]
Description=private-5g-router watchdog timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=60s
Unit=p5r-watchdog.service

[Install]
WantedBy=timers.target
EOF

chmod 0644 /etc/systemd/system/p5r-watchdog.service /etc/systemd/system/p5r-watchdog.timer

log "reloading systemd"
systemctl daemon-reload

log "enabling p5r-wan.service + p5r-watchdog.timer"
systemctl enable --now p5r-wan.service
systemctl enable --now p5r-watchdog.timer

log "done. Status:"
systemctl --no-pager --full status p5r-wan.service || true
systemctl --no-pager list-timers | grep p5r-watchdog || true
