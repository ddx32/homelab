# Backups

## In place (2026-11-10)

**Target: NFS share `pve-backups` on the NAS RAID** (`omv`, `/dev/md0`, ~16 TB free).
Created through OMV (Storage → Shared Folders, Services → NFS), not by editing
`/etc/exports`, which OMV regenerates. Exported only to the hypervisors' vlan40 addresses,
`10.0.40.4` and `10.0.40.5`, with `no_root_squash`: vzdump writes as root, and limiting the
export to those two keeps root write access away from the VMs and pods on vlan40.

**Proxmox storage `nas-backup`** (cluster-wide, content `backup`), mounted at
`/mnt/pve/nas-backup` on both nodes. Retention on the storage: 7 daily, 4 weekly,
3 monthly.

Two settings it needs:

- **`tmpdir: /var/tmp` in `/etc/vzdump.conf` on both nodes.** Without it, backups of the
  unprivileged tailscale LXCs fail: their mapped root (uid 100000) cannot write vzdump's
  temp directory on NFS (`tar ... failed: exit code 2`).
- **omv's passthrough disks are marked `backup=0`** (`scsi1`–`scsi5`: the 4 × 8 TB RAID
  members and the SSD). Only its 32 GB system disk is backed up; otherwise vzdump would try
  to read ~32 TB.

One full set exists so far: the pre-PVE 9 backups of all six guests, about 28 GB in total.
holly's three are also copied to pve's `/var/lib/vz/dump/from-holly/`, because the NAS
runs on holly.

## To do

1. **Scheduled job.** Datacenter → Backup → Add: storage `nas-backup`, all guests except
   template 9001, daily 02:30, mode snapshot, zstd, notify on failure.
2. **App data on `ssd-data`.** Every app's config (Home Assistant, Jellyfin, the *arr apps,
   Mosquitto, …) lives on `/export/ssd-data`: **one SSD, no redundancy**, and not covered by
   VM backups since the apps reach it over NFS. Add an OMV rsync job (Services → Rsync →
   Jobs) copying it nightly to a folder on the RAID, keeping a few versions.
3. **Off-site copy.** Everything above is in one house, mostly on holly. A weekly encrypted
   `rclone` sync of `pve-backups`, the `ssd-data` copies and the family `backups` share to
   Backblaze B2 or a Hetzner Storage Box covers fire, theft and ransomware.
4. **Test a restore** every few months; a backup nobody has restored is a guess.

## Known limits

- omv's own backup lives on omv's disks. Restoring it means assembling the RAID
  elsewhere first (`mdadm --assemble --scan` works from any Linux, holly included).
- holly's guests are backed up to disks inside holly. The RAID protects against a disk
  failing, not against losing the machine; that is what the off-site copy is for.
- If nightly full backups get slow or large, Proxmox Backup Server adds deduplication and
  incremental backups. Not needed at this size.

## Restoring

```sh
# list what is there
pvesm list nas-backup
# restore a VM to a new ID (keeps the original running)
qmrestore /mnt/pve/nas-backup/dump/vzdump-qemu-<vmid>-<date>.vma.zst <new-vmid> --storage local-lvm
# restore a container
pct restore <new-vmid> /mnt/pve/nas-backup/dump/vzdump-lxc-<vmid>-<date>.tar.zst --storage local-lvm
```

Restoring over the original ID needs `--force`. For omv, re-add the passthrough disks
afterwards: they are not in the backup.
