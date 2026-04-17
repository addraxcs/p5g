#!/usr/bin/env python3
"""
Config portal for private-5g-router.
Flask app served on LAN_GATEWAY:80.
Manages WiFi (hostapd) and optional WireGuard VPN settings.
Runs as root.
"""

import os
import re
import secrets
import subprocess

from flask import Flask, flash, redirect, render_template, request, Response, url_for

HOSTAPD_CONF  = os.environ.get("HOSTAPD_CONF", "/etc/hostapd/hostapd.conf")
DNSMASQ_CONF  = os.environ.get("DNSMASQ_CONF", "/etc/dnsmasq.d/p5r.conf")
P5R_DEFAULTS  = os.environ.get("P5R_DEFAULTS", "/etc/default/p5r")
PORT         = int(os.environ.get("PORTAL_PORT", "80"))
BIND         = os.environ.get("PORTAL_BIND", "0.0.0.0")
SECRET       = os.environ.get("PORTAL_SECRET", os.urandom(24).hex())
DRY_RUN      = os.environ.get("DRY_RUN", "").lower() in ("1", "true", "yes")
PORTAL_USER  = os.environ.get("PORTAL_USER", "admin")
PORTAL_PASS  = os.environ.get("PORTAL_PASS", "p5g123")
P5R_ROOT     = os.environ.get("P5R_ROOT", "/root/private-5g-router")
P5R_ENV      = os.environ.get("P5R_ENV", os.path.join(P5R_ROOT, ".env"))
VPN_IF       = os.environ.get("VPN_IF", "wg0")
SETUP_VPN    = os.path.join(P5R_ROOT, "scripts/setup_vpn.sh")
SETUP_NAT    = os.path.join(P5R_ROOT, "scripts/setup_nat.sh")

CHANNELS_24GHZ = list(range(1, 14))

COUNTRIES = [
    ("AU", "Australia"), ("AT", "Austria"), ("BE", "Belgium"), ("BR", "Brazil"),
    ("CA", "Canada"), ("CN", "China"), ("DK", "Denmark"), ("FI", "Finland"),
    ("FR", "France"), ("DE", "Germany"), ("IN", "India"), ("IE", "Ireland"),
    ("IT", "Italy"), ("JP", "Japan"), ("MX", "Mexico"), ("NL", "Netherlands"),
    ("NZ", "New Zealand"), ("NO", "Norway"), ("PL", "Poland"), ("PT", "Portugal"),
    ("ZA", "South Africa"), ("ES", "Spain"), ("SE", "Sweden"), ("CH", "Switzerland"),
    ("GB", "United Kingdom"), ("US", "United States"),
]

WG_FIELDS = [
    ("WG_PRIVATE_KEY",          "Private Key",         "password", "From [Interface] PrivateKey"),
    ("WG_ADDRESS",              "Tunnel Address",       "text",     "e.g. 10.8.0.2/32"),
    ("WG_DNS",                  "DNS",                  "text",     "e.g. 1.1.1.1"),
    ("WG_PEER_PUBLIC_KEY",      "Peer Public Key",      "text",     "From [Peer] PublicKey"),
    ("WG_ENDPOINT",             "Endpoint",             "text",     "e.g. vpn.example.com:51820"),
    ("WG_ALLOWED_IPS",          "Allowed IPs",          "text",     "0.0.0.0/0 routes all traffic"),
    ("WG_PERSISTENT_KEEPALIVE", "Persistent Keepalive", "text",     "Seconds, typically 25"),
]

app = Flask(__name__)
app.secret_key = SECRET


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

def _check_auth():
    auth = request.authorization
    if not auth:
        return False
    return (
        secrets.compare_digest(auth.username, PORTAL_USER)
        and secrets.compare_digest(auth.password, PORTAL_PASS)
    )


def _auth_required():
    return Response(
        "Authentication required.",
        401,
        {"WWW-Authenticate": 'Basic realm="Router Setup"'},
    )


# ---------------------------------------------------------------------------
# hostapd helpers
# ---------------------------------------------------------------------------

def read_hostapd():
    fields = {"ssid": "", "wpa_passphrase": "", "channel": "6", "country_code": "GB"}
    try:
        with open(HOSTAPD_CONF) as f:
            for line in f:
                line = line.strip()
                for key in fields:
                    if line.startswith(f"{key}="):
                        fields[key] = line[len(key) + 1:]
    except FileNotFoundError:
        pass
    return fields


