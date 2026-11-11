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

**Nightly job** (Datacenter → Backup): every guest except template 9001, daily 02:30,
snapshot mode, zstd, to `nas-backup`. A full run is ~28 GB and ~12 min; the storage's
retention prunes old ones. Failures go to `root@pam` (`f@filipruzicka.com`) through pve's
local mailer; delivery confirmed working without a relay.

Before the 2026-11-10/11 upgrades, one-off backups were taken (`pre-PVE9`, `pre-OMV7`,
`pre-OMV8` in the notes); holly's are also copied to pve's `/var/lib/vz/dump/from-holly/`,
because the NAS runs on holly. Delete that copy once the nightly job has run for a while.

**App data: `ssd-data` → RAID, daily snapshots.** Every app's config (Home Assistant,
Jellyfin, the *arr apps, Mosquitto, …) lives on `/export/ssd-data`: one SSD, no redundancy,
and not in any VM backup since the apps reach it over NFS. OMV scheduled task
**"ssd-data snapshot"** (System → Scheduled Tasks, daily 03:30, root) runs
`/usr/local/sbin/ssd-data-snapshot` on omv:

- `rsync -aHAX --delete --link-dest=latest` into shared folder `ssd-data-backup` on the RAID
  (root-only, not exported), one directory per day, 14 kept.
- Unchanged files are hard links into the previous day, so a day costs only what changed
  (~110 MB against 2.8 GB on the first test).
- Built as `<date>.partial` and renamed when complete; retention goes by directory name,
  because `rsync -a` copies the source's mtimes.
- Not an OMV rsync job on purpose: those keep a single mirror, which would copy an accidental
  deletion or a corrupted database over the only backup the next night.
- Live SQLite databases (Jellyfin, the *arr apps) are copied while in use, so a snapshot of
  one may need the app's own repair on restore. The *arr apps also keep their own backups
  under `config/Backups`, which land in the snapshots too.

Restore a file: copy it back from
`/srv/dev-disk-by-uuid-c2946330-0a87-4820-b505-4af86d6196b1/ssd-data-backup/<date>/` with the
app stopped.

## To do

1. **Email from OMV.** Notifications are not configured there (System → Notification), so a
   failing `ssd-data snapshot` task mails `root` on omv and nobody sees it.
2. **Off-site copy.** Everything above is in one house, mostly on holly. A weekly encrypted
   `rclone` sync of `pve-backups`, the `ssd-data` copies and the family `backups` share to
   Backblaze B2 or a Hetzner Storage Box covers fire, theft and ransomware.
3. **Test a restore** every few months; a backup nobody has restored is a guess.

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
