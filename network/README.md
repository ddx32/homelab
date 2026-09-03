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
| 40 | vms | 10.0.40.0/24 | 10.0.40.1 | .50–.99 | 10.0.40.1 | VMs, k3s nodes, NAS |
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
              ├── *.lan.jehli.net ──▶ answered locally from /ip dns static
              └── everything else ──▶ 8.8.8.8, 1.1.1.1
```

**LAN name resolution does not depend on the cluster** (since 2026-09-03). Six `/ip dns static`
A records on the router replaced a two-replica CoreDNS behind a LoadBalancer in k3s:

| Name | Address |
|---|---|
| `nas.lan.jehli.net` | 10.0.40.201 |
| `kube-captain.lan.jehli.net` | 10.0.40.102 |
| `kube-worker.lan.jehli.net` | 10.0.40.104 |
| `pve.lan.jehli.net` | 10.0.10.4 |
| `holly.lan.jehli.net` | 10.0.10.5 |
| `printer-buddy.lan.jehli.net` | 10.0.20.230 |

Why the router and not the cluster: these are six fixed appliances, and the old path made
`lan.jehli.net` die with `kube-captain`. `type=FWD` static entries take **one** `forward-to`
address — a comma-separated list parses but then SERVFAILs every query, and a second entry is
never consulted, so there was no failover to build. The router is always up and was already on
every resolution path anyway. Rationale and the checked preconditions are in
[`../MIGRATION.md`](../MIGRATION.md).

Every host resolves via the router (`192.168.0.1`), and pods go through cluster CoreDNS
(`10.43.0.10`) which forwards to the node's upstream — the router again. So nothing queries
these names directly.

Editing a record is now a router change: update `/ip dns static`, run `./refresh-exports.sh`,
commit the diff.

mDNS is repeated by the router across vlan10, vlan20 and vlan40, which is what makes
`nas.local` resolve across VLANs. It is now a redundant second path rather than the only
cluster-independent one, but it stays useful: it needs no configuration on the client.

## Notes

- **CGNAT.** The PPPoE WAN address is RFC1918, so inbound port forwarding cannot work. This
  is why ingress is Cloudflare Tunnel (outbound-only). The leftover `dstnat` rules were
  deleted 2026-09-02.
- **The `WAN` interface list contains `ether1`, not `pppoe-o2`.** Internet traffic arrives on
  the PPPoE interface, so anything keyed on `in-interface-list=WAN` never matches. This is
  worse than one dead rule: it leaves the forward chain with no default drop at all. See
  [audit finding 1](#1-the-forward-chain-has-no-default-drop-and-both-wan-rules-are-dead).
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

## Audit 2026-09-03

Verified against the live devices, not inferred from the exports. Ordered by what actually
bites first. Items 1-4 are **applied**; the rest are open.

### 1. The forward chain had no default drop, and both WAN rules were dead — FIXED

`in-interface-list=WAN` holds `ether1`; the internet arrives on `pppoe-o2`. Counters prove
the consequence:

```
defconf: drop all from WAN not DSTNATed      0 packets
Allow internet traffic                       0 packets
defconf: accept established,related      29 977 380 packets
```

Both rules keyed on the WAN list have never matched. A *new* inbound connection therefore
falls past every rule to the forward chain's implicit **accept**. Nothing inbound is being
refused by policy — only CGNAT stands in the way, and CGNAT is topology, not a firewall.

Adding `pppoe-o2` to the list activates both dead rules at once, and both are the ones you
want. Masquerade is keyed on `out-interface=pppoe-o2` directly, so NAT is unaffected.

```
/interface list member add list=WAN interface=pppoe-o2
```

Applied 2026-09-03 behind a 5-minute rollback scheduler, which was removed after verifying.

**Both counters stay at 0 afterwards, and that is expected — do not read it as failure.**
Rule 11 needs `in-interface-list=LAN`, and the `LAN` list holds only `lan_bridge`, so no VLAN
traffic ever matches it; VLAN egress rides the chain's implicit accept, exactly as before.
Rule 10 only counts *unsolicited inbound*, which CGNAT means you may never see. To prove the
list actually resolves `pppoe-o2`, count established inbound instead:

```
/ip firewall filter add chain=forward action=passthrough in-interface-list=WAN comment=wantest place-before=0
# 135 packets in 6s -> the list resolves pppoe-o2. Was 0 before the change.
/ip firewall filter remove [find comment=wantest]
```

**Do not "finish the job" with a default drop on the forward chain.** Because the `LAN` list is
missing every VLAN interface, a terminating drop would kill inter-VLAN traffic and all VLAN
egress. Activating rule 10 is the whole fix.

Verified after the change: lab and vlan40 egress (`http 200`), the Cloudflare tunnel
(`nas.jehli.net` → 302 to Access), and Tailscale CT 105 still online.

### 2. Switch and AP management was open; only the router was hardened — FIXED

Verified **from kube-captain on vlan40** — i.e. reachable by anything running in k3s:

```
10.0.40.2:23   OPEN   (telnet, cleartext admin login)
10.0.40.2:80   OPEN   (WebFig)
10.0.40.2:8291 OPEN   (Winbox)
10.0.40.2:8728 OPEN   (API)
```

Both the switch and the AP run ftp, telnet, www and api enabled with no `available-from`.
The switch holds an L3 address on vlan40, so a compromised container owns its management
plane. Apply what the router already does, on both devices:

```
/ip service set [find name="ftp"] disabled=yes        # and telnet, api, api-ssl
/ip service set [find name="ssh"] available-from=192.168.0.0/24,10.0.10.0/24
```

Applied 2026-09-03 to both. `ftp`, `telnet`, `api`, `api-ssl` and `www-ssl` are disabled;
`ssh`, `www`, `winbox` and (on the switch) `reverse-proxy` are restricted to mgmt + lab.

Two traps worth keeping:

- **The AP runs RouterOS 7.20 and spells the property `address=`, not `available-from=`.**
  The switch is on 7.24 and uses `available-from=`. The wrong one fails with
  `expected end of command`.
- **A port probe cannot verify this.** RouterOS completes the TCP handshake and *then* closes,
  so `/dev/tcp` and `nc` still report the port OPEN from a blocked source. Test at the
  protocol level:

  | From | WebFig | SSH |
  |---|---|---|
  | lab `10.0.10.0/24` (allowed) | `200`, 1320 bytes | negotiates |
  | kube-captain, vlan40 (blocked) | `000`, 0 bytes | `kex_exchange_identification: Connection closed` |

### 3. DNS truncated at 512 bytes for the whole LAN — FIXED

`max-udp-packet-size=512` against a 4096 default. Confirmed:

```
$ dig +notcp @10.0.10.1 nasa.gov DNSKEY
;; flags: qr tc rd ra          <- tc = truncated
$ dig @10.0.10.1 nasa.gov DNSKEY
;; Truncated, retrying in TCP mode.
```

Every response over 512 bytes costs an extra round trip and a TCP session, against
`max-concurrent-tcp-sessions=20` on an 880 MHz mmips box. 1232 is the DNS Flag Day value —
large enough to stop truncating, small enough to stay under path MTU:

```
/ip dns set max-udp-packet-size=1232
```

Applied 2026-09-03. The same query now returns 809 bytes over UDP with no `tc` flag and no
TCP retry.

### 4. Static VM addresses sat inside the vlan40 DHCP pool — FIXED

Pool `vlan40-vms` is `.50-.200` with **0 leases used**; the VMs are statically addressed
in-guest at `.102`, `.104`, `.105`, `.106` — all inside it. Nothing has collided only because
nothing has ever requested a lease on vlan40. One DHCP client is enough to be handed
`10.0.40.102`: the k3s control plane, and the target of the `lan.jehli.net` forward.

Narrowing keeps template provisioning working and removes the overlap. Convention: DHCP below
`.100`, statics at `.100` and above.

```
/ip pool set vlan40-vms ranges=10.0.40.50-10.0.40.99
```

Applied 2026-09-03.

### 5. Dead router config

Every item below matches nothing on this network:

| Config | Why it is dead |
|---|---|
| `/ip firewall mangle` → `prusa-vpn` | matches `src-address=192.168.1.12`; mgmt is `192.168.0.0/24`, so 192.168.1.0/24 does not exist here. Its route is `disabled=yes` with `gateway=""` — if it ever *did* match, the traffic would blackhole. Delete the rule, the route and `/routing table prusa-vpn`. |
| `/routing bfd configuration interfaces=all` | BFD enabled on every interface with zero BGP/OSPF peers — pure CPU cost on mmips. |
| `/routing ospf instance`, `/routing bgp template` | no peers, no areas enabled. |
| `/interface ovpn-server` | unused server offering `auth=sha1,md5`. |
| `/ip dns static router.lan → 192.168.88.1` | defconf leftover; that subnet has not existed since 2026-09-02. Also on the AP. |
| `/tool sniffer filter-ip-address=10.0.40.100/32` | that was `librarian`, deleted 2026-09-03. |
| `/interface wireless security-profiles`, `/interface lte apn` | the hEX has neither radio nor LTE. |

`ether3/4/5` carry `ingress-filtering=no` while the bridge runs `vlan-filtering=yes` — only
`ether2`, the real trunk, is filtered. **Keep `ether3`**: `pvid=10` puts a laptop plugged into
it inside `mgmt-allowed`, which is the recovery path if the input chain locks you out. Strip
`ether4`/`ether5`.

### 6. Switch ports

`ether7` is down but trunks vlan 10/20/30/40 with untagged 20 — plug in, reach everything.
`sfp-sfpplus1/2` are down with `pvid=1`, i.e. untagged **management**. Disable all three.

`ether4`/`ether6` are the hypervisor trunks and both carry `pvid=1`, so any untagged frame
from a guest lands on the management VLAN — the one `mgmt-allowed` trusts. Every VM is
`tag=40` today, so a forgotten tag is the whole exposure; `pvid=40` makes that mistake land
harmlessly among the other VMs.

### 7. AP

- `auto-smb-sharing=yes` with `auto-smb-user=guest` plus `auto-media-sharing=yes` on the
  bridge — an SMB server with guest access, running on a Wi-Fi AP. `/disk settings set
  auto-smb-sharing=no auto-media-sharing=no`.
- `discover-interface-list=all` announces model, RouterOS version and identity by MNDP/CDP
  onto **guest and IoT** Wi-Fi. The router correctly scopes this to `LAN`; scope the AP to
  `vlan1-mgmt`.
- `ft=yes` / `ft-over-ds=yes` — 802.11r with a **single AP** has nothing to roam to. It buys
  zero and is a known compatibility problem for older IoT clients. Remove.
- IPv6 is enabled and carries ~35 lines of defconf IPv6 firewall, while the router runs
  `disable-ipv6=yes` and the WAN has no IPv6 at all. `/ipv6 settings set disable-ipv6=yes`
  deletes the stack and its whole ruleset.
- 5 GHz is pinned to `5500-5560`, entirely DFS. A radar detection forces a channel change
  with a 10-minute CAC — a Wi-Fi outage. Channels 36-64 trade some spectrum for no radar
  dropouts.

### 8. NTP is disabled on all three devices, and the AP is two hours out

```
router  10:01:53  tz=Europe/Prague  ntp=false
switch  10:01:55  tz=Europe/Prague  ntp=false
ap      12:02:12  tz=Europe/Prague  ntp=false   <- +2h
```

None of these boards has a battery-backed RTC, so every power cut — and there was one on
2026-09-01 — brings all three up with a wrong clock. That is precisely when firewall logs
(`iot-drop`, `guest-drop`, `inputdrop`) are the evidence you need, and skewed timestamps make
them uncorrelatable. The AP is already wrong *now*.

```
/system ntp client set enabled=yes servers=time.google.com,pool.ntp.org   # router
/system ntp client set enabled=yes servers=10.0.10.1,time.google.com     # switch
/system ntp client set enabled=yes servers=192.168.0.1,time.google.com   # AP
```

### 9. Hosts still search the retired `cdglan.org`

`pve`, `holly` and `kube-worker` carry `search cdglan.org` in `/etc/resolv.conf`; kube-worker
also lists `nameserver 192.168.0.1` twice. The domain was retired 2026-09-02, so every
short-name lookup on those hosts appends a dead suffix before failing over. Should be
`lan.jehli.net`. Nothing points at CoreDNS directly — every host resolves via the router,
which is what makes finding 5 in [`../MIGRATION.md`](../MIGRATION.md) safe.

### 10. No recent config backup on the router

`free-hdd-space` is **3.6 MiB of 16 MiB**, so scheduled local `/system backup` files do not
fit. `refresh-exports.sh` is the backup, and it only runs when you remember. Run it after
every change — an export you did not take is the one you needed.

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
