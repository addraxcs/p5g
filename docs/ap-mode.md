# AP mode (pi as wifi router)

The built-in wireless radio on the pi serves as an access point. Downstream
clients connect over wifi, get DHCP from the pi, and route out through the
E3372 dongle.

## Topology

```
[ E3372 USB ]--usb0/ppp0--[ Pi ]--wlan0--((wifi))--[ clients ]
                  WAN                     LAN
```

- `WAN_IF` = `usb0` / `eth1` / `ppp0` (from modem detection)
- `LAN_IF` = `wlan0` (the pi's built-in radio)
- `eth0` is left for out-of-band management (e.g. plugged into your existing
  LAN for SSH). It is neither LAN nor WAN in the NAT config. See
  "Management access" below.

## Components

1. **hostapd**: owns `wlan0`, broadcasts SSID, does WPA2 auth.
2. **systemd-networkd**: gives `wlan0` its static `LAN_GATEWAY` address.
3. **dnsmasq**: DHCP + DNS for clients on `wlan0`. Required in AP mode,
   optional in wired-LAN mode.
4. **nftables**: LAN -> WAN NAT. Drops inbound on WAN.
5. **NetworkManager**: stays installed, but is told to unmanage `wlan0` so
   hostapd can claim it.

## Env values

In `.env` on the pi:

```
LAN_IF=wlan0
LAN_GATEWAY=10.77.0.1
LAN_SUBNET=10.77.0.0/24
LAN_SUBNET_MASK=255.255.255.0
DHCP_RANGE_START=10.77.0.50
DHCP_RANGE_END=10.77.0.200
DHCP_LEASE=12h

WIFI_SSID=my-wifi
WIFI_PASSPHRASE=<8..63 chars, change this>
WIFI_COUNTRY=<GB|US|DE|...>
WIFI_CHANNEL=6
```

Pick `LAN_SUBNET` that does not overlap any upstream network. If `eth0` is
plugged into a `192.168.x.0/24` LAN for management, do not use
`192.168.x.0/24` for the LAN subnet.

## Bring-up sequence (on the pi, as root)

```sh
sudo ./scripts/setup_prereqs.sh       # installs hostapd, iw, wireless-regdb
sudo ./scripts/setup_network_mode.sh  # or setup_ppp_mode.sh for path B
sudo ./scripts/setup_ap_mode.sh       # hostapd + wlan0 static IP

# DHCP for clients
sudo install -m 0644 configs/dnsmasq.conf.template /etc/dnsmasq.d/p5r.conf
sudo sed -i "s|__LAN_IF__|$LAN_IF|g; s|__LAN_GATEWAY__|$LAN_GATEWAY|g; \
  s|__LAN_SUBNET_MASK__|$LAN_SUBNET_MASK|g; \
  s|__DHCP_RANGE_START__|$DHCP_RANGE_START|g; \
  s|__DHCP_RANGE_END__|$DHCP_RANGE_END|g; \
  s|__DHCP_LEASE__|$DHCP_LEASE|g" /etc/dnsmasq.d/p5r.conf
sudo systemctl enable --now dnsmasq

sudo ./scripts/setup_nat.sh           # forwarding + nftables
sudo ./scripts/install_services.sh    # watchdog + boot-time WAN
```

## Verify checklist

```sh
# hostapd up
systemctl is-active hostapd
iw dev wlan0 info | grep type        # expect: type AP

# wlan0 has the gateway IP
ip -br addr show wlan0               # expect: 10.77.0.1/24 UP

# clients getting leases
journalctl -u dnsmasq -n 30 --no-pager | grep DHCPACK

# from a phone on the SSID
ping 10.77.0.1                       # pi's LAN side
ping 1.1.1.1                         # via NAT
curl -v https://example.com          # DNS + NAT + WAN
```

## Management access during and after setup

The default and recommended method is **SSH over eth0**. Set `MGMT_IF=eth0`
in `.env` (the default). The rendered nftables ruleset adds
`iifname "eth0" tcp dport 22 ct state new accept` in the input chain, so
new SSH connections on `eth0` remain open even after NAT is applied.
Existing sessions survive regardless because established connections are
always allowed.

Do not SSH in from a wifi client on the LAN SSID and expect to reconfigure
the AP from that session. Dropping hostapd will kick you off. Always use the
wired eth0 connection for AP work.

If issues persist after editing scripts on your workstation, re-sync and
re-run over SSH:

```sh
# macOS or Linux
rsync -avz --exclude .git --exclude .env ./ <user>@<pi-ip>:~/private-5g-router/

# then on the pi
cd ~/private-5g-router
sudo ./scripts/setup_ap_mode.sh
```

## Troubleshooting

**SSID does not appear after cold boot (wpa_supplicant race, Trixie)**
- Symptom: hostapd is `active`, but `iw dev wlan0 info | grep type` shows
  `type managed` instead of `type AP`. SSID is absent on phones.
- Root cause: `wpa_supplicant.service` is enabled by default on Pi OS
  Trixie. On boot it registers a supplicant interface with NetworkManager,
  which promotes wlan0's managed-type from `external` (our keyfile unmanage)
  to `full`. That overrides the unmanage conf.d drop-in and races hostapd
  for the radio.
- Fix: `setup_ap_mode.sh` masks `wpa_supplicant.service`. If you are
  debugging a pi that ran an older copy of the script, mask it manually:
  ```sh
  sudo systemctl disable --now wpa_supplicant.service
  sudo systemctl mask wpa_supplicant.service
  sudo systemctl restart NetworkManager
  sudo systemctl restart hostapd
  ```
  NM has its own internal supplicant for managed-wifi clients; the
  standalone one is not needed and actively harmful here.

**NM keeps re-activating wlan0 despite unmanage keyfile (netplan profile)**
- Symptom: `nmcli device status` shows wlan0 as `connected` with an SSID
  like `netplan-wlan0-CropGuard` even after NM restart.
- Root cause: Pi OS Trixie uses netplan by default. If wlan0 had a saved
  connection (from a previous wifi join), netplan regenerates an NM
  connection profile on every boot. NM activates it before reading the
  conf.d unmanage drop-in.
- Fix: `setup_ap_mode.sh` disconnects and deletes all wifi profiles on
  LAN_IF before restarting NM. To do it manually:
  ```sh
  sudo nmcli device disconnect wlan0
  sudo nmcli connection delete netplan-wlan0-<SSID>   # repeat for all wifi profiles
  sudo nmcli device set wlan0 managed no
  sudo systemctl restart NetworkManager
  sudo systemctl restart hostapd
  ```

**hostapd fails to start with "nl80211: Could not configure driver mode"**
- NetworkManager is still holding `wlan0`. Confirm
  `/etc/NetworkManager/conf.d/99-p5r-unmanage-lan.conf` exists, restart NM,
  then restart hostapd.
- `sudo rfkill list` then `sudo rfkill unblock wifi`.
- `iw dev` must show `wlan0`. If not, the radio is down or the driver did
  not load.

**hostapd starts, clients see SSID, but cannot associate**
- Check `WIFI_PASSPHRASE` length (8..63).
- `journalctl -u hostapd -f` while a client tries to join. Look for
  `WPA: rejecting`.

**Clients associate but have no IP**
- `journalctl -u dnsmasq -n 50`. Confirm dnsmasq is bound to `wlan0`.
- Confirm `wlan0` has the gateway IP: `ip addr show wlan0`.

**Clients have IP but no internet**
- `sudo nft list ruleset`. Check the `forward` chain allows
  `iifname wlan0 oifname <WAN_IF> accept`.
- `sysctl net.ipv4.ip_forward` must be 1.
- From the pi: `ping -I <WAN_IF> 1.1.1.1`. If that fails, WAN is the
  problem, not the AP.

**Channel complaints / regulatory errors**
- `WIFI_COUNTRY` must be set to a valid ISO code for your actual location.
  Setting `US` while in the EU can block channels 12/13; setting `GB` in
  the US may pick a channel the radio cannot use at the configured power.
- Verify: `iw reg get`.

**Low range / poor throughput**
- Try channels 1, 6, 11 in turn. `sudo iw dev wlan0 scan | grep -E 'freq|signal|SSID'`
  shows what neighbors are using.
- The pi's built-in antenna is modest. For longer ranges, a USB wifi adapter
  with an external antenna may be needed; hostapd supports it but this
  template targets the built-in radio.
