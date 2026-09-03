# Servers

Compute and storage. Network topology is in [`network/`](network/README.md); cluster
operational notes are in [`MIGRATION.md`](MIGRATION.md).

```
        switch ether4 (tagged 10,20,40)      switch ether6 (tagged 10,20,40)
                     │                                    │
                   eno1                                enp3s0
        ┌────────────┴────────────┐          ┌────────────┴────────────┐
        │  pve   i5-8500T 6c/15G  │          │ holly  N6005 4c/15G     │
        │  vmbr0 (vlan-aware)     │          │ vmbr0 (vlan-aware)      │
        │   .10 → 10.0.10.4  mgmt │          │  .10 → 10.0.10.5   mgmt │
        │   .40 → 10.0.40.4   vms │          │  .40 → 10.0.40.5    vms │
        ├─────────────────────────┤          ├─────────────────────────┤
        │ 102 kube-captain  k3s   │          │ 104 kube-worker    k3s  │
        │ 105 tailscale (LXC)     │          │ 106 tailscale2 (LXC)    │
        │ 9001 debian12-template  │          │ 201 omv    NAS + 4×8TB  │
        └─────────────────────────┘          └─────────────────────────┘
                        all VMs tagged VLAN 40
```

Proxmox 8.4.6 on both, cluster `cdglan`, quorate.

## VMs

VMID's last octet matches the host's last octet — VM 102 is `10.0.40.102`. All are `tag=40`
and `onboot=1` unless noted.

| ID | Name | Host | RAM/cores | Address | Role |
|---|---|---|---|---|---|
| 102 | **kube-captain** | pve | 8G / 2 | 10.0.40.102 | k3s server (control plane) |
| 105 | **tailscale** | pve | 512M / 1 | 10.0.40.105 | LXC — Tailscale subnet router |
| 9001 | debian12-template | pve | — | — | template, not a running guest |
| 104 | **kube-worker** | holly | 4G / 2 | 10.0.40.104 | k3s agent |
| 106 | **tailscale2** | holly | 512M / 1 | 10.0.40.106 | LXC — Tailscale subnet router (HA pair) |
| 201 | **omv** | holly | 4G / 3 | 10.0.40.201 | OpenMediaVault — NFS + SMB for everything |

**Removed 2026-09-03:** `librarian` (100), `caddy` (103), `netconsole-rx` (101) and
`avahi-reflect` (202). The first three ran but served nothing on 22/80/443/8080 from the lab
VLAN; caddy predated the Cloudflare tunnel, and avahi-reflect was superseded by the MikroTik's
own `mdns-repeat-ifaces`.

`vzdump` archives were taken first and live in `/var/lib/vz/dump/` on their respective hosts —
librarian 3.7G, caddy 488M, netconsole-rx 1.37G, avahi-reflect 617M. Delete them once you are
satisfied nothing is missed. Keep librarian's longest: it had ~21G allocated at 65% thin
usage, so it held real data.

That leaves only `kube-captain` and a template on pve, and `kube-worker` plus the NAS on
holly. pve `local-lvm` went 51% → 23%.

## How VLANs reach the VMs

Both hypervisors are wired identically:

1. The switch port is a **trunk** — `ether4` for pve, `ether6` for holly, both tagged
   10, 20, 40.
2. The physical NIC (`eno1` / `enp3s0`) is the sole bridge port of **`vmbr0`**, which is
   `bridge-vlan-aware yes` with `bridge-vids 2-4094`. The bridge itself carries no address.
3. The **host** gets its addresses from VLAN sub-interfaces on that bridge:
   `vmbr0.10` → `10.0.10.4` / `10.0.10.5` (management, default gateway `10.0.10.1`) and
   `vmbr0.40` → `10.0.40.4` / `10.0.40.5`.
4. A **guest** lands in a VLAN purely via its NIC tag:
   `net0: virtio=...,bridge=vmbr0,firewall=1,tag=40`. Change `tag` and the VM moves VLAN with
   no other change.

So hypervisors are dual-homed — managed on vlan10, talking to guests on vlan40 — while every
guest sits only on vlan40. vlan20 reaches both trunks but no guest uses it.