def write_hostapd(ssid, passphrase, channel, country):
    with open(HOSTAPD_CONF) as f:
        content = f.read()
    content = re.sub(r"^ssid=.*$",           f"ssid={ssid}",                 content, flags=re.MULTILINE)
    content = re.sub(r"^wpa_passphrase=.*$", f"wpa_passphrase={passphrase}", content, flags=re.MULTILINE)
    content = re.sub(r"^channel=.*$",        f"channel={channel}",           content, flags=re.MULTILINE)
    content = re.sub(r"^country_code=.*$",   f"country_code={country}",      content, flags=re.MULTILINE)
    with open(HOSTAPD_CONF, "w") as f:
        f.write(content)
    if not DRY_RUN:
        subprocess.run(["systemctl", "restart", "hostapd"], check=True)


# ---------------------------------------------------------------------------
# .env helpers
# ---------------------------------------------------------------------------

def read_env():
    result = {}
    try:
        with open(P5R_ENV) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, _, val = line.partition("=")
                    result[key.strip()] = val.strip()
    except FileNotFoundError:
        pass
    return result


def update_env(updates: dict):
    try:
        with open(P5R_ENV) as f:
            lines = f.readlines()
    except FileNotFoundError:
        lines = []

    written = set()
    new_lines = []
    for line in lines:
        stripped = line.strip()
        if stripped and not stripped.startswith("#") and "=" in stripped:
            key = stripped.partition("=")[0].strip()
            if key in updates:
                new_lines.append(f"{key}={updates[key]}\n")
                written.add(key)
                continue
        new_lines.append(line)

    for key, val in updates.items():
        if key not in written:
            new_lines.append(f"{key}={val}\n")

    with open(P5R_ENV, "w") as f:
        f.writelines(new_lines)


# ---------------------------------------------------------------------------
# VPN helpers
# ---------------------------------------------------------------------------

def vpn_is_active():
    result = subprocess.run(
        ["systemctl", "is-active", f"wg-quick@{VPN_IF}"],
        capture_output=True, text=True,
    )
    return result.stdout.strip() == "active"


def vpn_details():
    handshake = ""
    endpoint = ""
    if not os.path.exists(f"/sys/class/net/{VPN_IF}"):
        return handshake, endpoint
    try:
        r = subprocess.run(["wg", "show", VPN_IF], capture_output=True, text=True, timeout=3)
        for line in r.stdout.splitlines():
            line = line.strip()
            if line.startswith("endpoint:"):
                endpoint = line.split(":", 1)[1].strip()
            if line.startswith("latest handshake:"):
                handshake = line.split(":", 1)[1].strip()
    except Exception:
        pass
    return handshake, endpoint


def run_script(path, timeout=60):
    if DRY_RUN:
        return True, f"[DRY_RUN] would run: {path}"
    try:
        r = subprocess.run(["bash", path], capture_output=True, text=True, timeout=timeout)
        return r.returncode == 0, (r.stdout + r.stderr).strip()
    except subprocess.TimeoutExpired:
        return False, f"Script timed out after {timeout}s"
    except Exception as e:
        return False, str(e)


def parse_wg_conf(content):
    """Parse a WireGuard .conf file, return dict of WG_* env keys."""
    field_map = {
        ("interface", "PrivateKey"):        "WG_PRIVATE_KEY",
        ("interface", "Address"):           "WG_ADDRESS",
        ("interface", "DNS"):               "WG_DNS",
        ("peer",      "PublicKey"):         "WG_PEER_PUBLIC_KEY",
        ("peer",      "Endpoint"):          "WG_ENDPOINT",
        ("peer",      "AllowedIPs"):        "WG_ALLOWED_IPS",
        ("peer",      "PersistentKeepalive"): "WG_PERSISTENT_KEEPALIVE",
    }
    result = {}
    section = None
    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].lower()
            continue
        if "=" in line and section:
            key, _, val = line.partition("=")
            env_key = field_map.get((section, key.strip()))
            if env_key:
                result[env_key] = val.strip()
    return result


# ---------------------------------------------------------------------------
# dnsmasq helpers
# ---------------------------------------------------------------------------

