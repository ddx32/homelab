#!/usr/bin/env bash
# Refresh the committed RouterOS config snapshots.
#
# These replace hand-written config scripts: an export cannot drift, because it
# is the device. Run after changing any MikroTik, then commit the diff.
#
# Sanitising matters - this repo is public. Plain /export already hides
# passphrases, PPPoE passwords and API tokens (verified: `/export
# show-sensitive` reveals 3 passphrase lines, plain /export reveals none).
# What it does NOT hide is the serial number and the PPPoE username, so those
# are stripped here. Never add show-sensitive.
set -euo pipefail
cd "$(dirname "$0")"

sanitise() { sed -E -e '/^# (serial number|software id)/d' -e 's/ user=[^ ]+/ user=<REDACTED>/'; }

# Export to a temp file and only replace the snapshot on success: redirecting straight
# into it truncated the committed file to empty whenever ssh failed (e.g. unknown host key).
trap 'rm -f ./*.export.rsc.tmp' EXIT
export_to() { local out=$1; shift; ssh "$@" '/export' | sanitise > "$out.tmp"; mv "$out.tmp" "$out"; }

export_to router-rb750gr3.export.rsc -p 2200 admin@10.0.10.1
export_to switch-crs310.export.rsc         admin@192.168.0.3
export_to ap-hap-ax-s.export.rsc           admin@192.168.0.4

grep -rilE 'passphrase|password=|pre-shared|token=[0-9a-f]' ./*.export.rsc \
  && { echo "REFUSING: secret found in export"; exit 1; }
echo "snapshots refreshed, no secrets found"
