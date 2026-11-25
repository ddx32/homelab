# Notes for agents

## Home Assistant config

HA's `/config` is the `ssd-data` share on the NAS: `omv` (`10.0.40.201`),
`/export/ssd-data/homeassistant`. Editing it there is allowed; reach it with
`ssh jsolon@10.0.40.201`. Files under `.storage/` are root-only (`sudo`).

Since 2026.11, HTTP settings (`trusted_proxies` and friends) live in `.storage/http`,
managed in the UI under Settings > System > Network. The `http:` block was removed
from `configuration.yaml`; don't add it back (it is ignored, and an error from
2027.2.0). To edit `.storage/http` by hand, scale the deployment to 0 first, since
HA rewrites `.storage` while running, then scale back to 1.

`trusted_proxies` must include the k3s node IPs (`10.0.40.102`, `10.0.40.104`), not
just the pod CIDR. HA is `hostNetwork`, so when cloudflared runs on the other node its
traffic arrives SNATed to that node's IP and HA answers 400.

## Image upgrades

Pin a chart's image tag in its HelmChart manifest (`valuesContent.imageTag` in
`manifests/helm-controller-charts/`), not in `helm/<chart>/values.yaml`. An upgrade is
then a one-line manifest change plus `kubectl apply`, with no chart version bump or
chart release. Only bump the chart (`version` in `Chart.yaml` and the manifest) when the
templates change. A chart that hardcodes the tag in a template: move it to a value first.
