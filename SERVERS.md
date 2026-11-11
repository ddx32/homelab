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
        │ 100 librarian  MariaDB  │          │ 104 kube-worker    k3s  │
        │ 102 kube-captain  k3s   │          │ 106 tailscale2 (LXC)    │
        │ 105 tailscale (LXC)     │          │ 201 omv    NAS + 4×8TB  │
        │ 9002 debian13-template  │          │                         │
        └─────────────────────────┘          └─────────────────────────┘
                        all VMs tagged VLAN 40
```

Cluster `cdglan`, quorate. **Both nodes on Proxmox VE 9.2 (Debian 13, kernel 7.0)**, upgraded
from 8.4 on 2026-11-10 (8 went end of life in Aug 2026).

Guests start in order and get a long shutdown timeout, so k3s and Home Assistant always stop
before the storage and database they depend on (Proxmox force-stops anything past 180 s):

| Node | Order (start → ; shutdown is reverse) |
|---|---|
| pve | tailscale → librarian (`up=10`) → kube-captain (`down=600`) |
| holly | tailscale2 → omv (`up=60`, `down=300`) → kube-worker (`down=600`) |

Ordering cannot span nodes: kube-captain's pods simply wait for omv's NFS if both hosts boot
together.

Notes from the 8 → 9 upgrade, for the next major one:

- Prep (no downtime): remove the `systemd-boot` meta-package (the `pve8to9` blocker), install
  `grub-efi-amd64` (pve booted UEFI with `grub-pc`) with
  `grub2/force_efi_extra_removable=true`, add `non-free-firmware` + `intel-microcode`, and pin
  NIC names. `pve-network-interface-pinning` refuses to pin an interface to its current name,
  so the pins are hand-written `.link` files in `/usr/local/lib/systemd/network/50-pin-*.link`
  (MAC → current name). Both nodes are prepped; `pve8to9 --full` shows 0 failures.
- Back up first (see [BACKUPS.md](BACKUPS.md)), shut guests down, switch repos to `trixie`
  (security moves to `http://security.debian.org/debian-security trixie-security`), and run
  `dist-upgrade` as a `systemd-run` unit so a dropped SSH session cannot kill it. ~15 min.
- Expected during the upgrade: a few seconds with no network while networking and corosync
  restart; chrony failing to start until the reboot (`Could not send notification to
  $NOTIFY_SOCKET`, new chrony vs. the old systemd still running as PID 1). Both clear up on
  reboot. `lvm.conf` was kept: it only adds Proxmox's ZFS/Ceph filter, which is harmless here.
- Taking omv down stalls every NFS-backed pod; jellyfin's liveness probe restarts it a few
  times and it recovers on its own once the NAS is back.
- **pve's guests would not start on kernel 7.0**: every network attach to `vmbr0` failed with
  `RTNETLINK answers: Unknown error 524` / `netpoll: fwpr…p0 doesn't support polling`. Cause:
  a hand-made `netconsole-sender.service` (June 2026) bound netconsole to `vmbr0.40`, and the
  7.0 kernel refuses bridge ports without netpoll support while netconsole uses the bridge.
  Its target, a "capture VM" at `10.0.40.210`, no longer existed. The service is disabled
  (not deleted). Kernel logs off-host would need netconsole on a dedicated NIC, or journald/
  rsyslog forwarding instead.

## VMs

VMID's last octet matches the host's last octet — VM 102 is `10.0.40.102`. All are `tag=40`
and `onboot=1` unless noted.

| ID | Name | Host | RAM/cores | Address | Role |
|---|---|---|---|---|---|
| 100 | **librarian** | pve | 1G / 1 | 10.0.40.100 | MariaDB — Home Assistant's recorder DB |
| 102 | **kube-captain** | pve | 8G / 2 | 10.0.40.102 | k3s server (control plane) |
| 105 | **tailscale** | pve | 512M / 1 | 10.0.40.105 | LXC — Tailscale subnet router |
| 9002 | debian13-template | pve | — | — | template, Debian 13 generic cloud image (2026-11-11) |
| 9001 | debian12-template | pve | — | — | old template, nothing cloned from it; delete when convenient |
| 104 | **kube-worker** | holly | 4G / 2 | 10.0.40.104 | k3s agent |
| 106 | **tailscale2** | holly | 512M / 1 | 10.0.40.106 | LXC — Tailscale subnet router (HA pair) |
| 201 | **omv** | holly | 4G / 3 | 10.0.40.201 | OpenMediaVault — NFS + SMB for everything |

**Removed 2026-09-03:** `caddy` (103), `netconsole-rx` (101) and `avahi-reflect` (202). caddy
predated the Cloudflare tunnel and had nothing behind it; avahi-reflect was superseded by the
MikroTik's own `mdns-repeat-ifaces`.

`vzdump` archives are in `/var/lib/vz/dump/` on their respective hosts — caddy 488M,
netconsole-rx 1.37G, avahi-reflect 617M. Delete them once you are satisfied nothing is missed.

