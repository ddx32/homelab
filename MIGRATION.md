# cdglan.org → jehli.net migration

Status: **Phases 1 and 2 are applied and verified.** All 14 NFS PVs point at `10.0.40.201`,
and no cloudflare-tunnel ingress carries cert-manager config any more. Phase 3 (retire
cdglan.org) is still outstanding.

## Why NFS moved to an IP, not a name

`nas.jehli.net` resolves *publicly* to Cloudflare proxy IPs (`188.114.x.x`) — NFS cannot
traverse that. Keeping a DNS name for the NAS would require bind to become authoritative
for `jehli.net` internally, which in turn means every public hostname (jellyfin, ha,
sonarr…) needs a matching internal record or it breaks on the LAN.

The NAS is a fixed LAN appliance at `10.0.40.201`. It gains nothing from DNS indirection,
and a name is what wedged the cluster on 2026-09-01 (hard NFS mounts on an unreachable
`omv.cdglan.org` put the node in permanent D-state for ~15h). All NFS references are now
literal IPs.

## What is already done (repo only)

- All 13 `omv.cdglan.org` references → `10.0.40.201` (11 manifests + 2 ansible tasks).
- `manifests/helm-controller-charts/deluge.yaml` re-synced with the cluster. It had drifted
  badly: repo said namespace `homelab-services` / v0.1.1 / `downloads: /export/downloads`,
  cluster runs `media-stack` / v0.1.2 / `downloads: /export/media-library`. **Applying the
  old file would have created a second deluge in the wrong namespace.**
- Dead cert-manager config stripped from 9 charts (annotation + `tls:` block), patch
  versions bumped. TLS terminates at Cloudflare; these Certificates were never consumed and
  had been failing for up to 2 years.
- `letsencrypt-{production,staging}` ClusterIssuer solver retargeted `cdglan.org` → `jehli.net`.
  This one **is** live (helm release `cert-manager-setup` rev 3). `cdglan.org` is not in the
  Cloudflare account at all, so its DNS-01 challenges could never have succeeded.

## Phase 1 — NFS cutover — **DONE 2026-09-01**

All 14 PVs now point at `10.0.40.201`; every PV and PVC is `Bound`, every pod `Running`, and
file counts were checked per service before and after. Notes from the run are inline below.

Two things worth knowing before you read the patterns:

- **Pattern A needed an extra step I had not anticipated.** For `esphome`, `homebridge` and
  `mosquitto` the PV lives in the manifest but the *PVC is owned by Helm*. Deleting the PVC
  does not bring it back, because `kubectl apply` on the manifest leaves the HelmChart CR
  unchanged and helm-controller never re-runs. The fix is to delete the
  `helm-install-<name>` Job — helm-controller recreates it and the re-run restores the PVC.
  `jellyfin` is not affected (its PVCs are declared in the manifest).
- **Old hostname still shows in `mount` on kube-captain — this is cosmetic.** The Linux NFS
  client aliases superblocks per (server, export). kube-captain first mounted these exports
  as `omv.cdglan.org`, so every later mount of the same export inherits that device string
  even when mounted explicitly by IP — verified by mounting `10.0.40.201:/export/ssd-data/
  homeassistant` by hand and watching `/proc/mounts` report `omv.cdglan.org:`. The mount
  options show `addr=10.0.40.201` / `mountaddr=10.0.40.201`, so traffic goes to the IP and
  nothing consults DNS at runtime. It clears on the next reboot of that node. kube-worker,
  which never mounted under the old name, shows all mounts as `10.0.40.201:`.

## Phase 1 — the procedure that was used

`spec.persistentvolumesource` is immutable, confirmed by server dry-run:

```
The PersistentVolume "sonarr-config-pv" is invalid: spec.persistentvolumesource:
Forbidden: spec.persistentvolumesource is immutable after creation
```

So each PV must be deleted and recreated. **Every PV is `Retain`** — deleting a PV does not
touch data on the NAS. Do one service at a time and verify before moving on.

