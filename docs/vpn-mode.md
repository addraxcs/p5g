# VPN Mode (WireGuard)

Router-level VPN routes all LAN traffic through a WireGuard tunnel on the Pi itself. Every device on the WiFi is tunnelled automatically — no per-device VPN configuration required.

This is an optional, advanced feature. It is not part of the default install.

---

## How traffic flows

**Without VPN (default):**
```
LAN client → wlan0 → [Pi NAT] → WAN_IF (usb0/eth1/ppp0) → carrier → internet
```

**With VPN active:**
```
LAN client → wlan0 → [Pi NAT] → wg0 → WireGuard tunnel → VPN server → internet
                                   ↑
                       WireGuard UDP still goes via WAN_IF to reach the server,
                       but it's encrypted — carrier sees only the tunnel, not content
```

---

## What changes

| Behaviour | Without VPN | With VPN |
|---|---|---|
| LAN → internet | Via WAN_IF directly | Via wg0 (tunnel) |
| NAT masquerade | On WAN_IF | On wg0 |
| Forward to WAN_IF | Allowed | **Blocked** (kill switch) |
| Traffic visible to carrier | All destinations | Volume + timing only; content encrypted |
| Trust anchor | Carrier | VPN provider |

---

## Kill switch

The kill switch is not optional. When VPN mode is active, `nftables-vpn.conf.template` replaces the standard firewall with one that:

- allows forwarding **only** from `LAN_IF` to `VPN_IF` (wg0)
- **never** allows forwarding from `LAN_IF` to `WAN_IF`
- uses `policy drop` on the forward chain

If `wg0` goes down, the interface disappears. The forward rule that references it stops matching. The policy drop catches everything. There is no fallback path to `WAN_IF`. All client traffic stops until the tunnel recovers.

This is intentional. Silent fallback to an unencrypted path is worse than a connectivity loss.

---

## Trust model

Running a VPN at the router level shifts trust — it does not eliminate it.

| What improves | What does not change |
|---|---|
| Carrier cannot see traffic destinations or content | Carrier still sees your SIM identity |
| Carrier cannot see DNS queries | Carrier still sees connection timing and data volume |
| All LAN clients are covered without per-device config | VPN provider now sees all traffic from all clients |
| DNS queries exit through the tunnel | VPN provider's logging policy applies to your traffic |

Your carrier becomes a dumb pipe. Your VPN provider becomes the entity you are trusting instead. Choose one with a clear, audited no-logs policy.

---

## DNS

LAN clients send DNS queries to dnsmasq on the Pi. Dnsmasq forwards upstream to the configured resolvers (default: 1.1.1.1, 9.9.9.9). Because the routing table sends all non-WireGuard traffic through `wg0`, dnsmasq's upstream queries also exit through the tunnel.

DNS from LAN clients does not leak through `WAN_IF` in VPN mode.

The `WG_DNS` variable in `.env` sets the Pi's own system resolver (via wg-quick). It does not change what dnsmasq forwards to — those upstream servers are set in `configs/dnsmasq.conf.template`.

---

## Setup

### Prerequisites

- Base install complete (`sudo ./install.sh` run and healthy)
- VPN provider credentials (WireGuard private key, peer public key, endpoint)
- Variables populated in `.env` (see `.env.example` VPN section)

### Run

```sh
sudo ./scripts/setup_vpn.sh
```

The script:
1. Installs `wireguard-tools`
2. Renders `/etc/wireguard/wg0.conf` from your `.env` values
3. Starts and enables `wg-quick@wg0`
4. Replaces `/etc/nftables.conf` with the VPN-mode kill switch ruleset
5. Verifies the tunnel is up with a ping check

### Verify

```sh
wg show                          # tunnel status and latest handshake
ip route                         # confirm wg0 appears in routing table
ping -I wg0 1.1.1.1             # reachability through tunnel
nft list ruleset                 # confirm VPN-mode rules are active
```

---

## Rollback

```sh
sudo ./scripts/rollback.sh
```

Rollback removes the WireGuard config, stops `wg-quick@wg0`, and tears down the VPN-mode firewall rules along with everything else the installer placed. Re-run `sudo ./install.sh` or the individual stage scripts to restore normal operation.

---

## Trade-offs

| Trade-off | Detail |
|---|---|
| Uptime dependency | VPN provider outage = no internet for all LAN clients |
| Centralised trust | All traffic from all devices goes to one VPN exit point |
| Throughput | WireGuard is efficient but adds encryption overhead; expect some reduction on the Pi's CPU |
| Complexity | More moving parts — one more service to monitor and debug |
| Kill switch is binary | If the tunnel drops, everyone loses connectivity. There is no degraded mode. |

If uptime matters more than traffic privacy for a particular deployment, do not enable VPN mode. The base install provides a clean NAT router without these trade-offs.