**`librarian` was deleted the same day and restored from its archive at 12:06.** It was *not*
vestigial: it serves MariaDB on 3306 and Home Assistant on `kube-captain` uses it as the
recorder backend, hard-coded to `10.0.40.100`. The removal was gated on a port scan of
22/80/443/8080 — which does not include 3306 — so a database-only host looked identical to a
dead one. `ansible/playbooks/db/mysql.yaml` says `hosts: librarian`, as did `influxdb.yaml`
(since removed); both were in the repo the whole time. librarian was in the inventory, but
nothing connected the two.

**Before deleting a VM, scan the ports its services would actually use, and grep the repo for
its hostname.** Reachability on a handful of well-known ports is not evidence of disuse.

Restore cost ~90 minutes of Home Assistant history (08:33–10:03). Nothing else was lost: HA
holds its recorder queue in memory while the DB is unreachable and back-filled 10:03 onward on
reconnect — verified by a contiguous `state_id` run across the gap.

`librarian` used to answer only on its own subnet, which predated the restore and is now
fixed. It is statically addressed at `.100`, outside the vlan40 DHCP pool (`10.0.40.50-99`),
so it never received the `classless-v40-121` route option every DHCP client on vlan40 gets —
`10.0.10.0/24 via 10.0.40.2` (the CRS310, `comment=l3-routing`). Replies to vlan10 sources
went out the default gateway `10.0.40.1` instead, which does not hardware-route
vlan10 ↔ vlan40, so they were dropped. Home Assistant never noticed, because `kube-captain`
is on vlan40 too — but pings and `ansible librarian -m ping` from a vlan10 workstation timed
out, which is why the host looked dead from two directions at once.

The route is now a `post-up` line in `/etc/network/interfaces` (`ip route replace`, so it is
idempotent; original saved as `interfaces.bak`). Verified with `ifquery ens18`, then a ping
from `10.0.10.4` and `ansible librarian -m ping` from a workstation. **Any statically
addressed host on vlan40 needs this route set by hand** — the DHCP option only reaches hosts
inside the pool.

It has to be **persistent network config, not a boot-time `ip route`**. kube-captain and
kube-worker had it as a oneshot `route-vlan10.service`; the Debian 13 upgrade restarted
networking, the route was flushed, and kube-worker went silent to vlan10 until it rebooted.
Where each host keeps it now:

| Host | Route lives in |
|---|---|
| librarian, kube-captain | `post-up` in `/etc/network/interfaces` (`route-vlan10.service` kept on kube-captain, harmless) |
| kube-worker | `/etc/netplan/90-local-routes.yaml` (cloud-init only rewrites `50-cloud-init.yaml`) |
| omv | `/etc/netplan/90-local-routes.yaml` (OMV only rewrites `NN-openmediavault-*.yaml`) |

**librarian: Debian 13, MariaDB 11.8** (from 10.11, 2026-11-11; a logical dump taken first is
in `/root/mariadb-10.11-pretrixie.sql.zst`). Home Assistant connects as MariaDB `root` over
the network; a user limited to the `homeassistant` database would be better.

**InfluxDB was removed from `librarian` 2026-09-03; MariaDB is the only database it serves.**
Both packages are purged and `/var/lib/influxdb` is gone. The guest went 14G → 3.5G used.

The 11G that made librarian look data-heavy was InfluxDB 2's `_monitoring` bucket — its own Go
runtime telemetry (`go_memstats_*`, `boltdb_reads_total`, `storage_writer_*`) with no retention
policy, from Nov 2023 to 2024-02-25. Identified from the TSM index, not guessed. The running
InfluxDB 1.6.7 had only `_internal`; it never held user data, because Home Assistant's
integration is configured for `api_version: 2` and 1.6.7 does not speak that API.

A 30M bucket of real HA sensor history (through 2025-09-25) was also lost — `apt-get purge
influxdb` removes `/var/lib/influxdb` wholesale, so it went before it could be spared. It is
recoverable from `vzdump-qemu-100-2026_09_03-08_33_40.vma.zst`; **keep that archive.**

Follow-ups:

- Home Assistant still has a dead `influxdb:` block in `configuration.yaml` pointing at
  `10.0.40.100:8086`, bucket `homeassistant`. It has had nothing to talk to since influxdb2
  was removed and now has no listener at all. Remove it or stand influxdb2 back up.
- `scsi0` now has `discard=on`, but the change needs a VM power cycle before the guest's
  `fstrim` reaches the thin pool. Until then `vm-100-disk-0` still reads 63% allocated and
  `local-lvm` stays at 38% despite 26G being free inside the guest. Power-cycle then
  `fstrim -av`.
- `configuration.yaml` holds the MariaDB password and the old Influx token in plaintext, and
  the recorder connects as `root`. Worth a dedicated user and `secrets.yaml`.

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

