# cdglan.org → jehli.net migration

Status: **All three phases are applied and verified.** All 14 NFS PVs point at
`10.0.40.201`, no ingress carries cert-manager config, and nothing in the cluster serves or
resolves `cdglan.org`.

> **OPEN SECURITY ITEM.** `prometheus.jehli.net` and `alertmanager.jehli.net` are now
> reachable from the internet with **no authentication**. Verified live: an unauthenticated
> `GET /api/v1/query?query=up` returns real metrics, and `GET /api/v2/status` returns the
> Alertmanager config. No credentials are exposed (the config is stock, `api_url` fields are
> null defaults), but metrics reveal internal IPs and Alertmanager's API can create silences.
> **Add Cloudflare Access policies for both hostnames.** Access on `jehli.net` is
> per-application, not a wildcard. To close the hole immediately instead, set
> `enabled: false` on those two ingresses in `kube-prometheus-stack.yaml` and re-apply.

One remaining manual step: **remove the `cdglan.org` forward rule on the router**
(`192.168.0.1`, web UI only). Until then the router keeps answering from cache — the zone's
TTL was 2 days, so it expires on its own. Nothing depends on it either way.

## Why NFS moved to an IP, not a name

`nas.jehli.net` resolves *publicly* to Cloudflare proxy IPs (`188.114.x.x`) — NFS cannot
traverse that. Keeping a DNS name for the NAS would require bind to become authoritative
for `jehli.net` internally, which in turn means every public hostname (jellyfin, ha,
sonarr…) needs a matching internal record or it breaks on the LAN.

The NAS is a fixed LAN appliance at `10.0.40.201`. It gains nothing from DNS indirection,
and a name is what wedged the cluster on 2026-09-01 (hard NFS mounts on an unreachable
`omv.cdglan.org` put the node in permanent D-state for ~15h). All NFS references are now
literal IPs.

## Summary of the change set

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

### Follow-up, resolved in Phase 3

`cert-manager/le-test-cdglan-org` could never issue — hardcoded to `le-test.cdglan.org`,
which is not in Cloudflare. It turned out to be a smoke-test certificate from the original
2023-11-01 setup, pointed at the *staging* issuer and referenced by nothing. Its template was
removed from the chart (`cert-manager-setup` 0.1.4) and the leftover secret deleted.

`skip_existing: true` was also added to `.github/workflows/helm-release.yaml`, so a chart
edited without a version bump no longer aborts the entire release run.

## Phase 3 — retire cdglan.org — **DONE 2026-09-02**

`cdglan.org` is gone from the cluster. What was done:

- **bind removed entirely.** It served exactly one zone, `cdglan.org` (`internal` is an ACL,
  not a zone), and nothing resolved through it — both nodes point at the router. Its only
  remaining purpose was `omv.cdglan.org`, which Phase 1 made obsolete by moving every NFS
  volume to the literal IP. Deleting the HelmChart tore down the deployment, the ConfigMaps
  and the LoadBalancer that had been holding port 53 on both nodes. `manifests/helm-controller-charts/bind.yaml`
  is deleted; `helm/bind` is kept in git so the chart can be redeployed if wanted.
- **Monitoring moved to jehli.net on cloudflare-tunnel.** `grafana`, `prometheus` and
  `alertmanager` now use `ingressClassName: cloudflare-tunnel` and `*.jehli.net`. They had
  never worked because they set the deprecated `kubernetes.io/ingress.class` annotation
  instead of `spec.ingressClassName`, which modern ingress-nginx ignores — so no controller
  ever claimed them. See the security note at the top of this file.
- **All cert-manager Certificates are gone.** Cluster-wide count is now zero, including
  `le-test-cdglan-org` — a smoke-test cert from the original 2023-11-01 setup, pointed at the
  *staging* issuer and referenced by nothing. Its template was removed from the chart.
- **Node hostnames updated.** Both nodes had `127.0.1.1 <node>.cdglan.org`; now
  `<node>.jehli.net`. Backups at `/etc/hosts.bak-cdglan` on each. The `search cdglan.org`
  lines in `resolv.conf` were already commented out.

### Checked before removing the zone

Retiring a DNS zone breaks anything resolving through it, so this was verified first:

- No k8s PV, ingress or pod references `cdglan.org`.
- `pve` and `holly` have no NFS mounts and no `cdglan` in `/etc/fstab`.
- `pve`'s corosync uses literal `ring0_addr: 10.0.10.4/10.0.10.5`, not hostnames —
  `cluster_name: cdglan` is only a label. Cluster stayed Quorate.
- `pve:/etc/hosts` has a static `10.0.10.4 pve.cdglan.org` entry that resolves locally
  regardless of DNS.
- The NAS already identifies as `nas.jehli.net` and has no `cdglan` in its fstab.

### Still on cdglan.org, deliberately

`manifests/helm-controller-charts/mosquitto.yaml` has `passwd: "cdglan:..."`. That is an
**MQTT username**, not a hostname. Renaming it would break every MQTT client — Home
Assistant, ESPHome devices — so it stays.

## Local DNS after bind (added 2026-09-02)