def read_dnsmasq_conf():
    """Return dict with dns (list of IPs) and dhcp (dict of range fields)."""
    result = {"dns": [], "dhcp": {"start": "", "end": "", "mask": "", "lease": ""}}
    try:
        with open(DNSMASQ_CONF) as f:
            for line in f:
                line = line.strip()
                if line.startswith("server="):
                    result["dns"].append(line[len("server="):])
                elif line.startswith("dhcp-range="):
                    parts = line[len("dhcp-range="):].split(",")
                    if len(parts) >= 4:
                        result["dhcp"] = {"start": parts[0], "end": parts[1],
                                          "mask": parts[2], "lease": parts[3]}
    except FileNotFoundError:
        pass
    while len(result["dns"]) < 2:
        result["dns"].append("")
    return result


def write_dnsmasq_dns(dns1, dns2):
    try:
        with open(DNSMASQ_CONF) as f:
            lines = f.readlines()
    except FileNotFoundError:
        return
    new_lines = [l for l in lines if not l.strip().startswith("server=")]
    insert_at = next((i for i, l in enumerate(new_lines) if "no-resolv" in l), len(new_lines))
    servers = [f"server={ip}\n" for ip in [dns1, dns2] if ip]
    new_lines[insert_at + 1:insert_at + 1] = servers
    if not DRY_RUN:
        with open(DNSMASQ_CONF, "w") as f:
            f.writelines(new_lines)
        subprocess.run(["systemctl", "restart", "dnsmasq"], check=False)


def write_dnsmasq_dhcp(start, end, lease):
    cfg = read_dnsmasq_conf()
    mask = cfg["dhcp"]["mask"] or "255.255.255.0"
    new_range = f"dhcp-range={start},{end},{mask},{lease}"
    try:
        with open(DNSMASQ_CONF) as f:
            content = f.read()
    except FileNotFoundError:
        return
    content = re.sub(r"^dhcp-range=.*$", new_range, content, flags=re.MULTILINE)
    if not DRY_RUN:
        with open(DNSMASQ_CONF, "w") as f:
            f.write(content)
        subprocess.run(["systemctl", "restart", "dnsmasq"], check=False)
    update_env({"DHCP_RANGE_START": start, "DHCP_RANGE_END": end, "DHCP_LEASE": lease})


# ---------------------------------------------------------------------------
# /etc/default/p5r helpers
# ---------------------------------------------------------------------------

def read_p5r_defaults():
    result = {"HEALTHCHECK_TARGET": "1.1.1.1", "HEALTHCHECK_FAILURES": "3"}
    try:
        with open(P5R_DEFAULTS) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, _, val = line.partition("=")
                    result[key.strip()] = val.strip()
    except FileNotFoundError:
        pass
    return result


def write_p5r_defaults(updates):
    try:
        with open(P5R_DEFAULTS) as f:
            lines = f.readlines()
    except FileNotFoundError:
        lines = []
    written = set()
    new_lines = []
    for line in lines:
        stripped = line.strip()
        if stripped and not stripped.startswith("#") and "=" in stripped:
            key = stripped.partition("=")[0].strip()
            if key in updates:
                new_lines.append(f"{key}={updates[key]}\n")
                written.add(key)
                continue
        new_lines.append(line)
    for key, val in updates.items():
        if key not in written:
            new_lines.append(f"{key}={val}\n")
    if not DRY_RUN:
        with open(P5R_DEFAULTS, "w") as f:
            f.writelines(new_lines)
        subprocess.run(["systemctl", "restart", "p5r-watchdog.timer"], check=False)
    update_env(updates)


# ---------------------------------------------------------------------------
# Log helper
# ---------------------------------------------------------------------------

def get_logs(service, lines=40):
    if DRY_RUN:
        return "\n".join([
            f"Apr 18 08:00:0{i} pi {service}[1]: sample log line {i}"
            for i in range(1, 6)
        ])
    try:
        r = subprocess.run(
            ["journalctl", "-u", service, "-n", str(lines), "--no-pager", "--no-hostname"],
            capture_output=True, text=True, timeout=5,
        )
        return r.stdout.strip() or f"No log entries for {service}."
    except Exception as e:
        return str(e)


# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------

