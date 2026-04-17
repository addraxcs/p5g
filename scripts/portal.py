#!/usr/bin/env python3
"""
Config portal for private-5g-router.
Serves a form at the gateway IP on port 80 to change SSID and passphrase.
Runs as root so it can write hostapd.conf and restart hostapd.
"""

import http.server
import html
import os
import re
import subprocess
from urllib.parse import parse_qs, unquote_plus

HOSTAPD_CONF = "/etc/hostapd/hostapd.conf"
PORT = int(os.environ.get("PORTAL_PORT", "80"))
BIND = os.environ.get("PORTAL_BIND", "0.0.0.0")

PAGE = """<!DOCTYPE html>
<html>
<head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Router Setup</title>
<style>
*{{box-sizing:border-box}}
body{{font-family:system-ui,sans-serif;max-width:380px;margin:60px auto;padding:0 20px;color:#111}}
h2{{margin-bottom:4px}}
p.sub{{color:#555;margin-top:0;font-size:14px}}
label{{display:block;font-size:13px;font-weight:600;margin-bottom:4px;margin-top:16px}}
input{{width:100%;padding:9px 10px;font-size:15px;border:1px solid #ccc;border-radius:6px}}
button{{width:100%;margin-top:20px;padding:11px;font-size:15px;background:#111;color:#fff;border:none;border-radius:6px;cursor:pointer}}
button:active{{background:#333}}
.ok{{color:#1a7f37;background:#dafbe1;padding:10px 12px;border-radius:6px;margin-bottom:16px;font-size:14px}}
.err{{color:#cf222e;background:#ffebe9;padding:10px 12px;border-radius:6px;margin-bottom:16px;font-size:14px}}
</style>
</head>
<body>
<h2>Router Setup</h2>
<p class="sub">Changes apply immediately. Reconnect after saving.</p>
{banner}
<form method="POST" action="/">
<label>SSID</label>
<input name="ssid" value="{ssid}" maxlength="32" autocomplete="off" spellcheck="false">
<label>Passphrase (8-63 characters)</label>
<input name="passphrase" value="{passphrase}" maxlength="63" autocomplete="off" spellcheck="false">
<button type="submit">Save and Apply</button>
</form>
</body>
</html>"""


def read_hostapd():
    ssid, passphrase = "", ""
    try:
        with open(HOSTAPD_CONF) as f:
            for line in f:
                line = line.strip()
                if line.startswith("ssid="):
                    ssid = line[5:]
                elif line.startswith("wpa_passphrase="):
                    passphrase = line[15:]
    except FileNotFoundError:
        pass
    return ssid, passphrase


def write_hostapd(ssid, passphrase):
    with open(HOSTAPD_CONF) as f:
        content = f.read()
    content = re.sub(r"^ssid=.*$", f"ssid={ssid}", content, flags=re.MULTILINE)
    content = re.sub(r"^wpa_passphrase=.*$", f"wpa_passphrase={passphrase}", content, flags=re.MULTILINE)
    with open(HOSTAPD_CONF, "w") as f:
        f.write(content)
    subprocess.run(["systemctl", "restart", "hostapd"], check=True)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, code, body):
        enc = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(enc)))
        self.end_headers()
        self.wfile.write(enc)

    def _render(self, ssid, passphrase, banner=""):
        return PAGE.format(
            ssid=html.escape(ssid),
            passphrase=html.escape(passphrase),
            banner=banner,
        )

    def do_GET(self):
        ssid, passphrase = read_hostapd()
        self._send(200, self._render(ssid, passphrase))

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length).decode()
        params = parse_qs(raw)
        ssid = unquote_plus(params.get("ssid", [""])[0]).strip()
        passphrase = unquote_plus(params.get("passphrase", [""])[0]).strip()

        errors = []
        if not ssid:
            errors.append("SSID is required.")
        if len(passphrase) < 8:
            errors.append("Passphrase must be at least 8 characters.")

        if errors:
            banner = '<p class="err">' + " ".join(errors) + "</p>"
            self._send(400, self._render(ssid, passphrase, banner))
            return

        write_hostapd(ssid, passphrase)
        banner = '<p class="ok">Saved. Reconnect to <strong>' + html.escape(ssid) + "</strong>.</p>"
        self._send(200, self._render(ssid, passphrase, banner))


if __name__ == "__main__":
    server = http.server.HTTPServer((BIND, PORT), Handler)
    print(f"Portal running on {BIND}:{PORT}")
    server.serve_forever()
