# Ansible

Run everything from this directory; `ansible.cfg` points at `inventory.yaml` and connects
as `jsolon` with `~/.ssh/id_rsa`, using `sudo` on the far side.

## Patching: `playbooks/packages.yaml`

```sh
cd ansible && ansible-playbook playbooks/packages.yaml
```

`apt full-upgrade` on every host in `jehlinet_hosts` and `jehlinet_vms`, **one host at a
time, in inventory order**: the hypervisors (pve, holly) first, then the VMs. Running guests
are not touched by a hypervisor's package upgrade; they keep their QEMU process until their
next restart.

It **never reboots**. Each host ends with `REBOOT NEEDED (running <kernel>)` when it needs
one. Proxmox kernels never write `/var/run/reboot-required`, so the check also compares the
running kernel with the newest `/boot/vmlinuz-*`. Reboots are by hand because of what they
take down:

| Rebooting | Takes down |
|---|---|
| pve | kube-captain (control plane, Home Assistant), librarian (HA's DB), tailscale |
| holly | **omv, so all NFS storage for the cluster**, kube-worker, tailscale2 |

With two Proxmox nodes, whichever one stays up loses quorum until the other is back:
running guests keep running, but nothing can be started, stopped or reconfigured. Reboot
one node at a time and wait for `pvecm status` to show `Quorate: Yes` before the next.

Unreachable hosts are skipped, not fatal (`ignore_unreachable`), so one dead host does not
stop the run.

### Not covered

- **The tailscale LXCs** (105 on pve, 106 on holly) run no reachable sshd. Patch them from
  their host, one at a time so a subnet router stays up:
  `pct exec 106 -- sh -c 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade'`
- **printer-buddy** (vlan20) is not reachable over SSH from vlan10 and gets skipped.
- **Major releases** (Debian 12→13, Proxmox VE 8→9, OMV 6→7) are not routine patching. Do
  them by hand, per host, following the upstream guide; see `../SERVERS.md`.

## Host keys

`host_key_checking` is on (the default). A changed key stops the run for that host
instead of being silently accepted. Verify the new key out-of-band before replacing it in
`~/.ssh/known_hosts`:

- k3s nodes: through the Kubernetes API, e.g.
  `kubectl debug node/kube-worker --image=busybox --profile=general -- cat /host/etc/ssh/ssh_host_ed25519_key.pub`,
  then `ssh-keygen -lf` on the output and compare with `ssh-keyscan`.
- Other VMs: `qm guest exec <vmid> -- cat /etc/ssh/ssh_host_ed25519_key.pub` from the
  hypervisor, if the guest agent runs.

The cloud-init VMs (cloned from the Debian templates) **regenerate their host keys whenever
Proxmox's cloud-init instance-id changes**, which happens when the VM's cloud-init settings
change. kube-worker's key changed this way on 2026-11-10; it now has
`/etc/cloud/cloud.cfg.d/99-keep-host-keys.cfg` (`ssh_deletekeys: false`). Add the same to new
clones of template 9002.