Note vlan10 ↔ vlan40 is routed **in the CRS310's hardware**, not by the router, so that
traffic never passes the router's firewall. Between those two VLANs even ICMP works; between
lab and IoT it does not.

## Tailscale

Two unprivileged Debian 12 LXCs act as **subnet routers** — remote access to the LAN without
exposing anything inbound. That matters here: the WAN is CGNAT, so port forwarding cannot
work, and Tailscale traverses it via NAT punching or a DERP relay.

| CT | Host | Address | Tailscale hostname |
|---|---|---|---|
| 105 | pve | 10.0.40.105 | `homelab-subnet-router` |
| 106 | holly | 10.0.40.106 | `homelab-subnet-router-2` |

Both advertise **identical** routes, which is what makes them an HA pair: Tailscale elects one
primary and fails over to the other automatically. One per hypervisor, so losing either host
leaves remote access intact.

Containers rather than VMs, and not on the router or in Kubernetes, deliberately:

- **Not on the MikroTik** — the RB750Gr3 is `mmips`, and RouterOS containers need arm or x86.
  The CRS310 and hAP are arm and *could* host it, but neither has spare headroom worth using.
- **Not in Kubernetes** — chicken-and-egg. The cluster runs on these hypervisors; when it
  breaks, remote access is exactly what you need to fix it.
- **One per hypervisor** — pve also holds the only k3s control plane, so a router there alone
  would fail with the thing you need access to fix.

### Routes advertised

| Route | VLAN |
|---|---|
| `10.0.10.0/24` | lab |
| `10.0.20.0/24` | iot |
| `10.0.40.0/24` | vms |
| `192.168.0.0/24` | mgmt |

**`192.168.0.0/16` is deliberately not advertised**, even though the interface was a /16 until
recently. Advertising it would swallow every foreign `192.168.x.x` network you connect
from — hotels, cafés, other people's houses — and break your local connectivity while the
tunnel is up. vlan30 (guest) is intentionally excluded.

Placement does not restrict reach: every VLAN routes to every other, so a container on vlan40
can serve all four.

### The two things that bite

**`/dev/net/tun` in an unprivileged LXC.** Tailscale cannot create its interface without it,
and the container gets no such device by default. Two lines in each container's
`/etc/pve/lxc/<id>.conf`:

```
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

**IP forwarding.** Without it, subnet routing fails silently — the node appears healthy and
routes appear advertised, but nothing passes. Set in `/etc/sysctl.d/99-tailscale.conf`.

### Operating it

Started with:

```sh
tailscale up --advertise-routes=10.0.10.0/24,10.0.20.0/24,10.0.40.0/24,192.168.0.0/24 \
             --accept-dns=false --hostname=homelab-subnet-router
