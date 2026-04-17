# Network-interface mode (path A)

The Huawei E3372 in HiLink firmware presents as a CDC-ECM or NCM network
adapter. From the pi's view, it looks like a regular ethernet dongle with
an embedded DHCP server (typically `192.168.8.1/24`).

## Signals you are on this path

- `ip -br link` shows `usb0` or `eth1` after plug-in.
- No `/dev/ttyUSB*` nodes appear.
- `lsusb` vendor is Huawei; product id varies.

## How bring-up works

1. systemd-networkd sees the interface thanks to
   `/etc/systemd/network/10-wan-<WAN_IF>.network`.
2. It DHCP-leases an address (typically `192.168.8.100/24`) and installs a
   default route with metric 100.
3. DNS comes from the modem's DHCP offer.

You do not need PPP, chat scripts, APN, or usb_modeswitch on this path. The
modem holds APN and auth internally. If the APN is wrong on the carrier side
you will see the lease succeed but data fail, because the E3372 hands out an
address even without WAN connectivity. Confirm with a ping of the
`HEALTHCHECK_TARGET`.

## Gotchas

- **Double NAT**: the modem NATs internally, and the pi NATs again. This is
  expected and mostly fine for outbound traffic. No inbound ports reach
  clients behind the pi unless you set up DMZ on the modem web UI, which is
  out of scope. See `topology-notes.md`.
- **Modem web UI reachable from LAN**: the modem at `192.168.8.1` is routable
  from the pi but not from downstream LAN clients by default. If you want to
  reach it, port-forward or add a static route on a trusted host only. Do not
  expose it.
- **MTU**: CDC-NCM usually negotiates 1500. If you see stalled downloads,
  drop MTU on `usb0` to 1428 and retest.

## Verify checklist

```sh
ip -br addr show "$WAN_IF"
ip route | grep default
ping -c 3 -I "$WAN_IF" 1.1.1.1
getent hosts example.com
```
