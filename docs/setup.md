# Setup guide

---

## Before you start

You need:

- The hardware listed in the README
- A SIM with a data plan
- A Mac or Linux machine to transfer files from
- SSH access to the Pi over ethernet (`eth0`)

The entire setup runs over SSH. The nftables ruleset allows established
connections, so your session survives the NAT apply step and new SSH
connections stay open on `eth0` throughout.

---

## Step 0: Test the SIM first

Before the dongle touches the Pi, confirm the SIM is active. Insert it into
an unlocked phone, disable wifi, and browse over mobile data. Many prepaid
SIMs require a first-use activation step that is much easier to diagnose on
a phone than inside a Pi + dongle stack.

Once confirmed working, remove the SIM and insert it into the E3372 dongle.
The E3372h has one SIM slot; contacts face the PCB.

---

## Step 1: Flash the Pi

See [flashing.md](flashing.md) for which OS build to use and the full
Raspberry Pi Imager walkthrough. Once SSH works, come back here.

---

## Step 2: Copy the repo to the Pi

From your Mac or Linux machine:

```sh
rsync -avz --exclude .git --exclude .env ./ <user>@<pi-ip>:~/p5g/
```

On the Pi:

```sh
cd ~/p5g
chmod +x scripts/*.sh
```

---

## Step 3: Run the installer

```sh
sudo ./install.sh
```

The installer will:

1. Detect the dongle mode (HiLink network or PPP serial)
2. Prompt for WiFi credentials with auto-generated defaults (SSID, passphrase, country)
3. Confirm the WAN interface
4. Write `.env` with all settings
5. Run all setup stages in order with pass/fail output
6. Run an end-to-end healthcheck

If a stage fails it will tell you which one and suggest `sudo ./scripts/rollback.sh`.

---

## Verify end-to-end (manual)

```sh
sudo ./scripts/healthcheck_modem.sh
```

---

## Optional: web config portal

To manage WiFi settings (SSID, passphrase, channel, country) from a browser
without SSH, run:

```sh
sudo ./scripts/setup_portal.sh
```

This installs `python3-flask` and starts `p5r-portal.service`. Once running,
connect a device to the WiFi and open `http://10.77.0.1/` (or whatever
`LAN_GATEWAY` is set to). The browser will prompt for credentials set via
`PORTAL_USER` and `PORTAL_PASS` in `.env`.

Default credentials are `admin` / `p5g123`. Change them before deploying --
`install.sh` prompts for this, or edit `.env` and re-run `setup_portal.sh`.

The portal is reachable from the LAN only.

---

## Full rollback

```sh
sudo ./scripts/rollback.sh
```

Removes services, flushes nftables, removes network files, stops hostapd,
disables forwarding, and returns `wlan0` to NetworkManager. Does not
uninstall packages.

---

## Notes

**Double NAT:** the E3372 in HiLink mode runs its own NAT (modem = 192.168.8.1,
Pi gets 192.168.8.x). Adding the Pi's NAT creates double NAT. For most use
cases this is fine. Latency-sensitive applications may need Path B (PPP) to
get a public IP directly on `ppp0`.

**ModemManager:** if installed, `setup_prereqs.sh` warns you. It probes
serial ports and fights with manual PPP. Remove it on Path B:
`sudo apt-get remove modemmanager`

**Boot stalls:** `NetworkManager-wait-online.service` and
`systemd-networkd-wait-online.service` are masked during AP bring-up so the
Pi does not stall 90 seconds waiting for an interface that may not be plugged
in. This is intentional.
