#!/usr/bin/env bash
#
# gather_state.sh
# Capture a wide, read-only snapshot of the pi's networking and USB state.
# Intended to run before and after changes so diffs are easy to review.
# Prints to stdout. Pipe to a file: `sudo ./gather_state.sh | tee state.txt`.

set -euo pipefail
IFS=$'\n\t'

section() { printf '\n===== %s =====\n' "$*"; }
try()     { "$@" 2>&1 || printf '(command failed: %s)\n' "$*"; }

section "uname / os-release"
try uname -a
try cat /etc/os-release

section "date / uptime"
try date -u
try uptime

section "lsusb"
try lsusb
try lsusb -t

section "dmesg (last 120 lines)"
try dmesg --ctime | tail -n 120

section "loaded modem modules"
try lsmod | grep -E 'cdc_ether|cdc_ncm|rndis_host|option|usb_wwan|huawei_cdc_ncm|qmi_wwan' || echo "(none)"

section "ip link"
try ip -br link
section "ip addr"
try ip -br addr
section "ip route v4"
try ip route
section "ip route v6"
try ip -6 route

section "DNS state"
if command -v resolvectl >/dev/null 2>&1; then
    try resolvectl status
else
    try cat /etc/resolv.conf
fi

section "nftables ruleset"
try nft list ruleset || echo "(nft not installed or no rules)"

section "sysctl forwarding"
try sysctl net.ipv4.ip_forward
try sysctl net.ipv6.conf.all.forwarding

section "systemd networkd status"
try systemctl is-active systemd-networkd
try networkctl status 2>/dev/null || true

section "ppp peers present"
try ls -l /etc/ppp/peers 2>/dev/null || echo "(none)"

section "serial devices"
try ls -l /dev/ttyUSB* 2>/dev/null || echo "(none)"
try ls -l /dev/serial/by-id 2>/dev/null || echo "(none)"

section "journal (last 80 lines, networkd + pppd)"
try journalctl -u systemd-networkd -n 40 --no-pager 2>/dev/null || true
try journalctl -u p5r-wan.service -n 40 --no-pager 2>/dev/null || true
try journalctl -t pppd -n 40 --no-pager 2>/dev/null || true

printf '\n(gather_state.sh complete)\n'
