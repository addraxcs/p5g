# private-5g-router

Turn a Raspberry Pi and a Huawei USB dongle into a private, self-contained 4G/5G WiFi router — with one command.

---

## What you get

- A WiFi access point backed by a 4G/5G SIM
- NAT, DHCP, and DNS — all configured automatically
- A firewall that drops all inbound connections from the carrier
- A watchdog that restarts the WAN link on failure
- A web portal to change your SSID and passphrase without SSH
- A clean `rollback.sh` that undoes everything if something goes wrong

No cloud accounts. No carrier-owned hardware. No locked equipment. No manual config file editing. Runs off a USB power bank for portable use.

---

## Quick start

**What you need:**
- Raspberry Pi 4 (2GB+) running Raspberry Pi OS Lite (Bookworm)
- Huawei E3372 USB dongle (unlocked, any SIM)
- SSH access to the Pi over ethernet

```sh
# From your machine — copy the repo to the Pi
rsync -avz --exclude .git --exclude .env ./ <user>@<pi-ip>:~/private-5g-router/

# On the Pi
ssh <user>@<pi-ip>
cd ~/private-5g-router
chmod +x scripts/*.sh
sudo ./install.sh
```

`install.sh` detects your dongle, prompts for WiFi credentials (or generates them), configures everything, and ends with a live connectivity check. Setup takes under 10 minutes on a clean Pi.

Full guide: [docs/setup.md](docs/setup.md) — Pi flashing: [docs/flashing.md](docs/flashing.md)

---

## What the installer does

`install.sh` is the single entry point. It runs these stages in order, printing pass/fail for each:

1. **Detect modem** — classifies your dongle as network mode or PPP mode automatically
2. **Install packages** — hostapd, dnsmasq, nftables, ppp, usb-modeswitch
3. **Bring up WAN** — configures the dongle interface (or pppd for PPP mode)
4. **Set up WiFi AP** — hostapd on wlan0, WPA2-PSK
5. **Configure DHCP + DNS** — dnsmasq on the LAN
6. **Apply firewall** — nftables ruleset, IPv4 forwarding, NAT
7. **Install services** — systemd units for WAN persistence + watchdog timer
8. **Health check** — verifies interface, ping, DNS, and HTTPS end-to-end

Individual scripts in `scripts/` can be run standalone for manual recovery.

---

## Who this is for

**Good fit:**
- Developers or researchers who need mobile connectivity they fully control
- People running a Pi on a remote site (field, vehicle, off-grid)
- Anyone who wants a fully auditable firewall rather than a consumer router
- People who want to understand what their router is actually doing

**Not a good fit:**
- Production infrastructure (this is a personal/lab project)
- Setups requiring a public-facing IP or open inbound ports
- Non-technical users expecting a consumer router experience

---

## Security model

The firewall posture is **deny by default on WAN**:

| Direction | Policy |
|---|---|
| WAN → Pi (inbound) | Drop |
| WAN → LAN (forwarded) | Drop (except established) |
| LAN → WAN | Allow (NAT) |
| LAN → Pi (SSH, DHCP, DNS) | Allow |

No services listen on the WAN interface. SSH is only permitted on the management interface (`eth0`). The nftables ruleset is a single auditable file at `/etc/nftables.conf`.

Opening any inbound port or creating public-facing access is out of scope for this repo. Fork it if you need that, and flag it explicitly.

---

## Architecture

```
[ SIM card ]
     |
[ Huawei E3372 USB dongle ]   <-- auto-detected as network mode or PPP mode
     |
[ Raspberry Pi ]
  ├── eth0  (MGMT)    — SSH during setup; never NATed
  ├── wlan0 (LAN AP)  — hostapd, WPA2-PSK; dnsmasq DHCP/DNS; nftables NAT
  └── usb0 / eth1 / ppp0 (WAN)  — dongle interface; firewall drops all inbound
```

**Two modem paths, auto-detected:**
- **Path A (network mode):** dongle appears as `usb0`/`eth1`, DHCP via systemd-networkd
- **Path B (PPP mode):** dongle appears as `/dev/ttyUSB*`, driven by pppd + chat script

You do not need to know which mode your dongle runs. `detect_modem.sh` figures it out.

---

## Repo structure

