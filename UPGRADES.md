# Upgrades

Everything that needs updating, how, and what bit last time. Versions are as of
2026-11-11, when the whole stack was brought current. Start every round with

```sh
cd ansible && ansible-playbook playbooks/versions.yaml
```

## Surface

| Component | Current | How to upgrade |
|---|---|---|
| Debian packages: pve, holly, VMs, LXCs | Debian 13 everywhere | `ansible-playbook playbooks/packages.yaml` (see [ansible/README.md](ansible/README.md)) |
| Proxmox VE (pve, holly) | 9.2, kernel 7.0 | minor: the packages playbook. Major: by hand, see below |
| Debian release, VMs and LXCs | 13 (trixie) | by hand, see below |
| k3s | v1.37.2+k3s1 | `ansible-playbook playbooks/k3s/k3s-upgrade.yaml -e k3s_version=…` |
| Helm charts and images | `manifests/helm-controller-charts/`, pinned | edit the version/tag, `kubectl apply -f`, wait for the helm job |
| OpenMediaVault (omv) | 8.6 (Debian 13) | minor: packages playbook. Major: `omv-release-upgrade`, see below |
| MariaDB (librarian) | 11.8 | follows Debian; dump first (`mariadb-dump --all-databases --single-transaction`) |
| Home Assistant | image tag in `homeassistant.yaml` | tag bump like any chart; read the release notes' breaking changes |
| Template 9002 | Debian 13 generic cloud image | rebuild from a new image (SHA512-verify it), keep the settings |
| MikroTik router, switch, AP | RouterOS + firmware 7.25.1 | by hand, see below |
| printer-buddy (RPi) | unknown, unreachable over SSH from vlan10 | on the device |

Check upstream: k3s `curl -s https://update.k3s.io/v1-release/channels`, RouterOS
`/system package update check-for-updates`, Proxmox/OMV/Debian release pages.

## Before anything that reboots or migrates

- **Back up first.** `vzdump <vmid> --storage nas-backup --mode snapshot` (guests stay up);
  for a database, also a logical dump. See [BACKUPS.md](BACKUPS.md).
- **Record a baseline**: the public hostnames' HTTP codes, `kubectl get pods -A`, and for omv
  its exports, shares, mounts and RAID state. Compare after; "it booted" is not the check.
- Know what a reboot takes down (table in [ansible/README.md](ansible/README.md)): holly
  carries the NAS, so everything stalls with it.

## Procedures

**Proxmox major (done 8 → 9):** prep with no downtime (`pve8to9 --full` to 0 failures:
remove `systemd-boot`, `grub-efi-amd64` with `force_efi_extra_removable`, `intel-microcode`,
NIC names pinned by `.link` files), then per node: shut the guests down, switch repos (the
Debian security suite moves to `…/debian-security <suite>-security`), `dist-upgrade` inside
`systemd-run` so a dropped SSH session cannot kill it, reboot, check quorum, guests, chrony.
Notes in [SERVERS.md](SERVERS.md).

**Debian release, VMs and LXCs:** back up, drain if it is a k3s node, switch repos (deb822
`debian.sources` on the cloud VMs, `sources.list` elsewhere), `full-upgrade` with
`--force-confdef --force-confold` inside `systemd-run`, reboot, uncordon. LXCs: from the host
with `pct exec`, the tailscale pair one at a time (the other keeps the routes).

**OMV major (done 6 → 7 → 8):** one major per step. `omv-release-upgrade` prompts through
whiptail, so run it in `tmux` and answer with `tmux send-keys` (or attach). Afterwards test a
**login**, not just the shares.

**MikroTik:** per device `/system package update download` + `install` (reboots), then
`/system routerboard upgrade` + `/system reboot`. Order AP → switch → router. The CRS310
forwards traffic well before it accepts SSH again (~8 min); do not conclude it is dead.
Refresh `network/*.export.rsc` with `network/refresh-exports.sh` afterwards.

## What bit last time

| Symptom | Cause | Fix now in place |
|---|---|---|
| A VM silent to vlan10 mid-upgrade, fine from vlan40 | the `10.0.10.0/24 via 10.0.40.2` route was a boot-time `ip route`; restarting networking flushed it | route in persistent config on every vlan40 host (table in SERVERS.md) |
| omv silent to vlan10 after OMV 7 | OMV started writing the network config (netplan) and dropped the route | `/etc/netplan/90-local-routes.yaml`, which OMV does not manage |
| No pve guest starts on kernel 7.0 (`RTNETLINK … error 524`) | netconsole bound to `vmbr0.40` refuses non-netpoll bridge ports | `netconsole-sender.service` disabled |
| `qm shutdown` of omv times out | OMV power button set to "Nothing" | set to Shutdown, guest agent enabled |
| kube-captain takes 4.5 min to stop | k3s stopping containers; Proxmox force-stops at 180 s | `startup: down=600` on the k3s VMs |
| OMV 8 web UI: 502 on login | nginx left on PHP 8.2's socket, only 8.4 installed | `omv-salt deploy run phpfpm nginx` |
| HA `400 Bad Request` after cloudflared moved node | HA (hostNetwork) only trusted pod IPs | node IPs in `trusted_proxies` (`.storage/http`) |
| esphome deployed as `2026.1` | unquoted YAML tag `2026.10` read as a float | quote date-like tags |
| SSH host key changed on kube-worker | cloud-init regenerates keys on a new instance-id | `ssh_deletekeys: false` (add to new clones) |
| LXC backups fail on NFS | unprivileged container root cannot write vzdump's temp dir there | `tmpdir: /var/tmp` in `/etc/vzdump.conf` |
| Jellyfin restarts during NAS outages | liveness probe, NFS stalled | none needed: it recovers by itself |