def _valid_ip(ip):
    parts = ip.strip().split(".")
    if len(parts) != 4:
        return False
    return all(p.isdigit() and 0 <= int(p) <= 255 for p in parts)


def _valid_lease(s):
    return bool(re.fullmatch(r"\d+[mhd]", s.strip()))


def validate_wg(values):
    errors = []
    for key in ["WG_PRIVATE_KEY", "WG_ADDRESS", "WG_PEER_PUBLIC_KEY", "WG_ENDPOINT", "WG_DNS"]:
        if not values.get(key) or values[key] == "PENDING":
            errors.append(f"{key} is required.")
    return errors


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.route("/", methods=["GET", "POST"])
def index():
    if not _check_auth():
        return _auth_required()

    cfg = read_hostapd()
    active = vpn_is_active()

    if request.method == "POST":
        ssid       = request.form.get("ssid", "").strip()
        passphrase = request.form.get("passphrase", "").strip()
        channel    = request.form.get("channel", "6").strip()
        country    = request.form.get("country", "GB").strip()

        errors = []
        if not ssid:
            errors.append("SSID is required.")
        elif len(ssid) > 32:
            errors.append("SSID must be 32 characters or fewer.")
        if passphrase and len(passphrase) < 8:
            errors.append("Passphrase must be at least 8 characters.")
        if not passphrase:
            passphrase = cfg["wpa_passphrase"]
        if channel not in [str(c) for c in CHANNELS_24GHZ]:
            errors.append("Invalid channel.")
        if country not in [c for c, _ in COUNTRIES]:
            errors.append("Invalid country code.")

        if errors:
            for e in errors:
                flash(e, "err")
        else:
            write_hostapd(ssid, passphrase, channel, country)
            flash(f'Saved. Reconnect to "{ssid}".', "ok")
            cfg = read_hostapd()

    return render_template(
        "wifi.html",
        active_tab="wifi",
        vpn_active=active,
        ssid=cfg["ssid"],
        passphrase=cfg["wpa_passphrase"],
        channel=int(cfg.get("channel", 6)),
        country=cfg.get("country_code", "GB"),
        channels=CHANNELS_24GHZ,
        countries=COUNTRIES,
    )


@app.route("/vpn", methods=["GET", "POST"])
def vpn():
    if not _check_auth():
        return _auth_required()

    mode = request.args.get("mode", "manual")
    active = vpn_is_active()
    handshake, endpoint_live = vpn_details()
    env = read_env()
    wg = {key: env.get(key, "") for key, *_ in WG_FIELDS}

    if request.method == "POST":
        action = request.form.get("action", "save")

        if action == "import":
            conf_content = request.form.get("conf_content", "")
            parsed = parse_wg_conf(conf_content)
            if not parsed:
                flash("Could not parse .conf — check the format and try again.", "err")
            else:
                update_env(parsed)
                missing = [k for k in ["WG_PRIVATE_KEY", "WG_ADDRESS", "WG_PEER_PUBLIC_KEY", "WG_ENDPOINT"] if k not in parsed]
                if missing:
                    flash(f"Imported partial config. Missing: {', '.join(missing)}.", "err")
                else:
                    flash("Config imported and saved to .env. Review below then enable.", "ok")
            return redirect(url_for("vpn", mode="manual"))

        values = {key: request.form.get(key, "").strip() for key, *_ in WG_FIELDS}

        to_write = {k: v for k, v in values.items() if v}
        if to_write:
            update_env(to_write)
            wg.update(to_write)

        if action == "save":
            flash("Configuration saved to .env.", "ok")

        elif action in ("enable", "restart"):
            errors = validate_wg({**wg, **to_write})
            if errors:
                for e in errors:
                    flash(e, "err")
            else:
                if action == "enable":
                    ok, out = run_script(SETUP_VPN, timeout=90)
                    if ok:
                        flash("VPN enabled. Kill switch active — all LAN traffic routes through the tunnel.", "ok")
                    else:
                        flash(f"setup_vpn.sh failed: {out[-300:]}", "err")
                else:
                    if not DRY_RUN:
                        subprocess.run(["systemctl", "restart", f"wg-quick@{VPN_IF}"], check=False)
                    flash("Tunnel restarted with new configuration.", "ok")
                active = vpn_is_active()
                handshake, endpoint_live = vpn_details()

        elif action == "disable":
            if not DRY_RUN:
                subprocess.run(["systemctl", "disable", "--now", f"wg-quick@{VPN_IF}"], check=False)
                ok, out = run_script(SETUP_NAT, timeout=30)
                if not ok:
                    flash(f"Warning: setup_nat.sh returned an error: {out[-200:]}", "err")
            flash("VPN disabled. Normal routing restored.", "ok")
            active = False
            handshake = ""
            endpoint_live = ""

        return redirect(url_for("vpn"))

    return render_template(
        "vpn.html",
        active_tab="vpn",
        vpn_active=active,
        handshake=handshake,
        endpoint_live=endpoint_live,
        wg=wg,
        wg_fields=WG_FIELDS,
        mode=mode,
    )