```
.
├── install.sh              # start here — interactive one-shot setup
├── .env.example            # all config variables with descriptions
├── scripts/
│   ├── detect_modem.sh     # classify dongle — read-only, safe to re-run
│   ├── setup_*.sh          # one script per setup stage
│   ├── portal.py           # Flask config portal (SSID, passphrase, channel)
│   ├── healthcheck_modem.sh
│   ├── gather_state.sh     # read-only network snapshot for debugging
│   ├── generate_credentials.sh
│   └── rollback.sh         # undo everything
├── configs/                # config templates rendered at install time
└── docs/                   # setup, troubleshooting, per-mode references
```

---

## Configuration

`install.sh` writes `.env` for you. You can also copy `.env.example` and fill it in manually before running.

Key variables:

| Variable | What it controls | Default |
|---|---|---|
| `WIFI_SSID` | Network name | auto-generated |
| `WIFI_PASSPHRASE` | WPA2 passphrase | auto-generated (12 digits) |
| `WIFI_COUNTRY` | Regulatory domain | prompted |
| `WIFI_CHANNEL` | 2.4GHz channel | `6` |
| `WAN_IF` | Dongle interface | auto-detected |
| `LAN_GATEWAY` | Pi's LAN IP | `10.77.0.1` |
| `APN` | Carrier APN (PPP only) | prompted |
| `PORTAL_USER` / `PORTAL_PASS` | Config portal auth | `admin` / `p5g123` — change this |

`.env` is stored at `0600`. It is gitignored and never committed.

---

## Config portal (optional)

After setup, run `sudo ./scripts/setup_portal.sh` to install a web UI at `http://10.77.0.1/`. From any device on the WiFi, you can change the SSID, passphrase, channel, and country without SSH.

Protected by HTTP Basic Auth (`PORTAL_USER` / `PORTAL_PASS` in `.env`). Only reachable from within the LAN. Change the default credentials before use.

---

## Advanced usage

| Task | Command |
|---|---|
| Check modem mode | `sudo ./scripts/detect_modem.sh` |
| Run connectivity check | `sudo ./scripts/healthcheck_modem.sh` |
| Snapshot network state | `sudo ./scripts/gather_state.sh` |
| Undo everything | `sudo ./scripts/rollback.sh` |
| Run stages manually | see [docs/setup.md](docs/setup.md) |

**Per-mode docs:**
- [docs/network-mode.md](docs/network-mode.md) — Path A (HiLink)
- [docs/ppp-mode.md](docs/ppp-mode.md) — Path B (PPP)
- [docs/troubleshooting.md](docs/troubleshooting.md) — common issues

---

## Known limitations

- **2.4GHz only.** 5GHz requires a USB wifi adapter and additional hostapd config not covered here.
- **Single WAN.** One dongle. No failover or bonding.
- **Double NAT on Path A.** The HiLink dongle already does NAT internally. Your Pi gets a `192.168.x.x` address from the dongle, not a public IP. This is fine for most use cases.
- **PPP mode gives a public IP** (carrier-assigned, dynamic). Better for applications that need a routable address.
- **No IPv6.** IPv6 forwarding is disabled. Carrier IPv6 prefixes are not routed to the LAN.
- **WPA2-PSK only.** WPA3 is not configured. Coverage for older clients is the trade-off.
- **Tested on Raspberry Pi OS Bookworm (Debian 12).** Other Debian-based distros may need adjustments.

---

## Why this exists

Consumer routers are black boxes. Carrier-provided hardware is worse. This project is about running the part of the network you own, on hardware you control, with a firewall you can read in one file.

It also exists because setting this up manually is genuinely difficult — NetworkManager, wpa_supplicant, hostapd, systemd-networkd, and pppd all have opinions about who owns which interface, and they fight. This repo works out those conflicts so you do not have to.

---

## Hardware reference

| Part | Notes |
|---|---|
| Raspberry Pi 4 (2GB+) | Pi 3B+ works; Pi 5 works; Pi Zero not suitable |
| Portable USB power bank (5V/3A) | Powers the Pi and dongle for field/portable use — any USB-C PD bank works |
| Huawei E3372 USB dongle | Get an unlocked unit — see below |
| MicroSD (16GB+, Class 10 / A1) | |
| USB-C 5V/3A power supply | Official Pi PSU recommended |

**Unlocked E3372 models:**

| Model | Firmware | Notes |
|---|---|---|
| E3372h-320 | HiLink (Path A) | Most widely available, recommended |
| E3372h-607 | HiLink (Path A) | Good availability |
| E3372s-153 | Stick/PPP (Path B) | Less common |
| E3372h-153 | Either | Check listing — some units are carrier-locked |

Avoid carrier-branded units (EE, Vodafone, Three packaging). Look for "unlocked" or "SIM-free" in the listing.

---

## License

MIT
