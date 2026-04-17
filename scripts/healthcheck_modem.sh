#!/usr/bin/env bash
#
# healthcheck_modem.sh
# Manual, interactive version of the watchdog. Use it to verify end-to-end
# connectivity after bring-up, before trusting the timer.
#
# Does not restart anything. Purely observational.

set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

load_env
require_var WAN_IF
: "${HEALTHCHECK_TARGET:=1.1.1.1}"

echo "== interface =="
ip -br addr show "${WAN_IF}" || die "interface ${WAN_IF} not present"

echo
echo "== default route =="
ip route | grep default || log "no default route"

echo
echo "== ping test via ${WAN_IF} to ${HEALTHCHECK_TARGET} =="
if ping -c 4 -W 3 -I "${WAN_IF}" "${HEALTHCHECK_TARGET}"; then
    log "ping succeeded"
else
    log "ping failed"
    exit 1
fi

echo
echo "== DNS resolution =="
if getent hosts example.com >/dev/null; then
    getent hosts example.com
    log "DNS ok"
else
    log "DNS lookup failed. Check /etc/resolv.conf or dnsmasq."
    exit 2
fi

echo
echo "== https reachability =="
if curl -sS --max-time 8 -o /dev/null -w 'http=%{http_code} ip=%{remote_ip}\n' https://example.com; then
    log "https ok"
else
    log "https failed"
    exit 3
fi

log "healthcheck passed"
