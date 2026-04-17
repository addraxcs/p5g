#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

ENV_FILE="${SCRIPT_DIR}/../.env"

SUFFIX=$(tr -dc 'A-Z0-9' < /dev/urandom | head -c 6)
SSID="p5n-${SUFFIX}"
PIN=$(tr -dc '0-9' < /dev/urandom | head -c 12)

if [[ -f "${ENV_FILE}" ]]; then
    sed -i "s|^WIFI_SSID=.*|WIFI_SSID=${SSID}|" "${ENV_FILE}"
    sed -i "s|^WIFI_PASSPHRASE=.*|WIFI_PASSPHRASE=${PIN}|" "${ENV_FILE}"
    log "Written to .env:"
else
    log "No .env found - copy .env.example to .env first, or export manually:"
fi

echo "  WIFI_SSID=${SSID}"
echo "  WIFI_PASSPHRASE=${PIN}"
