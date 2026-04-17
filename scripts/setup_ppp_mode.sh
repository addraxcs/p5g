#!/usr/bin/env bash
#
# setup_ppp_mode.sh
# Path B: E3372 exposes /dev/ttyUSB*. Configure pppd with a chat script
# keyed on APN.
#
# Prereq: detect_modem.sh printed MODE=ppp, and APN + PPP_DEV in .env are set.
#
# Note on PPP_DEV:
#   The E3372 stick firmware often exposes three serial nodes. The AT command
#   port is usually /dev/ttyUSB2 but this is not guaranteed. If PPP fails to
#   initialize, try /dev/ttyUSB0 and /dev/ttyUSB1.

set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

require_root
load_env
require_var APN
require_var PPP_DEV

[[ -e "${PPP_DEV}" ]] || die "PPP_DEV=${PPP_DEV} does not exist. Check /dev/ttyUSB* nodes."
command -v pppd >/dev/null || die "pppd not installed. Run setup_prereqs.sh."

PEER=/etc/ppp/peers/p5r-wwan
CHAT=/etc/chatscripts/p5r-wwan

mkdir -p /etc/chatscripts

log "writing ${CHAT}"
cat >"${CHAT}" <<EOF
# private-5g-router chat script. Pair: ${PEER}
ABORT           'BUSY'
ABORT           'NO CARRIER'
ABORT           'ERROR'
ABORT           'NO DIALTONE'
ABORT           'NO ANSWER'
TIMEOUT         30
''              'AT'
'OK'            'ATZ'
'OK'            'AT+CFUN=1'
'OK'            'AT+CGDCONT=1,"IP","${APN}"'
'OK'            'ATD*99#'
'CONNECT'       ''
EOF
chmod 0644 "${CHAT}"

log "writing ${PEER}"
cat >"${PEER}" <<EOF
# private-5g-router PPP peer for Huawei E3372 on ${PPP_DEV}
${PPP_DEV}
115200
defaultroute
usepeerdns
noauth
noipdefault
nocrtscts
lock
persist
holdoff 10
maxfail 0
noipx
novj
novjccomp
connect '/usr/sbin/chat -v -f ${CHAT}'
EOF
# peers file may contain user/pass. Lock it down.
chmod 0600 "${PEER}"

if [[ -n "${PPP_USER:-}" && -n "${PPP_PASS:-}" ]]; then
    log "writing /etc/ppp/pap-secrets and chap-secrets entries"
    # Remove any prior p5r entry.
    for f in /etc/ppp/pap-secrets /etc/ppp/chap-secrets; do
        [[ -f "${f}" ]] || { echo '' >"${f}"; chmod 0600 "${f}"; }
        sed -i "/^# p5r-begin$/,/^# p5r-end$/d" "${f}"
        printf '# p5r-begin\n%s * %s *\n# p5r-end\n' "${PPP_USER}" "${PPP_PASS}" >>"${f}"
    done
    # Tell pppd to authenticate.
    sed -i 's|^noauth$|user "'"${PPP_USER}"'"|' "${PEER}"
fi

log "peer + chatscript installed"
log "to test interactively: sudo pppd call p5r-wwan nodetach debug"
log "when stable, install_services.sh will make p5r-wan.service drive pppd."