```

`--accept-dns=false` keeps the router itself off MagicDNS, avoiding resolution loops.

Both live since 2026-09-03 — `100.116.69.45` (CT 105) and `100.97.22.61` (CT 106), all four
routes approved on each, key expiry disabled. Both reach a host in every advertised subnet
(pve on lab, the robot on iot, NAS SMB on vms, the switch on mgmt), and both have `tailscaled`
enabled at boot alongside `onboot: 1` with `ip_forward` persisted in `sysctl.d`, so a host
reboot brings them back.

**Failover was tested, not assumed.** Stopping CT 105 moved all four routes to CT 106 within
seconds. Reading the pair: exactly one shows `PrimaryRoutes`; the standby shows none but still
lists the routes in `AllowedIPs` — that is what "approved but standby" looks like, and it is
easy to misread as broken. Tailscale does **not** pre-empt, so after a failover the survivor
keeps the routes even once the other returns. That is harmless; do not chase it.

### Split DNS

To resolve `*.lan.jehli.net` over the tunnel, in the admin console under **DNS**:

1. **Nameservers → Add nameserver → Custom**, address **`10.0.10.1`**.
2. Enable **Restrict to search domain** and enter **`lan.jehli.net`**.

Point it at the **router**, not CoreDNS on `10.0.40.102`. The router is always up and already
forwards that zone to CoreDNS; pointing at CoreDNS directly makes remote name resolution
depend on kube-captain being healthy.

Two things that stop this working:

- **The client must accept routes.** `10.0.10.1` is only reachable through an advertised
  subnet. Linux needs `tailscale up --accept-routes`; on macOS, iOS and Windows it is a
  toggle, off by default on some versions. Symptom is DNS timing out while the tunnel looks
  fine.
- **The subnet routers themselves run `--accept-dns=false`** on purpose, to avoid resolution
  loops. That setting is per-node and does not affect your clients.

`nas.local` will not work remotely — mDNS does not traverse Tailscale. Use
`nas.lan.jehli.net`, or the IP.

Not configured: exit node. Add `--advertise-exit-node` if you want all traffic routed home,
bearing in mind the upstream is a CGNAT PPPoE line.

## Storage

**NAS (omv, VM 201 on holly)** — physical disks passed through by `by-id`, not virtual:

- 4 × WD Red 8TB → Linux md **RAID5**, 22T usable, 6.3T used, all four healthy `[UUUU]`.
  Serves `/export/media-library`, `downloads`, `music`, `iso`, `frigate-storage`.
- 1 × Crucial MX500 500GB → `/export/ssd-data` (and `frigate-config`), 2.3G used. This is
  where every k8s config volume lives.
- 15 NFS exports, 10 SMB shares.

**Proxmox** — `local` (dir, 71G, also holds the vzdump archives) and `local-lvm` (LVM-thin;
pve 148G at 23%, holly 354G at 9%). Not shared between the two hosts, so VMs cannot
live-migrate.

**Kubernetes** — 14 NFS PVs, all pointing at `10.0.40.201` by IP (see MIGRATION.md for why
not a name), plus one `local-path` PV for mariadb.

## Kubernetes

k3s `v1.36.2+k3s1`, Debian 12, two nodes: `kube-captain` (control plane, on pve) and
`kube-worker` (agent, on holly). Pods currently sit 40 / 15 across them.

| Namespace | Runs |
|---|---|
| `homeassistant` | homeassistant, esphome, homebridge, mosquitto (MQTT) |
| `media-stack` | sonarr, radarr, prowlarr, deluge, flaresolverr |
| `homelab-services` | adminer, dobby-robot, openmediavault (UI proxy), coredns-lan ×2 |
| `monitoring` | kube-prometheus-stack — prometheus, grafana, alertmanager, operator, kube-state-metrics |
| `jellyfin`, `navidrome` | media servers |
| `cert-manager` | cert-manager + cainjector + webhook |
| `cloudflare-tunnel-ingress-controller` | tunnel controller + cloudflared connector |
| `nginx-ingress` | ingress-nginx — **zero ingresses use it** |
| `kube-system` | coredns, local-path-provisioner, metrics-server |

All 15 ingresses are `cloudflare-tunnel`. Three LoadBalancer services are exposed by k3s
servicelb on both node IPs: `mosquitto` (1883, 9001), `coredns-lan` (53) and
`ingress-nginx-controller` (80, 443) — the last still holding those ports for no consumer.

`homeassistant` is pinned to kube-captain by a required `skyconnect-dongle` node affinity and
a `/dev/ttyUSB0` hostPath — it cannot run on kube-worker.

## Single points of failure

- **`kube-captain` is the only k3s control plane**, on pve. Remote access no longer depends on
  it once CT 106 is authenticated, but the cluster still does.
- **holly carries both `kube-worker` and the NAS.** Losing holly takes storage away from the
  whole cluster, including pods running on kube-captain. This is the largest one.
- **`kube-captain` is the only control plane**, and it hosts `lan.jehli.net` resolution via
  `coredns-lan`. If it is down, LAN name resolution goes with it — `nas.local` (mDNS, served
  by the router) is the fallback.
- **The Proxmox cluster expects 2 votes with 2 nodes and no qdevice**, so losing either host
  loses quorum. This is what produced the `no quorum!` errors when both wedged on 2026-09-01.
- **No shared Proxmox storage**, so no live migration; a host outage means downtime for its
  guests.
