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
| 9001 | debian12-template | pve | — | — | template, not a running guest |
| 104 | **kube-worker** | holly | 4G / 2 | 10.0.40.104 | k3s agent |
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

- **holly carries both `kube-worker` and the NAS.** Losing holly takes storage away from the
  whole cluster, including pods running on kube-captain. This is the largest one.
- **`kube-captain` is the only control plane**, and it hosts `lan.jehli.net` resolution via
  `coredns-lan`. If it is down, LAN name resolution goes with it — `nas.local` (mDNS, served
  by the router) is the fallback.
- **The Proxmox cluster expects 2 votes with 2 nodes and no qdevice**, so losing either host
  loses quorum. This is what produced the `no quorum!` errors when both wedged on 2026-09-01.
- **No shared Proxmox storage**, so no live migration; a host outage means downtime for its
  guests.
