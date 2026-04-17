# Troubleshooting

Symptoms first. Commands to run second. Fix third.

## Modem not detected at all

**Symptom:** `lsusb` shows nothing Huawei.

- Replug in a different USB port. Pi USB2 ports are more reliable than USB3.
- `dmesg --ctime | tail -n 50` on plug-in. Look for "new USB device".
- Use a powered hub. Brownout silently kills enumeration.
- Try a different cable. Some are charge-only.

## Storage mode instead of modem mode

**Symptom:** `lsblk` shows a small disk labelled Huawei or 3G/4G; no
`/dev/ttyUSB*`, no `usb0`.

- `apt-get install usb-modeswitch usb-modeswitch-data` (done by
  `setup_prereqs.sh`).
- Unplug and replug. `usb-modeswitch` should fire via udev.
- Watch `dmesg` during replug; expect a second USB enumeration within 3s.
- If it does not switch, force it:
  ```sh
  sudo usb_modeswitch -v 12d1 -p <storage-product-id> -J
  ```
  `-J` is the Huawei-specific switch message. Replace `<storage-product-id>`
  with the value from `lsusb`.

## No `/dev/ttyUSB*` appears

- `lsmod | grep -E 'option|usb_wwan'`. If empty:
  ```sh
  sudo modprobe option
  echo '12d1 1506' | sudo tee /sys/bus/usb-serial/drivers/option1/new_id
  ```
  (Product id from `lsusb` output; `1506` is common for the stick variant.)
- If it still does not appear, the firmware may be locked to HiLink and
  you are on path A, not path B.

## No `usb0`/`eth1` appears

- `lsmod | grep cdc_`. If empty:
  ```sh
  sudo modprobe cdc_ether
  sudo modprobe cdc_ncm
  ```
- If modules load but no interface shows, the firmware is probably stick
  firmware and you are on path B, not path A.

## APN issues

**Symptom (path B):** chat script dials, gets CONNECT, PPP negotiates, link
drops within seconds. Or: `ATD*99#` returns `NO CARRIER`.

- Confirm APN spelling. Many carriers reject unknown APNs silently.
- Confirm the SIM has a data plan active and no PIN:
  ```sh
  sudo minicom -D /dev/ttyUSB2 -b 115200
  AT+CPIN?       # expect +CPIN: READY
  AT+CGDCONT?    # lists stored APNs
  AT+COPS?       # expect registered operator
  AT+CSQ         # expect signal > 10
  ```
- If `CSQ` is under 10, antenna or coverage is the problem. Move the dongle.

## NAT works but DNS does not

**Symptom:** `ping 1.1.1.1` succeeds on a LAN client, `ping example.com`
fails.

- `cat /etc/resolv.conf` on the pi.
- On path A, the modem's DHCP often gives junk DNS. Override in dnsmasq
  (already done in the template: `server=1.1.1.1`).
- If LAN clients are getting DNS from dnsmasq but dnsmasq cannot resolve:
  ```sh
  sudo journalctl -u dnsmasq -n 100
  ```
  Confirm outbound UDP/53 reaches the upstream resolver. Some carriers
  block outbound DNS to non-carrier resolvers; set `server=<carrier-dns>`.

## Clients have IP, pi has WAN, but clients have no internet (route metric tie)

**Symptom:** `ping 1.1.1.1` fails from a client even though `ping -I eth1 1.1.1.1`
succeeds on the pi. `ip route` on the pi shows two default routes at the same
metric.

- Root cause: if `eth0` (management) is plugged in and networkd assigned it a
  default route at metric 100, and `eth1` (modem) is also at 100, the kernel
  may forward client packets via `eth0`. The nftables `forward` chain only
  accepts `iifname wlan0 oifname eth1`; packets to `eth0` are dropped.
- Fix: `setup_network_mode.sh` writes `RouteMetric=50` in the networkd unit
  for `WAN_IF` so the modem always wins. Confirm: `ip route | grep default`.
  Both defaults should show the modem at metric 50, management at 100.
- Manual fix if needed: edit `/etc/systemd/network/10-wan-<WAN_IF>.network`,
  set `RouteMetric=50` in `[DHCPv4]`, then `systemctl restart systemd-networkd`.

## dnsmasq "unknown interface wlan0" / not binding

**Symptom:** `journalctl -u dnsmasq` shows "unknown interface" or "failed to
bind" on wlan0 at startup. Clients get no DHCP lease.

- Root cause: dnsmasq started before hostapd had wlan0 in AP mode. The
  interface existed but had no carrier-level setup, so dnsmasq couldn't bind.
- Fix: restart dnsmasq after confirming hostapd is active:
  ```sh
  systemctl is-active hostapd     # must say "active"
  sudo systemctl restart dnsmasq
  ```
  The template uses `bind-dynamic` (not `bind-interfaces`) so dnsmasq
  re-binds automatically across interface flaps on subsequent boots. A one-time
  restart after first setup is all that is needed.

## Downstream clients connect but no internet

- From a LAN client:
  ```sh
  ip route               # default should be pi's LAN IP
  ping <pi-lan-ip>       # must succeed
  ping 1.1.1.1           # tests NAT
  curl -v https://example.com
  ```
- On the pi:
  ```sh
  sudo nft list ruleset                # confirm forward + nat tables present
  sysctl net.ipv4.ip_forward           # must be 1
  sudo conntrack -L 2>/dev/null | head # see flows going out
  ```
- If conntrack is empty, forwarding or nftables is wrong.
- If conntrack shows flows but no replies, the modem or carrier is dropping
  them. Try a different APN or reboot the modem.

## Double NAT concerns

**Symptom:** VoIP, inbound game lobbies, SIP, port forwards fail.

- Expected. Path A is inherently double NAT (modem + pi). Path B behind CGNAT
  is also effectively double NAT. Do not expect inbound reachability.
- If you need inbound, you need a public tunnel (wireguard to a VPS, etc.).
  That is out of scope here and would be a deliberate, reviewed addition.

## Watchdog restarts too aggressively

- Edit `/etc/default/p5r`. Raise `HEALTHCHECK_FAILURES` or change
  `HEALTHCHECK_TARGET` to something the carrier does not throttle.
- `sudo systemctl restart p5r-watchdog.timer`.

## Nothing in logs

```sh
journalctl -u p5r-wan.service -n 200 --no-pager
journalctl -u p5r-watchdog.service -n 200 --no-pager
journalctl -u systemd-networkd -n 200 --no-pager
journalctl -t pppd -n 200 --no-pager
dmesg --ctime | tail -n 200
```
