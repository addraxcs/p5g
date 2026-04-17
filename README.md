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
├── install.sh              # one-shot interactive installer (start here)
├── .env.example            # all config variables
├── configs/                # config templates rendered on the Pi
├── scripts/                # individual setup scripts (called by install.sh)
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

## Security posture

- Inbound WAN: **drop**
- Established connections: **allow**
- LAN to WAN: **allow** (NAT)
- No services listening on WAN

Adding any inbound port, NAT rule, or public-facing tunnel is out of scope for this repo. If you need that, fork and flag it explicitly.

---

## License

MIT
# p5g
# p5g
