# Network

Reference for the physical and logical network. The `.rsc` files here are idempotent
RouterOS scripts that reproduce the documented state — see [Scripts](#scripts).

## Topology

```
                    Internet — O2 PPPoE on vlan848  (CGNAT: WAN is 10.227.x.x/32)
                                    │
                            ┌───────┴────────┐
                            │  RB750Gr3 hEX  │  router · DHCP · DNS · firewall
                            │  10.0.10.1     │  mmips — no container support
                            └───────┬────────┘
                                 ether2  trunk: 10,20,30,40 tagged + vlan1 untagged
                                    │
                                 ether8
                            ┌───────┴────────┐
                            │  CRS310        │  L3 hardware offload (vlan10 ↔ vlan40)
                            │  192.168.0.3   │  arm
                            └┬──┬──┬──┬──┬──┬┘
                    ether1 ──┘  │  │  │  │  └── ether6 → holly (PVE, + VM NICs)
                    "Stul"      │  │  │  └───── ether5 → lab access
                                │  │  └──────── ether4 → pve   (PVE, + VM NICs)
                                │  └─────────── ether3 → overwatcher (RPi 4)
                             ether2
                                │  trunk: 10,20,30 tagged
                        ┌───────┴────────┐
                        │  hAP ax S      │  Wi-Fi
                        │  192.168.0.4   │  arm
                        └────────────────┘
```

Only `ether2` is live on the router — everything else hangs off the switch.

## VLANs

| VLAN | Name | Subnet | Gateway | DHCP pool | DHCP DNS | Purpose |
|---|---|---|---|---|---|---|
| 1 | mgmt | 192.168.0.0/16 | 192.168.0.1 | .50–.150 | 192.168.0.1 | Device management |
| 10 | lab | 10.0.10.0/24 | 10.0.10.1 | .50–.200 | 192.168.0.1 | Workstations, hypervisors, Pis |
| 20 | iot | 10.0.20.0/24 | 10.0.20.1 | .50–.254 | 10.0.20.1 | Printers, robot, cameras |
| 30 | guest | 10.0.30.0/24 | 10.0.30.1 | .50–.200 | 1.1.1.1, 8.8.8.8 | Guest Wi-Fi — public DNS by design |
| 40 | vms | 10.0.40.0/24 | 10.0.40.1 | .50–.200 | 10.0.40.1 | VMs, k3s nodes, NAS |
| 848 | isp | — | — | — | — | PPPoE transport to O2 |

Search domain handed out on vlan10 and 192.168.0.0/16 is `lan.jehli.net`.

**VLANs are not isolated from each other.** The forward chain has no inter-VLAN drop, so any
host can reach any other over TCP. ICMP between VLANs is not accepted, which makes `ping`
misleading as a reachability test — use TCP.

## Devices

| Device | Model | Addresses | Arch | Role |
|---|---|---|---|---|
| router | RB750Gr3 (hEX) | 10.0.10.1, 10.0.20.1, 10.0.30.1, 10.0.40.1, 192.168.0.1 | mmips | Routing, DHCP, DNS, firewall, PPPoE |
| switch | CRS310 | 192.168.0.3, 10.0.10.2, 10.0.40.2 | arm | VLAN switching, L3 offload |
| ap | hAP ax S | 192.168.0.4 | arm | Wi-Fi, 3 SSIDs |

SSH: the **router is on port 2200**; switch and AP are on 22. All as `admin`.

`mmips` matters: the router cannot run RouterOS containers. The switch and AP can.

## Switch ports (CRS310)

| Port | VLANs | Connects to |
|---|---|---|
| ether1 | untagged 10 | "Stul" desk drop (10.0.10.51) |
| ether2 | tagged 10,20,30 | hAP ax S (its ether1) |
| ether3 | untagged 10 | overwatcher, RPi 4 (10.0.10.128) |
| ether4 | tagged 10,20,40 | pve hypervisor (10.0.10.4) |
| ether5 | untagged 10 | lab access |
| ether6 | tagged 10,20,40 | holly hypervisor (10.0.10.5) |
| ether7 | untagged 20, tagged 10,30,40 | *(down)* |
| ether8 | tagged 10,20,30,40 | **router** (its ether2) |
| sfp-sfpplus1/2 | vlan1 | *(down)* |

The switch holds L3 addresses on vlan10 and vlan40 with `l3-hw-offloading=yes`, so traffic
between those two VLANs is routed in switch hardware and never reaches the router.

## Wi-Fi

| SSID | VLAN | Security | Bands |
|---|---|---|---|
| `Jehli-Fi` | 10 | WPA2 + WPA3, 802.11r fast transition | 2.4 GHz ax + 5 GHz ax |
| `jehlifi_iot` | 20 | WPA2 only (legacy device compatibility) | 2.4 GHz |
| `Jehli-Fi Guest` | 30 | WPA2 + WPA3 | 2.4 + 5 GHz |

vlan40 is deliberately absent from the AP — VMs are wired only.

## DNS

```
client ──▶ router (10.0.10.1 / 192.168.0.1)
              ├── lan.jehli.net ──▶ CoreDNS in k3s (10.0.40.102)  → LAN infra names
              └── everything else ──▶ 8.8.8.8, 1.1.1.1
```

CoreDNS is deployed by `manifests/helm-controller-charts/coredns-lan.yaml` and serves only
`lan.jehli.net`; it REFUSES anything else, so it can never act as an open resolver. Full
detail in [`../MIGRATION.md`](../MIGRATION.md).

`type=FWD` static entries take **one** `forward-to` address. A comma-separated list parses
but then SERVFAILs every query. Only the first matching entry is ever used, so a second entry
is a manual fallback, not failover.

mDNS is repeated by the router across vlan10, vlan20 and vlan40, which is what makes
`nas.local` resolve across VLANs. That path does not depend on the cluster, unlike
`lan.jehli.net`.

## Notes

- **CGNAT.** The PPPoE WAN address is RFC1918, so inbound port forwarding cannot work. This
  is why ingress is Cloudflare Tunnel (outbound-only). Four `dstnat` rules for 80/443/6881 →
  10.0.40.102 are left over from before and can never fire.
- **`192.168.0.0/16` is a /16.** Only `.50–.150` is used. Treat it as a /24 for anything that
  advertises routes (VPN, Tailscale) — advertising the /16 would swallow every foreign
  192.168.x.x network you connect from.
- **Management is flat.** The input chain has no drop rule, so every VLAN — including guest —
  can reach the router's services. Restrict with `/ip service address=` if that matters.

## Scripts

`router-rb750gr3.rsc`, `switch-crs310.rsc`, `ap-hap-ax-s.rsc` reproduce the structural config
above: bridges, VLANs, addressing, DHCP, DNS, Wi-Fi. They are **idempotent** — every change is
find-then-add-or-update, so re-running converges rather than duplicating.

They deliberately do **not** cover: defconf firewall rules, PPPoE credentials, Wi-Fi
passphrases, or per-host DHCP leases. Those are either secret or site-specific; passphrases
appear as `CHANGEME` placeholders.

Intended for rebuild and disaster recovery, and as an executable description of intent. To
apply, upload and run:

```sh
scp -P 2200 network/router-rb750gr3.rsc admin@10.0.10.1:
ssh -p 2200 admin@10.0.10.1 '/import file-name=router-rb750gr3.rsc'
```

Review the diff against a live `/export` before running against a working device.
