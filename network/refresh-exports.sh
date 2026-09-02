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

ssh -p 2200 admin@10.0.10.1 '/export' | sanitise > router-rb750gr3.export.rsc
ssh        admin@192.168.0.3 '/export' | sanitise > switch-crs310.export.rsc
ssh        admin@192.168.0.4 '/export' | sanitise > ap-hap-ax-s.export.rsc

grep -rilE 'passphrase|password=|pre-shared|token=[0-9a-f]' ./*.export.rsc \
  && { echo "REFUSING: secret found in export"; exit 1; }
echo "snapshots refreshed, no secrets found"