### Pattern A — PV in the manifest, PVC owned by Helm
`esphome`, `homebridge`, `mosquitto`

```sh
NS=homeassistant DEPLOY=esphome-deployment PVC=esphome-pvc PV=esphome-config-pv
kubectl -n $NS scale deploy/$DEPLOY --replicas=0
kubectl -n $NS wait --for=delete pod -l app=esphome --timeout=150s
kubectl -n $NS delete pvc $PVC
kubectl delete pv $PV
kubectl apply -f manifests/helm-controller-charts/esphome.yaml   # recreates the PV only
kubectl -n $NS delete job helm-install-esphome                   # forces PVC recreation
kubectl -n $NS rollout status deploy/$DEPLOY
```

Helm restores the replica count itself, so no scale-up is needed.

### Pattern A2 — PV *and* PVC in the manifest
`jellyfin` only. No helm job to delete; scale back up by hand.

```sh
kubectl -n jellyfin scale deploy/jellyfin --replicas=0
kubectl -n jellyfin wait --for=delete pod -l app.kubernetes.io/name=jellyfin --timeout=150s
kubectl -n jellyfin delete pvc jellyfin-config-pvc jellyfin-media-pvc
kubectl delete pv jellyfin-config-pv jellyfin-media-pv
kubectl apply -f manifests/helm-controller-charts/jellyfin.yaml
kubectl -n jellyfin scale deploy/jellyfin --replicas=1
```

`mosquitto`'s PV is `mosquitto-data-pv`, not `mosquitto-pv`.

### Pattern B — PV created by the chart
`deluge`, `navidrome`, `prowlarr`, `radarr`, `sonarr`

Editing `valuesContent` is what re-triggers helm-controller, so delete the volumes *first*,
then apply — otherwise the helm upgrade fails on the immutable PV.

```sh
NS=media-stack APP=sonarr
kubectl -n $NS scale deploy/$APP --replicas=0
kubectl -n $NS wait --for=delete pod -l app=$APP --timeout=120s
kubectl -n $NS delete pvc ${APP}-config-pvc ${APP}-media-pvc
kubectl delete pv ${APP}-config-pv ${APP}-media-pv
kubectl apply -f manifests/helm-controller-charts/${APP}.yaml
kubectl -n $NS rollout status deploy/$APP --timeout=300s
```

Config-only (no `-media` pair): `prowlarr`. Deluge uses `-config`/`-downloads`;
navidrome uses `-data`/`-music` in namespace `navidrome`.

### Pattern C — inline pod volume, no PV
`homeassistant` mounts NFS directly in the pod spec (`storage.server`). No PV work:

```sh
kubectl apply -f manifests/helm-controller-charts/homeassistant.yaml
kubectl -n homeassistant rollout status deploy/homeassistant
```

`homeassistant` is hardware-pinned: a **required** node affinity on `skyconnect-dongle=true`
plus a `/dev/ttyUSB0` hostPath for the SkyConnect Zigbee stick. It can only run on
kube-captain — never try to drain it onto kube-worker to clean up a mount.

### Verify after each service

```sh
kubectl -n $NS exec deploy/$APP -- stat -f /config    # or the chart's mountPath
kubectl get pv | grep -v Bound                        # expect no output
mount | grep 10.0.40.201                              # on kube-captain, via ssh
```

### Frigate

Removed 2026-09-01. It never ran in k8s — it was a docker-compose stack on `overwatcher`
(RPi 4, `10.0.10.128`), and its ports were already closed. `ansible/playbooks/frigate/` and
the `overwatcher` inventory entry are gone. The Pi itself was left untouched.

## Phase 2 — publish charts, then drop the dead cert config — **DONE 2026-09-02**

All ten cloudflare-tunnel ingresses now render with no `tls:` block and no
`cert-manager.io/cluster-issuer`; their Certificates and TLS secrets are deleted and
ingress-shim does not recreate them. Every service still answers over HTTPS, and the edge
serves `CN=jehli.net` issued by Google Trust Services — Cloudflare's own certificate, which
was never connected to the cert-manager ones.

