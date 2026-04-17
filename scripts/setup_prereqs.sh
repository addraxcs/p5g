#!/usr/bin/env bash
#
# setup_prereqs.sh
# Install the baseline packages for both path A and path B.
# Idempotent, safe to re-run.
#
# Notes:
# - Package names target Debian/Raspberry Pi OS. If running on another distro,
#   adjust the apt block.
# - We deliberately do NOT install ModemManager. See README for rationale.

set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

require_root

command -v apt-get >/dev/null || die "apt-get not found. This script expects Debian/Raspberry Pi OS."

log "updating apt metadata"
apt-get update -y

PKGS=(
    # Core networking.
    iproute2
    iputils-ping
    nftables
    # Used for downstream DHCP/DNS if pi is the LAN DHCP server.
    dnsmasq
    # Needed when the E3372 boots in CD-ROM mode and must switch to modem.
    usb-modeswitch
    usb-modeswitch-data
    # PPP path; harmless on path A.
    ppp
    # Convenience for AT port inspection; small, optional.
    minicom
    # Wifi AP.
    hostapd
    iw
    rfkill
    wireless-regdb
    # Shell + jq useful for log triage.
    jq
    curl
)

log "installing: ${PKGS[*]}"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${PKGS[@]}"

# We use systemd-networkd on the WAN interface for path A. It is present on
# Pi OS but not enabled by default.
log "enabling systemd-networkd (harmless if already on)"
systemctl enable systemd-networkd

# Confirm no ModemManager is active; if it is, warn the operator.
if systemctl is-active --quiet ModemManager 2>/dev/null; then
    log "WARNING: ModemManager is running. It can interfere with manual PPP."
    log "         Consider: sudo systemctl disable --now ModemManager"
fi

log "prereqs done"
