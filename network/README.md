# Network

Reference for the physical and logical network — topology, addressing, and the reasoning an
`/export` cannot capture. The `*.export.rsc` files are sanitised config snapshots from the
live devices, refreshed by `./refresh-exports.sh`.

Hypervisors, VMs and the Kubernetes cluster are in [`../SERVERS.md`](../SERVERS.md).

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
| 1 | mgmt | 192.168.0.0/24 | 192.168.0.1 | .50–.150 | 192.168.0.1 | Device management |
| 10 | lab | 10.0.10.0/24 | 10.0.10.1 | .50–.200 | 192.168.0.1 | Workstations, hypervisors, Pis |
| 20 | iot | 10.0.20.0/24 | 10.0.20.1 | .50–.254 | 10.0.20.1 | Printers, robot, cameras |
| 30 | guest | 10.0.30.0/24 | 10.0.30.1 | .50–.200 | 1.1.1.1, 8.8.8.8 | Guest Wi-Fi — public DNS by design |
| 40 | vms | 10.0.40.0/24 | 10.0.40.1 | .50–.200 | 10.0.40.1 | VMs, k3s nodes, NAS |
| 848 | isp | — | — | — | — | PPPoE transport to O2 |

Search domain handed out on vlan10 and the mgmt /24 is `lan.jehli.net`.

### Isolation

**iot (20) and guest (30) cannot initiate connections into any other VLAN.** They reach the
internet normally, and mgmt, lab and vms reach *into* them freely — the defconf
"accept established,related" rule sits ahead of the drops, so replies flow.

One exception, and it matters: **IoT is allowed to 10.0.40.0/24 tcp/1883**. Five IoT devices
hold long-lived MQTT sessions to mosquitto in k3s; without that rule Home Assistant silently
loses every sensor. Verified with rule counters — the MQTT accept matched, the drop caught
everything else.

The drops log as `iot-drop` and `guest-drop`. A connection-table snapshot cannot reveal
periodic traffic (nightly firmware checks, scheduled jobs), so watch
`/log print where message~"drop"` for a week and add exceptions before assuming it is clean.
Turn the logging off afterwards if it is noisy.

mgmt (1), lab (10) and vms (40) are **not** isolated from each other. ICMP between VLANs is
never accepted, which makes `ping` a misleading reachability test — use TCP.

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

`type=FWD` static entries take **one** `forward-to` address — a comma-separated list parses
but then SERVFAILs every query. Only the first matching entry is ever used, so a second entry
buys nothing; there is no failover. If `kube-captain` is down, `lan.jehli.net` stops resolving
and `nas.local` (mDNS, cluster-independent) is the fallback.

mDNS is repeated by the router across vlan10, vlan20 and vlan40, which is what makes
`nas.local` resolve across VLANs. That path does not depend on the cluster, unlike
`lan.jehli.net`.

## Notes

- **CGNAT.** The PPPoE WAN address is RFC1918, so inbound port forwarding cannot work. This
  is why ingress is Cloudflare Tunnel (outbound-only). The leftover `dstnat` rules were
  deleted 2026-09-02.
- **The `WAN` interface list contains `ether1`, not `pppoe-o2`.** Internet traffic arrives on
  the PPPoE interface, so anything keyed on `in-interface-list=WAN` never matches — defconf's
  "drop all from WAN not DSTNATed" has fired 0 packets. Adding `pppoe-o2` to the list would
  activate it, but that changes forward-chain behaviour and is untested here.
- **Management is a /24** on all three devices. It was a /16 until 2026-09-02; the five
  192.168.x.x ARP entries outside the /24 turned out to be incomplete entries with no MAC and
  no ping reply, not real hosts.
- **The input chain is locked down** as of 2026-09-02. SSH, Winbox and WebFig accept only
  `192.168.0.0/24` and `10.0.10.0/24`, enforced both by firewall rule and by
  `/ip service address=`. Everything not explicitly allowed is dropped and logged as
  `inputdrop`. This also closed the router's DNS resolver on the PPPoE interface, which was
  previously reachable from anything that could route to the WAN address.

### Input chain

What the router itself accepts, and why — each entry was observed on a temporary logging rule
before the drop went in, not guessed:

| Allowed | From | Breaks if removed |
|---|---|---|
| udp 67,68 | any VLAN | DHCP leases everywhere |
| udp/tcp 53 | `internal` | lab, iot, vms and mgmt name resolution |
| udp 5353 | any | mDNS repeater — `nas.local` across VLANs |
| igmp | any | multicast membership that mDNS depends on |
| udp 5678 | `internal` | `/ip neighbor` discovery of the switch and AP |
| tcp 2200, 8291, 80, 443 | `mgmt-allowed` | your own management access |
| established, related, ICMP | any | defconf, already present |

Deliberately dropped: udp/17500 (Dropbox LAN sync), udp/1900 (SSDP), udp/6667. These are
broadcasts that land on input without being addressed to the router.

Changing this chain risks locking yourself out. Add a rollback first — a scheduler that
removes the drop rule after a few minutes — verify access, then delete the scheduler:

```
/system scheduler add name=fwrollback interval=4m on-event="/ip firewall filter remove [find log-prefix=inputdrop]; /system scheduler remove [find name=fwrollback]"
```

## Config snapshots

`*.export.rsc` are sanitised `/export` output from each device, refreshed by
`./refresh-exports.sh`. They replaced hand-written idempotent scripts, which were 2.6x
longer, reproduced only part of the config (7 of 23 filter rules, 0 of 5 NAT rules — so
importing one gave a router with no internet), and could silently drift. An export cannot
drift: it *is* the device.

Run the script after changing any MikroTik, then commit the diff. It refuses to write if a
secret appears.

**This repo is public.** Plain `/export` already hides passphrases, PPPoE passwords and API
tokens — verified: `/export show-sensitive` reveals 3 Wi-Fi passphrase lines, plain `/export`
reveals none. It does *not* hide the serial number or PPPoE username, so the script strips
those. Never add `show-sensitive`.

Snapshots are a reference and a rebuild aid, not a deployment mechanism — `/import` of a full
export onto a live device is not idempotent. For a rebuild, restore a `/system backup` and use
the export to diff against. This file carries the *why*; the export carries the *what*.
