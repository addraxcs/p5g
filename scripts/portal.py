#!/usr/bin/env python3
"""
Config portal for private-5g-router.
Flask app served on LAN_GATEWAY:80 to manage WiFi settings.
Runs as root so it can write hostapd.conf and restart hostapd.
"""

import os
import re
import secrets
import subprocess

from flask import Flask, flash, render_template_string, request, Response

HOSTAPD_CONF = os.environ.get("HOSTAPD_CONF", "/etc/hostapd/hostapd.conf")
PORT = int(os.environ.get("PORTAL_PORT", "80"))
BIND = os.environ.get("PORTAL_BIND", "0.0.0.0")
SECRET = os.environ.get("PORTAL_SECRET", os.urandom(24).hex())
DRY_RUN = os.environ.get("DRY_RUN", "").lower() in ("1", "true", "yes")
PORTAL_USER = os.environ.get("PORTAL_USER", "admin")
PORTAL_PASS = os.environ.get("PORTAL_PASS", "p5g123")

CHANNELS_24GHZ = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]

COUNTRIES = [
    ("AU", "Australia"), ("AT", "Austria"), ("BE", "Belgium"), ("BR", "Brazil"),
    ("CA", "Canada"), ("CN", "China"), ("DK", "Denmark"), ("FI", "Finland"),
    ("FR", "France"), ("DE", "Germany"), ("IN", "India"), ("IE", "Ireland"),
    ("IT", "Italy"), ("JP", "Japan"), ("MX", "Mexico"), ("NL", "Netherlands"),
    ("NZ", "New Zealand"), ("NO", "Norway"), ("PL", "Poland"), ("PT", "Portugal"),
    ("ZA", "South Africa"), ("ES", "Spain"), ("SE", "Sweden"), ("CH", "Switzerland"),
    ("GB", "United Kingdom"), ("US", "United States"),
]

PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Router Setup</title>
<style>
*{box-sizing:border-box}
body{font-family:system-ui,sans-serif;max-width:420px;margin:60px auto;padding:0 20px;color:#111}
h2{margin-bottom:2px}
p.sub{color:#555;margin-top:0;font-size:14px}
label{display:block;font-size:13px;font-weight:600;margin-bottom:4px;margin-top:18px}
input,select{width:100%;padding:9px 10px;font-size:15px;border:1px solid #ccc;border-radius:6px;background:#fff}
.row{display:grid;grid-template-columns:1fr 1fr;gap:12px}
button{width:100%;margin-top:24px;padding:11px;font-size:15px;background:#111;color:#fff;border:none;border-radius:6px;cursor:pointer}
button:active{background:#333}
.ok{color:#1a7f37;background:#dafbe1;padding:10px 12px;border-radius:6px;margin-bottom:16px;font-size:14px}
.err{color:#cf222e;background:#ffebe9;padding:10px 12px;border-radius:6px;margin-bottom:16px;font-size:14px}
</style>
</head>
<body>
<h2>Router Setup</h2>
<p class="sub">Changes apply immediately. Reconnect after saving.</p>
{% for msg in get_flashed_messages(category_filter=["ok"]) %}
<p class="ok">{{ msg }}</p>
{% endfor %}
{% for msg in get_flashed_messages(category_filter=["err"]) %}
<p class="err">{{ msg }}</p>
{% endfor %}
<form method="POST" action="/">
  <label>Network Name (SSID)</label>
  <input name="ssid" value="{{ ssid }}" maxlength="32" autocomplete="off" spellcheck="false" required>

  <label>Passphrase (8-63 characters)</label>
  <input name="passphrase" value="{{ passphrase }}" maxlength="63" autocomplete="off" spellcheck="false">

  <div class="row">
    <div>
      <label>Channel</label>
      <select name="channel">
        {% for ch in channels %}
        <option value="{{ ch }}" {% if ch == channel %}selected{% endif %}>{{ ch }}</option>
        {% endfor %}
      </select>
    </div>
    <div>
      <label>Country</label>
      <select name="country">
        {% for code, name in countries %}
        <option value="{{ code }}" {% if code == country %}selected{% endif %}>{{ code }} - {{ name }}</option>
        {% endfor %}
      </select>
    </div>
  </div>

  <button type="submit">Save and Apply</button>
</form>
</body>
</html>"""

app = Flask(__name__)
app.secret_key = SECRET


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
    content = re.sub(r"^ssid=.*$", f"ssid={ssid}", content, flags=re.MULTILINE)
    content = re.sub(r"^wpa_passphrase=.*$", f"wpa_passphrase={passphrase}", content, flags=re.MULTILINE)
    content = re.sub(r"^channel=.*$", f"channel={channel}", content, flags=re.MULTILINE)
    content = re.sub(r"^country_code=.*$", f"country_code={country}", content, flags=re.MULTILINE)
    with open(HOSTAPD_CONF, "w") as f:
        f.write(content)
    if not DRY_RUN:
        subprocess.run(["systemctl", "restart", "hostapd"], check=True)


@app.route("/", methods=["GET", "POST"])
def index():
    if not _check_auth():
        return _auth_required()
    cfg = read_hostapd()
    if request.method == "POST":
        ssid = request.form.get("ssid", "").strip()
        passphrase = request.form.get("passphrase", "").strip()
        channel = request.form.get("channel", "6").strip()
        country = request.form.get("country", "GB").strip()

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
            flash(f"Saved. Reconnect to \"{ssid}\".", "ok")
            cfg = read_hostapd()

    return render_template_string(
        PAGE,
        ssid=cfg["ssid"],
        passphrase=cfg["wpa_passphrase"],
        channel=int(cfg.get("channel", 6)),
        country=cfg.get("country_code", "GB"),
        channels=CHANNELS_24GHZ,
        countries=COUNTRIES,
    )


if __name__ == "__main__":
    app.run(host=BIND, port=PORT, debug=False)