bind is not coming back, but a few hosts still need names on the LAN — the NAS for SMB above
all, since `nas.jehli.net` resolves to Cloudflare and is useless for file protocols.

`manifests/helm-controller-charts/coredns-lan.yaml` deploys CoreDNS in `homelab-services`
serving one zone, `lan.jehli.net`, from a static `hosts` block: nas, pve, holly, both kube
nodes, librarian and printer-buddy. LoadBalancer on `10.0.40.102,10.0.40.104`, 2 replicas so
resolution survives a node drain.

It is **not** a resolver. There is no `forward` plugin and no `kubernetes` plugin, so anything
outside its zone is `REFUSED` — verified against `google.com`, `example.com` and
`nas.jehli.net`. It cannot be used as an open resolver or a DNS amplifier. Clients keep using
the MikroTik for everything else.

Cluster service names are deliberately not served. Every ingress is cloudflare-tunnel with no
LAN address, so a LAN name would resolve to something nothing serves — worse than hairpinning
through Cloudflare. If services are ever also put behind ingress-nginx (still deployed, still
with zero ingresses), add the `k8s_gateway` plugin and it picks them up with no manual records.

### MikroTik wiring — done 2026-09-02

The router is a single MikroTik (RouterOS 7.24) with both `10.0.10.1` and `192.168.0.1` on it;
SSH is on **port 2200**, not 22. Config exports taken before and after.

```
/ip dns static add name=lan.jehli.net type=FWD forward-to=10.0.40.102 match-subdomain=yes
```

**`forward-to` must be a single IP.** A comma-separated list is accepted by the parser but
every query then returns `SERVFAIL` — confirmed by testing. A second entry for `10.0.40.104`
exists but is **disabled**: RouterOS only ever uses the first matching static entry, so it
gives no automatic failover (verified by pointing the primary at a dead IP — queries timed
out rather than falling through). Treat it as a manual switch, not HA.

That means `lan.jehli.net` resolution depends on `kube-captain` being up. If it is down, use
IP addresses, or flip the two entries. Real redundancy would need a floating VIP for the
CoreDNS service rather than k3s servicelb's per-node IPs.

Removed at the same time: four dead `cdglan.org` static entries, one of which was still
active and forwarding `.+\.cdglan\.org` to the deleted bind LoadBalancer. DHCP was handing
out `domain=cdglan.org` as a search domain on vlan10-lab and 192.168.0.0/16 — now
`lan.jehli.net`, which also makes bare `nas` work once clients renew their lease.

- **Tailscale** (not installed anywhere yet): Split DNS, domain `lan.jehli.net`, nameserver
  `10.0.40.102`. Tailnet clients need a route to `10.0.40.0/24`, so either a subnet router or
  put a tailscale node on that subnet.

### Router follow-ups — done 2026-09-02

- **DHCP DNS repointed.** `vlan20-iot` and `vlan40-vms` were handing out `1.1.1.1,8.8.8.8`,
  so anything taking a lease there bypassed the router and could not resolve `lan.jehli.net`.
  Now each hands out its own gateway (`10.0.20.1`, `10.0.40.1`) — verified both answer LAN
  names and recurse to the internet. `vlan30-guest` deliberately still uses public resolvers.
  The firewall `input` chain has no drop rule, so every VLAN can already reach the router's
  DNS; this needed no firewall change.
- **mDNS repeat now includes `vlan40-vms`.** `nas.local` resolves from the lab VLAN and
  `_smb._tcp` advertises as "nas - SMB/CIFS". This is a **cluster-independent** path to the
  NAS: it keeps working when kube-captain is down and `lan.jehli.net` does not.
- **duckdns removed.** A dormant script from a previous config (`run-count=2`,
  `last-started=2023-11-12`, referencing an `interface=MATRIX` that no longer exists) holding
  a live API token. No scheduler or netwatch referenced it. Script deleted; router now has
  zero scripts and zero schedulers, and no `token=` remains in the running config.

  **The token is not revoked by deleting the script.** Rotate or delete it at duckdns.org —
  and note two binary backups on the router's flash predate the removal and will still
  contain it: `flash/Godfrey-20240212-2128.backup` and `flash/auto-before-reset.backup`.

### Router items found but NOT changed

- **`router.lan -> 192.168.88.1`** is leftover MikroTik `defconf`; that address is not in use.

Zone choice: `lan.jehli.net` is a subdomain of a domain you own, so it can never collide with
public DNS, and it does not shadow any Cloudflare record — deliberately *not* overriding
`nas.jehli.net`, which would create split-horizon and bypass Cloudflare Access from the LAN.

## The NAS

Already fully migrated; nothing was needed here:

- The host identifies as `nas.jehli.net`.
- Its web UI is exposed at `nas.jehli.net` **behind Cloudflare Access** (verified: redirects
  to `jehlici.cloudflareaccess.com/.../nas.jehli.net`).
- Only HTTP is exposed. The path is ingress → `openmediavault:9062` → the nginx-proxy pod →
  `10.0.40.201:80`. NFS and SMB are not routed through the tunnel, as intended — use
  Tailscale for those.

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