Three traps worth remembering, all hit during this run:

- **A chart edit without a version bump breaks the whole release pipeline.** mosquitto was
  changed (a comment) but left at 0.2.0, and chart-releaser died on it:
  `422 Validation Failed [{Resource:Release Field:tag_name Code:already_exists}]`. That
  aborted the run after 5 releases and before `cr index`, so five charts were released but
  unindexed and five were never reached. Consider adding `skip_existing: true` to
  `.github/workflows/helm-release.yaml` to make the pipeline idempotent.
- **chart-releaser only processes charts changed in the triggering push.** Fixing mosquitto
  and pushing again republished *only* mosquitto. Recovering the rest meant uploading the
  missing releases and rebuilding `index.yaml` by hand with `cr`.
- **`helm repo update` can return a cached index.** It reported success while still serving
  a stale 15 KB index, so every `helm show chart` failed with "not found in index" even
  though GitHub Pages was serving the correct 19 KB file. Delete
  `~/Library/Caches/helm/repository/<repo>-index.yaml` if versions look missing.

## Phase 2 — the procedure that was used

Phase 1 works against the **currently published** chart versions. The cert-manager cleanup
needs a chart release first, so do it second.

1. Merge the bumped charts to `main`. `.github/workflows/helm-release.yaml` runs
   chart-releaser on any push touching `helm/**`, so the tags and `.tgz` releases are
   created for you — no manual tagging. Confirm each version appears in
   `https://ddx32.github.io/homelab/index.yaml` before step 2.

   | chart | new version |
   |---|---|
   | adminer | 0.1.2 |
   | deluge | 0.1.3 |
   | esphome | 0.1.4 |
   | homebridge | 0.2.2 |
   | navidrome | 0.1.4 |
   | nginx-proxy | 0.1.3 |
   | prowlarr | 0.1.1 |
   | radarr | 0.1.1 |
   | sonarr | 0.1.1 |

2. Only after the release is live, bump the version in each HelmChart CR and apply:

   ```sh
   sed -i '' 's/^  version: 0.1.0$/  version: 0.1.1/' manifests/helm-controller-charts/sonarr.yaml
   kubectl apply -f manifests/helm-controller-charts/sonarr.yaml
   ```

3. Then remove the orphaned Certificates, which will no longer be recreated:

   ```sh
   kubectl delete certificate -n homeassistant esphome-cert homebridge-tls
   kubectl delete certificate -n homelab-services adminer-cert dobby-robot-cert openmediavault-cert
   kubectl delete certificate -n media-stack deluge-cert prowlarr-cert radarr-cert sonarr-cert
   kubectl delete certificate -n navidrome navidrome-cert
   ```

   Do this only *after* step 2 has rolled out. While the annotation is still on the ingress,
   cert-manager's ingress-shim recreates each Certificate as fast as you delete it.

   cert-manager deliberately leaves the TLS `Secret` behind when a `Certificate` is deleted,
   so remove those too (same names, same namespaces). Check nothing references them first —
   by this point no ingress should.

   Note these Certificates had gone `Ready=True` shortly before deletion: retargeting the
   ClusterIssuer solver to `jehli.net` finally let them issue, after years of failing. They
   were still unused, since TLS terminates at Cloudflare.

### Still outstanding after Phase 2

`cert-manager/le-test-cdglan-org` is still `Ready=False` and cannot ever issue — it is
hardcoded to `le-test.cdglan.org` in `helm/cert-manager/templates/test-certificate.yaml`,
and that domain is not in Cloudflare. Either point it at a `jehli.net` name or drop the
template; it needs a chart version bump either way. The three `monitoring` Certificates were
deliberately left alone.

## Phase 3 — retire cdglan.org

Not started; these are still on `cdglan.org` and were deliberately left alone:

