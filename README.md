# p5g - Private 5g Portable Router

A Raspberry Pi that turns a 4G/5G USB dongle into a private, self-contained wifi router.

No cloud accounts. No ISP-owned hardware. No carrier-locked equipment.

---

## What this is

The Pi takes a 4G/5G uplink from a Huawei USB dongle and shares it as a wifi access point. Downstream clients connect to the Pi's SSID. All traffic is NATed through the dongle. The firewall drops all inbound connections from the WAN side.

```
[ 4G/5G SIM ] --> [ Huawei dongle (USB) ] --> [ Raspberry Pi 4 ] --(wifi)--> [ your devices ]
     WAN                                    hostapd + NAT + DHCP               LAN
```

The dongle is the only thing that touches the carrier. Downstream devices connect over wifi and share the uplink. A VPN-configured device on the LAN encrypts all its traffic before it leaves the Pi - the carrier sees a tunnel, not destinations.

---

## Hardware

| Part | Notes |
|---|---|
| Raspberry Pi 4 (2GB+) | Pi 3B+ works but 4 is preferred |
| Huawei E3372 USB dongle | See unlocked models below |
| MicroSD card (16GB+) | Class 10 or A1 rated |
| USB-C 5V/3A power supply | Official Pi PSU recommended |
| Portable rechargeable PSU | Coming soon |

### Unlocked Huawei dongle models

The E3372 comes in two firmware variants - HiLink (network mode) and stick (PPP mode). Both are supported. Buy an unlocked unit that works with any SIM:

- **E3372h-320** - global unlocked, most widely available, HiLink firmware
- **E3372h-607** - unlocked, HiLink firmware, good availability
- **E3372s-153** - unlocked, stick/PPP firmware, less common
- **E3372h-153** - check listing carefully, some units are unlocked, some carrier-locked

Avoid carrier-branded units (EE, Vodafone, Three branded packaging). Buy from a seller that explicitly states "unlocked" or "SIM-free".

The installer auto-detects which firmware variant your dongle runs and takes the right path. You do not need to know in advance.

---

## Software stack

- **OS:** Raspberry Pi OS Bookworm (32 or 64-bit lite)
- **Firewall:** nftables (single-file ruleset, easy to audit)
- **Networking:** systemd-networkd for interface addressing
- **AP:** hostapd (WPA2-PSK)
- **DHCP/DNS:** dnsmasq
- **WAN persistence:** custom systemd service + watchdog timer
- **Config portal:** Flask app at `http://LAN_GATEWAY/` to change SSID, passphrase, channel, and country without SSH

No ModemManager. No NetworkManager managing the radio. No DHCP clients fighting each other.

---

## Setup

Full guide: [docs/setup.md](docs/setup.md)

1. Configure / Test SIM in a phone first
2. Flash Pi OS - see [docs/flashing.md](docs/flashing.md)
3. Copy this repo to the Pi over SSH
4. Run `sudo ./install.sh` - detects dongle, prompts for credentials, configures everything

---

## Repository layout

```
.
├── install.sh                      # one-shot interactive installer (start here)
├── .env.example                    # all config variables
├── configs/                        # config templates rendered on the Pi
├── scripts/
│   ├── _lib.sh                     # shared shell functions (load_env, render_template, ...)
│   ├── detect_modem.sh             # classify E3372 dongle mode
│   ├── setup_prereqs.sh            # apt install baseline packages
│   ├── setup_network_mode.sh       # Path A (HiLink) WAN bring-up
│   ├── setup_ppp_mode.sh           # Path B (PPP) WAN bring-up
│   ├── setup_ap_mode.sh            # hostapd on wlan0
│   ├── setup_dhcp.sh               # dnsmasq DHCP + DNS
│   ├── setup_nat.sh                # sysctl + nftables
│   ├── install_services.sh         # p5r-wan.service + watchdog timer
│   ├── setup_portal.sh             # install Flask config portal service
│   ├── portal.py                   # Flask config portal (SSID, passphrase, channel, country)
│   ├── gather_state.sh             # read-only network snapshot
│   ├── healthcheck_modem.sh        # E2E connectivity check
│   ├── generate_credentials.sh     # generate random WiFi credentials
│   └── rollback.sh                 # undo all changes
└── docs/
    ├── setup.md            # setup guide
    ├── flashing.md         # flash Pi OS with Raspberry Pi Imager
    ├── ap-mode.md          # AP mode details and troubleshooting
    ├── troubleshooting.md  # modem and WAN troubleshooting
    ├── network-mode.md     # Path A (HiLink) reference
    ├── ppp-mode.md         # Path B (PPP) reference
    └── topology-notes.md   # network topology options
```

---

## Config portal

After setup, a web portal is available at `http://<LAN_GATEWAY>/` (default: `http://10.77.0.1/`) from any device on the WiFi network. It lets you change the SSID, passphrase, channel, and country code without SSH. Changes restart hostapd immediately.

To install:

```sh
sudo ./scripts/setup_portal.sh
```

This installs `python3-flask`, copies the portal to `/usr/local/bin/p5r-portal`, and starts `p5r-portal.service` bound to the LAN gateway IP on port 80.

The portal is protected by HTTP Basic Auth. Credentials are set via `PORTAL_USER` and `PORTAL_PASS` in `.env` (defaults: `admin` / `p5g123` -- change before deploying). It is only reachable from within the LAN. Do not expose port 80 on the WAN interface.

---

## Security posture

- Inbound WAN: **drop**
- Established connections: **allow**
- LAN to WAN: **allow** (NAT)
- No services listening on WAN

Adding any inbound port, NAT rule, or public-facing tunnel is out of scope for this repo. If you need that, fork and flag it explicitly.

---

## License

MIT
