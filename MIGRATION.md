# Cluster notes

The `cdglan.org` → `jehli.net` migration is finished (2026-09-01/02). This keeps only what is
still useful: open issues, and the traps worth not rediscovering. The blow-by-blow is in git
history. Network topology and router config live in [`network/`](network/README.md).

## Open items

Re-verified live 2026-09-03. Ordered by consequence.

> **`prometheus.jehli.net` and `alertmanager.jehli.net` are internet-reachable with no
> authentication.** Still open — confirmed again today: both return `HTTP 200`, and
> `/api/v1/query?query=up` hands back real metrics naming internal endpoints
> (`10.0.40.104:9100`), namespaces and job names. The Alertmanager API can create silences,
> so anyone can mute your alerting. **Add Cloudflare Access policies for both** — Access on
> `jehli.net` is per-application, not a wildcard. To close it immediately instead, set
> `enabled: false` on those two ingresses in `kube-prometheus-stack.yaml` and re-apply.

- **Proxmox has no quorum tiebreaker, and the tiebreaker is already racked.** `pvecm status`
  reports `Expected votes: 2, Quorum: 2` — losing either host loses quorum, which is what
  produced the `no quorum!` errors when both wedged on 2026-09-01. `overwatcher`, the RPi 4 on
  `10.0.10.128`, is up and does nothing quorum-related. A qdevice makes it the third vote:

  ```sh
  # on overwatcher
  sudo apt install corosync-qnetd
  # on pve (once)
  sudo apt install corosync-qdevice   # and on holly
  sudo pvecm qdevice setup 10.0.10.128
  ```

  Best resilience-per-effort item in the setup, on hardware already running.

- **LAN DNS no longer depends on the k3s control plane.** *(done 2026-09-03)* `coredns-lan`
  was a two-replica CoreDNS behind a LoadBalancer whose entire zone was six A records for
  fixed appliances, and the router's `type=FWD` entry pointed at `10.0.40.102` with no
  failover — so `lan.jehli.net` died with kube-captain. The records now live in
  `/ip dns static` on the router and the HelmChart is gone, removing a single point of
  failure, a LoadBalancer on port 53, two pods and a layer of indirection.

  **The precondition was checked, not assumed: nothing resolved against CoreDNS directly.**
  `pve`, `holly`, `kube-captain` and `kube-worker` all point at the router (`192.168.0.1`);
  the NAS uses `127.0.0.53`. Pods go via cluster CoreDNS (`10.43.0.10`), which forwards to the
  node's upstream — the router again. Every lookup already traversed the router, so the static
  records simply answer a hop earlier instead of being forwarded into the cluster.

  Nothing was lost on short names: vlan20 and vlan40 are handed no `domain` option, and the
  old `FWD` entry only matched `lan.jehli.net`, so a bare `nas` returned NXDOMAIN before the
  change too. To get short names on vlan40, that is a separate one-liner
  (`/ip dhcp-server network set [find comment=vlan40-vms] domain=lan.jehli.net`).

  Verified after removal, with the chart deleted: all six names resolve from lab, from both
  vlan40 hosts, and from inside a pod; kube-worker's 14 NFS mounts were untouched (they use
  IPs). Cutover was a single batch — do not run the statics alongside the `FWD` entry, as
  precedence between an exact-name static and a `match-subdomain` forward is ambiguous.

  If cluster services ever move behind a LAN ingress and need *dynamic* names, that is the
  case for bringing CoreDNS back with `k8s_gateway`. Today every ingress is cloudflare-tunnel
  with no LAN address, so there is nothing to discover.

- **`ingress-nginx` removed (2026-11-10).** It had zero consumers (all 15 ingresses are
  `cloudflare-tunnel`) but held a LoadBalancer on 80/443 across both node IPs, and upstream
  had retired the project. The `ingressClassName: nginx` defaults in `helm/*/values.yaml`
  are dead; every manifest overrides them.

- **mosquitto persistence has never worked.** The chart renders `mosquitto.conf` with
  persistence enabled and provisions `mosquitto-pvc`, but the deployment never mounts that
  claim — it mounts an `emptyDir` and the ConfigMap. `mosquitto.db` therefore lives in
  container-local storage and is discarded on every restart;
  `/export/ssd-data/mosquitto/data` on the NAS has been empty since Feb 2026. The fix and the
  evidence are in a `TODO` in `helm/mosquitto/templates/deployment.yaml`.

- **No UPS monitoring on `pve`** — `nut-monitor` and `apcupsd` both confirmed `inactive`
  again today. Both hosts lost power on 2026-09-01 after wedging for ~15h. If a UPS is
  attached, nothing is listening to it, so nothing shuts down cleanly.

- **NFS mounts are `hard`.** Confirmed `hard` on kube-captain. That is what turned a NAS stall
  into an uninterruptible node hang rather than degraded pods. `soft`/`softreloc` would
  degrade instead. The mount also still reports the `omv.cdglan.org:` device string — the
  superblock alias described under Traps, not a live DNS dependency.

