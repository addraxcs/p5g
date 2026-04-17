# Topology notes

Three common ways to wire this pi up.

## 1. Pi as the only router

```
[ E3372 ]--usb--[ Pi ]--eth0--[ switch / clients ]
```

- LAN_IF = eth0
- WAN_IF = usb0 | eth1 | ppp0
- Pi runs dnsmasq for DHCP + DNS (stage 5 of deploy plan).
- Single NAT path A, but path A is internally double-NAT because the E3372
  HiLink firmware NATs too.

## 2. Pi feeding an existing router's WAN port

```
[ E3372 ]--usb--[ Pi ]--eth0--[ Router WAN ]--[ LAN + wifi clients ]
```

- LAN_IF = eth0 (feeds router WAN)
- WAN_IF = usb0 | eth1 | ppp0
- dnsmasq NOT needed on the pi. The downstream router runs DHCP.
- Pi's LAN subnet must not overlap the router's LAN subnet. Pick
  `10.77.0.0/24` or similar and set a static address on `eth0` on the pi
  plus the router's WAN.
- Double NAT: pi NATs once, downstream router NATs again. If on path A,
  that's triple NAT counting the modem's internal NAT. Outbound still works
  but inbound is hopeless. Acceptable for client use.

## 3. Pi with wifi AP (default for this project)

```
[ E3372 ]--usb--[ Pi ]--wlan0--((wifi))--[ clients ]
                  |
                  +--eth0--[ mgmt LAN, optional ]
```

- WAN_IF = usb0 | eth1 | ppp0
- LAN_IF = wlan0 (hostapd serves SSID)
- eth0 is the management interface (`MGMT_IF=eth0`). It is not part of NAT
  or forwarding. The nftables ruleset keeps port 22 open on eth0 throughout,
  including after NAT is applied. SSH in via eth0 for all setup work.
- See `docs/ap-mode.md` for the full bring-up, hostapd gotchas, and
  regulatory settings.

## Addressing cheatsheet

| Interface | Typical address                           |
| --------- | ----------------------------------------- |
| usb0      | 192.168.8.100/24 (from modem DHCP)        |
| eth1      | 192.168.8.100/24                          |
| ppp0      | carrier-assigned, CGNAT likely            |
| eth0      | 10.77.0.1/24 (pi's LAN, from .env)        |

If the upstream router uses `192.168.1.0/24` and you happen to pick
`192.168.1.0/24` for LAN, routing will break in subtle ways. Always use a
subnet not in use anywhere else in the chain.
