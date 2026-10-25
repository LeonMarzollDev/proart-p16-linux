#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - step 15 (optional, EXPERIMENTAL): tell the firmware about s2idle
# (proart_s2idle, DKMS)
#
# Windows evaluates the Microsoft Modern Standby _DSM (11e00d56-...) of \_SB.PEPD (PNP0D80) when it
# turns the display off and enters/leaves Modern Standby; the AML forwards each step to the ASUS EC
# (0xb7/0x9a/0xae on entry, 0xaf/0x9b/0xb8 on exit). Linux only does this on x86
# (drivers/acpi/x86/s2idle.c), so on this laptop the EC never learns that the system sleeps and the
# fans keep running (~11 W asleep). proart_s2idle calls the same _DSM functions in the noirq phase
# of suspend-to-idle. Known risk (seen when proart_battery sent the raw EC commands): the EC may then
# cut the audio codecs' power - check speakers/microphone after a long sleep; options to narrow it
# down are in config/modprobe.d/proart-s2idle.conf and drivers/proart-s2idle/README.md.
# Remove: modprobe -r proart_s2idle; dkms remove proart-s2idle/<version> --all;
#         rm -rf /usr/src/proart-s2idle-* /etc/modules-load.d/proart-s2idle.conf \
#         /etc/modprobe.d/proart-s2idle.conf
# Run with: sudo bash install/15-s2idle.sh
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_root
KREL=$(uname -r)
D="$REPO/drivers/proart-s2idle"
VER=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$D/dkms.conf")
SRC=/usr/src/proart-s2idle-$VER

echo "== 1/3 Build tools"
apt_update
apt-get install -y dkms build-essential

echo "== 2/3 Remove older versions, build and install $VER for $KREL"
for old in $(dkms status proart-s2idle 2>/dev/null | sed -n 's#^proart-s2idle/\([^,]*\),.*#\1#p' | sort -u); do
	dkms remove "proart-s2idle/$old" --all || true
done
rm -rf /usr/src/proart-s2idle-*
install -d "$SRC"
install -m 644 "$D"/{proart_s2idle.c,Makefile,dkms.conf} "$SRC/"
dkms add "proart-s2idle/$VER"
dkms build "proart-s2idle/$VER" -k "$KREL"
dkms install "proart-s2idle/$VER" -k "$KREL"
echo proart_s2idle > /etc/modules-load.d/proart-s2idle.conf
[ -e /etc/modprobe.d/proart-s2idle.conf ] ||
	install -m 644 "$REPO/config/modprobe.d/proart-s2idle.conf" /etc/modprobe.d/

echo "== 3/3 Load"
modprobe -r proart_s2idle 2>/dev/null || true
modprobe proart_s2idle
dmesg | grep proart_s2idle | tail -3
echo "mem_sleep: $(cat /sys/power/mem_sleep)"
echo
echo "Done. Test: sudo bash $D/test-s2idle.sh 120   (sleeps 120 s, reports the average power)"