- **`holly` carries both `kube-worker` and the NAS** (see SERVERS.md). Every NFS PV points at
  it, so losing holly takes storage from pods on *both* nodes. Nothing here fixes that without
  moving the NAS or the disks; it is the structural limit of a two-host setup and worth stating
  plainly rather than designing around.


## Why NFS uses an IP, not a name

`nas.jehli.net` resolves *publicly* to Cloudflare proxy IPs — NFS cannot traverse that. Giving
bind an internal `jehli.net` zone would make it authoritative for every public hostname too,
so each would need a matching internal record or break on the LAN.

The NAS is a fixed appliance at `10.0.40.201`. It gains nothing from DNS indirection, and a
name is exactly what wedged the cluster: hard NFS mounts against an unresolvable
`omv.cdglan.org` left kube-captain in uninterruptible sleep for ~15h. All 14 PVs use the IP.

## Moving a PV to a new NFS server

`spec.persistentvolumesource` is immutable:

```
The PersistentVolume "sonarr-config-pv" is invalid: spec.persistentvolumesource:
Forbidden: spec.persistentvolumesource is immutable after creation
```

So each PV must be deleted and recreated. **Every PV is `Retain`**, so deleting one does not
touch data on the NAS. Do one service at a time and verify before moving on. Four shapes:

**PV in the manifest, PVC owned by Helm** — `esphome`, `homebridge`, `mosquitto`.
`kubectl apply` recreates the PV but leaves the HelmChart CR unchanged, so helm-controller
never re-runs and the PVC never returns. Delete the install Job to force it:

```sh
NS=homeassistant DEPLOY=esphome-deployment PVC=esphome-pvc PV=esphome-config-pv
kubectl -n $NS scale deploy/$DEPLOY --replicas=0
kubectl -n $NS wait --for=delete pod -l app=esphome --timeout=150s
kubectl -n $NS delete pvc $PVC && kubectl delete pv $PV
kubectl apply -f manifests/helm-controller-charts/esphome.yaml   # recreates the PV only
kubectl -n $NS delete job helm-install-esphome                   # forces PVC recreation
```

**PV *and* PVC in the manifest** — `jellyfin` only. No helm job; scale back up by hand. Its
pod selector is `app.kubernetes.io/name=jellyfin`, not `app=`.

**PV created by the chart** — `deluge`, `navidrome`, `prowlarr`, `radarr`, `sonarr`. Editing
`valuesContent` is what re-triggers helm-controller, so delete the volumes *first*, then
apply, or the upgrade fails on the immutable PV.

**Inline pod volume, no PV** — `homeassistant`. Just apply and let it roll. It is
hardware-pinned by a required `skyconnect-dongle` affinity and a `/dev/ttyUSB0` hostPath, so
it can only run on kube-captain — never drain it to clean up a mount.

`mosquitto`'s PV is `mosquitto-data-pv`, not `mosquitto-pv`.

## Traps

**NFS superblock aliasing looks like a failed migration.** The Linux NFS client aliases
superblocks per (server, export). kube-captain first mounted these exports as
`omv.cdglan.org`, so every later mount of the same export inherits that device string — even
when mounted explicitly by IP. Confirmed by mounting the export by hand and watching
`/proc/mounts` still report `omv.cdglan.org:`. The options show `addr=10.0.40.201`, so traffic
goes to the IP and nothing consults DNS at runtime. Clears on reboot.

**A chart edited without a version bump aborts the whole release run.** chart-releaser
packages every changed chart and fails hard on an existing tag
(`422 ... Code:already_exists`), leaving later charts unreleased and `index.yaml` never
regenerated. `skip_existing: true` is now set in `.github/workflows/helm-release.yaml`.

**chart-releaser only processes charts changed in the triggering push.** Fixing one chart and
pushing again republishes only that chart. Recovering the rest meant uploading the missing
releases with `cr` and rebuilding the index by hand.

**`helm repo update` can return a cached index.** It reported success while still serving a
stale 15 KB index, so every `helm show chart` failed with "not found in index" even though
GitHub Pages served the correct 19 KB file. Delete
`~/Library/Caches/helm/repository/<repo>-index.yaml`.

**Pods relocate when you scale to zero.** Most of these workloads had only ever run on
kube-captain; the scheduler placed them on kube-worker, which had never mounted NFS before.
kube-worker is now on the NAS critical path too.

## The NAS

Already fully migrated — nothing was needed:

- The host identifies as `nas.jehli.net`.
- Its web UI is exposed at `nas.jehli.net` **behind Cloudflare Access** (redirects to
  `jehlici.cloudflareaccess.com`).
- Only HTTP is exposed: ingress → `openmediavault:9062` → nginx-proxy → `10.0.40.201:80`.
  NFS and SMB are not routed through the tunnel, as intended — use Tailscale for those.

For SMB on the LAN use `nas.lan.jehli.net` (via CoreDNS) or `nas.local` (mDNS, and
cluster-independent, so it survives kube-captain being down).
