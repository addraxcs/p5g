# Shared helpers. Source, do not execute.
# Requires the caller to have `set -euo pipefail` already.

# Where the env lives on the pi. The repo root is typically ~/private-5g-router.
FARM_ROOT="${FARM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FARM_ENV="${FARM_ENV:-${FARM_ROOT}/.env}"

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
    [[ $(id -u) -eq 0 ]] || die "must run as root (use sudo)"
}

load_env() {
    [[ -f "${FARM_ENV}" ]] || die "missing ${FARM_ENV}. Copy .env.example and fill values."
    # Only pull KEY=VALUE lines.
    set -a
    # shellcheck disable=SC1090
    source "${FARM_ENV}"
    set +a
}

require_var() {
    local name="$1"
    local val="${!name:-}"
    [[ -n "${val}" && "${val}" != "PENDING" ]] || die "env var ${name} is unset or PENDING"
}

# Render a template by substituting __KEY__ placeholders with env values.
# Usage: render_template <src> <dst> KEY1 KEY2 ...
render_template() {
    local src="$1" dst="$2"; shift 2
    [[ -f "${src}" ]] || die "template missing: ${src}"
    local tmp
    tmp="$(mktemp)"
    cp "${src}" "${tmp}"
    local key val
    for key in "$@"; do
        val="${!key:-}"
        [[ -n "${val}" ]] || die "cannot render ${src}: ${key} is empty"
        # Use a delimiter unlikely to appear in values.
        sed -i "s|__${key}__|${val}|g" "${tmp}"
    done
    install -m 0644 "${tmp}" "${dst}"
    rm -f "${tmp}"
    log "rendered ${src} -> ${dst}"
}
