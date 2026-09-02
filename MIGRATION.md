# Cluster notes

The `cdglan.org` → `jehli.net` migration is finished (2026-09-01/02). This keeps only what is
still useful: open issues, and the traps worth not rediscovering. The blow-by-blow is in git
history. Network topology and router config live in [`network/`](network/README.md).

## Open items

> **`prometheus.jehli.net` and `alertmanager.jehli.net` are internet-reachable with no
> authentication.** Verified live: unauthenticated `GET /api/v1/query?query=up` returns real
> metrics, `GET /api/v2/status` returns the Alertmanager config. No credentials leak (the
> config is stock), but metrics expose internal topology and the Alertmanager API can create
> silences. **Add Cloudflare Access policies for both** — Access on `jehli.net` is
> per-application, not a wildcard. To close it immediately instead, set `enabled: false` on
> those two ingresses in `kube-prometheus-stack.yaml` and re-apply.

- **mosquitto persistence has never worked.** The chart renders `mosquitto.conf` with
  persistence enabled and provisions `mosquitto-pvc`, but the deployment never mounts that
  claim — it mounts an `emptyDir` and the ConfigMap. `mosquitto.db` therefore lives in
  container-local storage and is discarded on every restart;
  `/export/ssd-data/mosquitto/data` on the NAS has been empty since Feb 2026. The fix and the
  evidence are in a `TODO` in `helm/mosquitto/templates/deployment.yaml`.
- **`ingress-nginx` has zero consumers.** All 15 ingresses are `cloudflare-tunnel`. It still
  runs and still holds a LoadBalancer on 80/443. Remove it, or put something behind it.
- **No UPS monitoring on `pve`** (`nut-monitor` and `apcupsd` both inactive). Both hosts lost
  power on 2026-09-01 after wedging for ~15h.
- **NFS mounts are `hard`.** That is what turned a NAS stall into an uninterruptible node
  hang rather than degraded pods. `soft`/`softreloc` would degrade instead.

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