| ingress | class | note |
|---|---|---|
| `monitoring/kube-prometheus-stack-grafana` | *(none)* | no `ingressClassName` — **no controller serves it** |
| `monitoring/…-prometheus` | *(none)* | same |
| `monitoring/…-alertmanager` | *(none)* | same |

The three monitoring ingresses have never worked; they are declared in
`manifests/helm-controller-charts/kube-prometheus-stack.yaml`.

`default/homer` used to be the fourth entry here. It was torn down on 2026-09-01 — it was the
only `nginx`-class Ingress, so `ingress-nginx` now has zero consumers (see the note in
`manifests/helm-controller-charts/nginx-ingress-controller.yaml`).

Remaining cdglan.org tail:

- `manifests/helm-controller-charts/bind.yaml` still serves the `cdglan.org` zone
  (`ns`, `omv`, `grafana`, `prometheus`, `homeassistant`, `adminer`, `deluge`, `esphome`,
  `homebridge` — the `homer` record was removed with the teardown). Once Phase 1 lands,
  nothing in k8s depends on `omv.cdglan.org`.
- The router at `192.168.0.1` forwards `cdglan.org` → bind (its SOA serial `2023120512`
  matches `bind.yaml`). That forward rule is the last thing to remove, and it is web-UI only
  — no SSH.
- `kube-captain:/etc/hosts` still has `127.0.1.1 kube-captain.cdglan.org`.

## Teardown: homer and frigate (done 2026-09-01)

**homer** — `helm uninstall homer -n default` removed the deployment, service, ingress, all
five replicasets and the Certificate; the leftover `homer-cert` TLS secret was deleted by
hand (cert-manager owned it, not helm). Cluster is clean. Removed from the repo:
`helm/homer/`, `container-images/homer/`, `manifests/helm-controller-charts/homer.yaml`,
the `homer` A record in `bind.yaml`, and `.github/workflows/main.yml` — that workflow built
*only* the homer image, so with `container-images/` empty it would have failed on every push.

This discarded an in-progress homer migration (upstream `b4bz/homer` image, parameterized
`ingressClassName`, a HelmChart CR targeting `jehli.net` on cloudflare-tunnel), retired by
explicit decision.

**frigate** — never ran in k8s. Removed `ansible/playbooks/frigate/` and the `overwatcher`
host from `ansible/inventory.yaml`. The Pi at `10.0.10.128` was left running and untouched;
if you want it wiped, that is still outstanding.

## Rollback

Phase 1 is reversible per service: `git checkout` the manifest, delete the PVC/PV, re-apply.
Data is untouched throughout because every PV is `Retain` — the NFS export is never written
to by these steps.

## Found during the Phase 1 cutover

**mosquitto persistence has never worked.** The chart provisions `mosquitto-pvc` /
`mosquitto-data-pv`, but the deployment mounts only an `emptyDir` and the config
ConfigMap — the PVC is never referenced by any container. `/export/ssd-data/mosquitto/data`
on the NAS has been empty since Feb 2026, and `mosquitto.db` lives in container-local
storage, so it is discarded on every restart. Nothing was lost in the cutover (there was
nothing on NFS to lose), but the PV/PVC pair is dead weight and the broker has no retained
state across restarts. Fix in the chart's `deployment.yaml` if persistence is wanted.

**Pods relocate to kube-worker.** Most of these workloads had never run anywhere but
kube-captain; scaling to zero let the scheduler place them on kube-worker, which had never
mounted NFS before (it installed `rpc-statd` on first mount). This is fine, but it means
kube-worker is now on the NAS's critical path too.

## Unrelated issues found on 2026-09-01

- No UPS monitoring on `pve` (`nut-monitor` and `apcupsd` both inactive). Both hosts lost
  power at 20:38 after being wedged since ~04:56.
- Consider `soft`/`softreloc` NFS mounts so a NAS stall degrades pods instead of wedging the
  node in uninterruptible sleep.
- `dobby-robot` has 10011 restarts, `openmediavault` 2341 — both currently Running, both
  likely liveness-probe casualties of NFS stalls. Not investigated.