Two unprivileged Debian 13 LXCs act as **subnet routers** — remote access to the LAN without
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
  Serves `/export/media-library`, `downloads`, `music`, `iso`, `frigate-storage`, and
  `pve-backups` (Proxmox backups, NFS to the two hypervisors only; see [BACKUPS.md](BACKUPS.md)).
- 1 × Crucial MX500 500GB → `/export/ssd-data` (and `frigate-config`), 2.3G used. This is
  where every k8s config volume lives.
- 15 NFS exports, 10 SMB shares.
- Shutdown: OMV's power button setting (System → Power Management) was "Nothing", so the
  guest ignored Proxmox's ACPI shutdown and a `qm shutdown` timed out. Now "Shutdown", and the
  VM has `agent: enabled=1` with `qemu-guest-agent` running, so Proxmox shuts it down through
  the agent. It stops in seconds. Never force-stop it: the RAID and every NFS client sit behind it.
- **OMV 8.6 on Debian 13**, upgraded 6 → 7 → 8 on 2026-11-11 with `omv-release-upgrade`, run
  in `tmux` because it prompts through `whiptail`. Things the upgrade changed:
  - OMV 7+ writes the network config itself (netplan, static), which dropped the
    `10.0.10.0/24 via 10.0.40.2` route: omv went silent to vlan10 (see librarian above). The
    route now lives in `/etc/netplan/90-local-routes.yaml`; OMV only manages
    `NN-openmediavault-*.yaml`, so it survives redeploys.
  - RAID management moved out of the core into the `openmediavault-md` plugin (installed).
  - The 7 → 8 step left nginx pointing at PHP 8.2's FPM socket while only PHP 8.4 was
    installed, so the web UI loaded but every login returned **502**; NFS and SMB were fine.
    `omv-salt deploy run phpfpm nginx` regenerated both. After any OMV release upgrade, test a
    login, not just the shares.
- The SSD used to be passed through twice (whole disk as `scsi5`, its partition as `scsi6`),
  so the guest saw two devices with the same filesystem UUID. `scsi6` was removed; mounts are
  by UUID, so the device letters shuffling between boots does not matter.

**Proxmox** — `nas-backup` (NFS, vzdump archives), `local` (dir, 71G) and `local-lvm` (LVM-thin;
pve 148G at 23%, holly 354G at 9%). Not shared between the two hosts, so VMs cannot
live-migrate.

**Kubernetes** — 14 NFS PVs, all pointing at `10.0.40.201` by IP (see MIGRATION.md for why
not a name), plus one `local-path` PV for mariadb.

## Kubernetes

k3s `v1.36.2+k3s1`, Debian 13 (kernel 6.12), two nodes: `kube-captain` (control plane, on pve) and
`kube-worker` (agent, on holly). Pods currently sit 40 / 15 across them.

| Namespace | Runs |
|---|---|
| `homeassistant` | homeassistant, esphome, homebridge, mosquitto (MQTT) |
| `media-stack` | sonarr, radarr, prowlarr, deluge, flaresolverr |
| `homelab-services` | adminer, dobby-robot, openmediavault (UI proxy) |
| `monitoring` | kube-prometheus-stack — prometheus, grafana, alertmanager, operator, kube-state-metrics |
| `jellyfin`, `navidrome` | media servers |
| `cert-manager` | cert-manager + cainjector + webhook |
| `cloudflare-tunnel-ingress-controller` | tunnel controller + cloudflared connector |
| `kube-system` | coredns, local-path-provisioner, metrics-server |

All 15 ingresses are `cloudflare-tunnel`. One LoadBalancer service is exposed by k3s
servicelb on both node IPs: `mosquitto` (1883, 9001). `ingress-nginx` held 80/443 for no
consumer until it was removed on 2026-11-10, and `coredns-lan` held 53 until it was retired
to the router on 2026-09-03.

`homeassistant` is pinned to kube-captain by a required `skyconnect-dongle` node affinity and
a `/dev/ttyUSB0` hostPath — it cannot run on kube-worker.

## Single points of failure

- **holly carries both `kube-worker` and the NAS.** Losing holly takes storage away from the
  whole cluster, including pods running on kube-captain. This is the largest one, and the only
  one with no cheap fix — it is the structural limit of two hosts.
- **`kube-captain` is the only k3s control plane**, on pve. Remote access no longer depends on
  it once CT 106 is authenticated, and LAN name resolution no longer does either — the
  `lan.jehli.net` records moved to the router on 2026-09-03. The cluster itself still has no
  second control plane.
- **The Proxmox cluster expects 2 votes with 2 nodes and no qdevice**, so losing either host
  loses quorum. This is what produced the `no quorum!` errors when both wedged on 2026-09-01.
  **Fixable on hardware already running:** `overwatcher` (RPi 4, `10.0.10.128`) can be a
  corosync qdevice and become the third vote — see [MIGRATION.md](MIGRATION.md#open-items).
- **No shared Proxmox storage**, so no live migration; a host outage means downtime for its
  guests.
- **No UPS monitoring on pve**, so a power event is an unclean shutdown for every guest on it.
