# Threat Model

This document describes the security boundary of the p5g gateway, what it protects against, and what it explicitly does not protect against.

---

## Trust Boundaries

```
[Internet / Carrier]
        |
   [WAN_IF: usb0/eth1/ppp0]  <- UNTRUSTED
        |
   [Raspberry Pi Gateway]
        |
   [LAN_IF: wlan0]            <- TRUSTED (all connected clients share this trust level)
        |
   [WiFi Clients]

   [MGMT_IF: eth0]            <- TRUSTED (operator only, never in NAT)
```

**WAN is untrusted.** Carrier infrastructure, other cellular users, and the public internet are outside the trust boundary.

**LAN is trusted.** All WiFi clients share a single trust level. There is no per-client authentication or isolation between clients on `wlan0`.

**Management interface (`eth0`) is trusted.** Used only for operator SSH access. Not in NAT; not reachable from WAN or LAN by default.

---

## What the Firewall Protects Against

### WAN-side threats

| Threat | Mitigation |
|---|---|
| Port scanning from internet | nftables drops all inbound on WAN_IF (policy drop, no rules open inbound) |
| Service discovery / exploitation | No services listen on WAN_IF |
| Carrier-side traffic injection | Established/related state machine only; unsolicited inbound dropped |
| ICMP flood / amplification | ICMP ratelimited to 20 packets/second |

Nothing is reachable from the WAN interface. There are no open ports, no exposed services, no inbound NAT rules.

### VPN kill switch

When VPN mode is enabled, the nftables forward chain allows only `LAN_IF -> VPN_IF (wg0)`. There is no `LAN_IF -> WAN_IF` rule.

| Scenario | Result |
|---|---|
| Tunnel is up | LAN traffic routed through VPN |
| Tunnel drops (wg0 disappears) | Forward rule cannot match any packet; policy drop blocks all |
| wg-quick fails to start | Same: no interface, no match, no traffic |

This is an architectural guarantee, not a software check. No application-layer watchdog can silently re-enable WAN routing.

---

## What This System Does Not Protect Against

### LAN-side threats

| Threat | Not Mitigated Because |
|---|---|
| Rogue WiFi client (knows SSID + passphrase) | All clients share the same LAN trust level |
| ARP spoofing between LAN clients | No per-client isolation (hostapd `ap_isolate` not set) |
| DHCP starvation from LAN | dnsmasq has no client allowlist by default |
| Brute force on config portal | No rate limiting on HTTP Basic Auth |
| Physical access to the Pi | Full filesystem access; no encrypted storage |
| Compromised VPN provider | Trust shifts from carrier to provider when VPN is enabled |
| DNS interception by carrier | dnsmasq forwards over plaintext UDP; carrier can see DNS unless VPN is active |

### Portal threats

The config portal runs over HTTP on the LAN. An attacker who can reach the portal (any LAN client) can attempt to brute force the HTTP Basic Auth credentials. There is no lockout by default.

Operators who want a tighter posture can restrict portal access via nftables to a specific LAN IP:

```nft
iifname "wlan0" ip saddr != 10.77.0.X tcp dport 80 drop
```

---

## Secrets

| Secret | Storage | Permissions | In git? |
|---|---|---|---|
| WIFI_PASSPHRASE | `/etc/hostapd/hostapd.conf`, `.env` | 0600 | No |
| PORTAL_PASS | `.env` | 0600 | No |
| WG_PRIVATE_KEY | `/etc/wireguard/wg0.conf`, `.env` | 0600 | No |
| APN credentials | `.env`, `/etc/ppp/peers/p5r-wwan` | 0600 | No |

`.env` is in `.gitignore` and never committed. `.env.example` contains only placeholder values.

---

## Out of Scope

- Security of the cellular carrier's network
- Security of the VPN provider's infrastructure
- Physical security of the Raspberry Pi
- Security of client devices on the LAN
- Supply chain security of the OS image or installed packages