@app.route("/advanced", methods=["GET", "POST"])
def advanced():
    if not _check_auth():
        return _auth_required()

    active = vpn_is_active()

    if request.method == "POST":
        action = request.form.get("action", "")

        if action == "dns":
            dns1 = request.form.get("dns1", "").strip()
            dns2 = request.form.get("dns2", "").strip()
            errors = []
            if dns1 and not _valid_ip(dns1):
                errors.append("DNS 1 is not a valid IP address.")
            if dns2 and not _valid_ip(dns2):
                errors.append("DNS 2 is not a valid IP address.")
            if not dns1 and not dns2:
                errors.append("At least one DNS server is required.")
            if errors:
                for e in errors:
                    flash(e, "err")
            else:
                write_dnsmasq_dns(dns1, dns2)
                flash("[DRY_RUN] DNS updated." if DRY_RUN else "DNS servers updated.", "ok")

        elif action == "dhcp":
            start = request.form.get("dhcp_start", "").strip()
            end   = request.form.get("dhcp_end", "").strip()
            lease = request.form.get("dhcp_lease", "").strip()
            errors = []
            if not _valid_ip(start):
                errors.append("DHCP range start is not a valid IP.")
            if not _valid_ip(end):
                errors.append("DHCP range end is not a valid IP.")
            if start and end and _valid_ip(start) and _valid_ip(end):
                if int(start.split(".")[-1]) >= int(end.split(".")[-1]):
                    errors.append("Range start last octet must be lower than end.")
            if not _valid_lease(lease):
                errors.append("Lease time must match pattern like 12h, 30m, or 1d.")
            if errors:
                for e in errors:
                    flash(e, "err")
            else:
                write_dnsmasq_dhcp(start, end, lease)
                flash("[DRY_RUN] DHCP range updated." if DRY_RUN else "DHCP range updated.", "ok")

        elif action == "watchdog":
            target    = request.form.get("hc_target", "").strip()
            threshold = request.form.get("hc_failures", "").strip()
            errors = []
            if not _valid_ip(target):
                errors.append("Healthcheck target is not a valid IP address.")
            if not threshold.isdigit() or not (1 <= int(threshold) <= 10):
                errors.append("Failure threshold must be an integer between 1 and 10.")
            if errors:
                for e in errors:
                    flash(e, "err")
            else:
                write_p5r_defaults({"HEALTHCHECK_TARGET": target, "HEALTHCHECK_FAILURES": threshold})
                flash("[DRY_RUN] Watchdog settings saved." if DRY_RUN else "Watchdog settings saved.", "ok")

        return redirect(url_for("advanced"))

    dns_dhcp = read_dnsmasq_conf()
    watchdog  = read_p5r_defaults()
    logs = {
        svc: get_logs(svc)
        for svc in ["hostapd", "dnsmasq", f"wg-quick@{VPN_IF}", "p5r-watchdog"]
    }

    return render_template(
        "advanced.html",
        active_tab="advanced",
        vpn_active=active,
        dns1=dns_dhcp["dns"][0],
        dns2=dns_dhcp["dns"][1],
        dhcp=dns_dhcp["dhcp"],
        hc_target=watchdog.get("HEALTHCHECK_TARGET", "1.1.1.1"),
        hc_failures=watchdog.get("HEALTHCHECK_FAILURES", "3"),
        logs=logs,
    )


if __name__ == "__main__":
    app.run(host=BIND, port=PORT, debug=False)
