#!/usr/bin/env bash
#
# detect_modem.sh
# Classify the attached Huawei E3372 as one of:
#   - network  (HiLink firmware: usb0/eth1 appears)
#   - ppp      (stick firmware: /dev/ttyUSB0..2 appears)
#   - storage  (still in CD-ROM mode, needs usb-modeswitch)
#   - unknown  (nothing recognizable showed up)
#
# Read-only. Safe to run repeatedly. Prints a summary plus a final MODE= line.

set -euo pipefail
IFS=$'\n\t'

# Huawei vendor id. The specific product id varies by firmware variant, so we
# only pin the vendor and let the classification come from what kernel surfaces.
HUAWEI_VID="12d1"

info()  { printf '[info]  %s\n' "$*"; }
warn()  { printf '[warn]  %s\n' "$*" >&2; }
fail()  { printf '[fail]  %s\n' "$*" >&2; exit 1; }

command -v lsusb >/dev/null || fail "lsusb not present. Install usbutils."
command -v ip    >/dev/null || fail "ip not present. Install iproute2."

echo "=== lsusb ==="
lsusb || true

echo
echo "=== Huawei devices ==="
huawei_lines="$(lsusb | grep -i "${HUAWEI_VID}:" || true)"
if [[ -z "${huawei_lines}" ]]; then
    warn "no Huawei USB device found. Is the dongle plugged in?"
fi
printf '%s\n' "${huawei_lines:-<none>}"

echo
echo "=== tty nodes ==="
tty_nodes=()
for n in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2 /dev/ttyUSB3; do
    [[ -e "${n}" ]] && tty_nodes+=("${n}")
done
if ((${#tty_nodes[@]})); then
    printf '  %s\n' "${tty_nodes[@]}"
else
    echo "  <none>"
fi

echo
echo "=== candidate WAN network interfaces ==="
# Interfaces that often indicate a modem in network mode.
net_candidates=()
while read -r line; do
    name="$(awk '{print $1}' <<<"${line}")"
    case "${name}" in
        usb0|usb1|eth1|eth2|wwan0|wwan1) net_candidates+=("${name}") ;;
    esac
done < <(ip -br link show 2>/dev/null || true)
if ((${#net_candidates[@]})); then
    printf '  %s\n' "${net_candidates[@]}"
    ip -br addr show
else
    echo "  <none>"
fi

echo
echo "=== storage-mode evidence ==="
# If the modem is presenting as a disk or CD-ROM, the kernel will have added
# an sr* or sd* node for it. This is a sign usb-modeswitch has not fired.
storage_hits="$(lsblk -o NAME,MODEL,SIZE,TYPE 2>/dev/null | grep -iE 'huawei|mobile' || true)"
printf '%s\n' "${storage_hits:-<none>}"

# Classify.
mode="unknown"
if ((${#net_candidates[@]})); then
    mode="network"
elif ((${#tty_nodes[@]})); then
    mode="ppp"
elif [[ -n "${storage_hits}" ]]; then
    mode="storage"
fi

echo
echo "=== classification ==="
echo "MODE=${mode}"

case "${mode}" in
    network)
        echo "Suggested next step: scripts/setup_network_mode.sh after editing .env"
        echo "Likely WAN_IF values to try: ${net_candidates[*]}"
        ;;
    ppp)
        echo "Suggested next step: scripts/setup_ppp_mode.sh after editing .env"
        echo "AT port is usually /dev/ttyUSB2 on the E3372 stick firmware."
        ;;
    storage)
        echo "Suggested next step: install usb-modeswitch and replug."
        echo "See docs/troubleshooting.md (storage mode instead of modem mode)."
        ;;
    unknown)
        echo "No recognizable modem state. Check dmesg, lsusb -t, and replug."
        exit 2
        ;;
esac
