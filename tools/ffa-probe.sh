#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - battery/EC diagnosis: drivers/proart-ffa-probe asks the EC services behind
# FF-A directly and logs the raw response registers. Read-only requests; the module does not stay loaded.
# Result: <invoking user's home>/ffa-probe.txt
# Needs the kernel headers (install/01-kernel.sh) and build-essential.
# Run with: sudo bash tools/ffa-probe.sh
set -euo pipefail
. "$(dirname "$0")/../install/lib.sh"
require_root
USERNAME=$(target_user)
OUT="$(user_home "$USERNAME")/ffa-probe.txt"
KREL=$(uname -r)
[ -d "/lib/modules/$KREL/build" ] || { echo "Kernel headers for $KREL missing - run install/01-kernel.sh first"; exit 1; }
command -v make >/dev/null || { apt_update; apt-get install -y build-essential; }

echo "== 1/2 Build the probe module"
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
cp "$REPO"/drivers/proart-ffa-probe/{proart_ffa_probe.c,Makefile} "$BUILD/"
make -C "$BUILD"

echo "== 2/2 Load it once (it intentionally reports 'Resource temporarily unavailable')"
MARK="proart_ffa_probe_start_$(date +%s)"
echo "$MARK" > /dev/kmsg
insmod "$BUILD/proart_ffa_probe.ko" || true
journalctl -k -b --no-pager -o cat | sed -n "/$MARK/,\$p" | grep "proart_ffa" > "$OUT"
chown "$USERNAME:" "$OUT"
cat "$OUT"
