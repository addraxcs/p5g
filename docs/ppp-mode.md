# PPP/serial mode (path B)

The E3372 in stick firmware exposes `/dev/ttyUSB0..2`. The pi dials the modem
over AT commands, negotiates PPP, and gets a real routable IP from the
carrier (often CGNAT).

## Signals you are on this path

- Three `/dev/ttyUSB*` nodes appear after plug-in.
- No `usb0`/`eth1` appears.
- `lsmod` shows `option` and `usb_wwan`.

## Port conventions on E3372 stick firmware

- `/dev/ttyUSB0`: PCUI (diagnostics)
- `/dev/ttyUSB1`: modem data
- `/dev/ttyUSB2`: AT commands (what we dial against)

These are conventions, not guarantees. If `PPP_DEV=/dev/ttyUSB2` fails, try
`/dev/ttyUSB0` and `/dev/ttyUSB1`. The `detect_modem.sh` output lists what
is actually present.

## APN

APN is carrier-specific. Examples only, do not use without checking:

- UK Three: `3internet`
- UK EE: `everywhere` with user/pass `eesecure/secure`
- UK Vodafone: `internet`
- UK O2: `mobile.o2.co.uk`
- US T-Mobile: `fast.t-mobile.com`

If unsure, ask the carrier or check their APN settings page. A wrong APN
causes `AT+CGDCONT` to succeed but `ATD*99#` to return `NO CARRIER`.

## SIM PIN

If the SIM has a PIN, `AT+CPIN?` returns `+CPIN: SIM PIN` instead of
`+CPIN: READY`. Remove the PIN (easiest: stick the SIM in a phone once)
rather than adding unlock logic to the chat script.

## Verify checklist

```sh
# Interactive first run:
sudo pppd call p5r-wwan nodetach debug

# In another shell:
ip -br addr show ppp0
ip route | grep default
ping -c 3 -I ppp0 1.1.1.1
```

After stable, Ctrl-C the foreground run and let `p5r-wan.service` (installed
by `install_services.sh`) manage pppd with restart-on-failure.

## Gotchas

- **CGNAT**: most mobile IPv4 addresses are behind carrier-grade NAT. No
  inbound reachability. This is fine for a LAN gateway; do not build
  features that expect inbound.
- **ModemManager**: if it is running, it will grab the AT port before pppd
  can. Disable it.
- **Power**: the E3372 pulls up to 2W during transmit. On Pi Zero or an
  undersized supply, dialing can brown out the USB bus. Use a powered hub
  if you see random disconnects.
