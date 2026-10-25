#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - optional: patched SoundWire manager (soundwire-mtk) as DKMS module
#
# Builds NVIDIA's drivers/soundwire/mediatek from linux-nvidia (downloaded from NV-Kernels at a
# pinned commit, sha256-checked) with patches/audio/kernel/000[1-4] and installs it to
# /lib/modules/<kernel>/updates/dkms, where it takes precedence over the in-tree module:
#   0001 close the interrupt gate before quiescing a link (Ryan Hughes; omarchy 1034)
#   0002 re-apply the SoundWire pin bias on system resume
#   0003 restart the links on resume through the probe sequence + attach check
#   0004 select the SoundWire bus/PHY clock parents (APLL2) whenever a link clock is enabled
# Target: audio after long s2idle sleeps (research/audio-suspend.md). Only built for
# linux-nvidia 7.0.0-1021..1024 (dkms.conf BUILD_EXCLUSIVE_KERNEL).
# Knobs (no rebuild): /sys/module/soundwire_mtk/parameters/{restart_on_resume,sdw_set_clk_parents,sdw_lp_clk_parents}
# Remove: dkms remove proart-sdw-mtk/1.0 --all; rm -rf /usr/src/proart-sdw-mtk-1.0; update-initramfs -u
# Run with: sudo bash patches/audio/install-sdw-dkms.sh
set -euo pipefail
. "$(dirname "$0")/../../install/lib.sh"
require_root

NAME=proart-sdw-mtk
VER=1.0
COMMIT=4646b8565e0ee1a7739c3920903146fa2f29352f
RAW=https://raw.githubusercontent.com/NVIDIA/NV-Kernels/$COMMIT
SRC=/usr/src/$NAME-$VER
KREL=${KREL:-$(uname -r)}
HERE=$(cd "$(dirname "$0")" && pwd)
SUMS='
5a5d9a835707c199b4d463daf8f45eeb98be787daf0b3c20e5f6c1c8ecd7d56c  drivers/soundwire/mediatek/mt8901-afe-clk.c
94dfebcbb8926525af9525e824f4b05f779a99990a4c2f93b42bea5edb47e68f  drivers/soundwire/mediatek/mt8901-afe-clk.h
65c7fef197e6429b39745c5686f4e1ee7a8e9a5d62dc724125d2988c91c941f0  drivers/soundwire/mediatek/mtk-sdw-chipglue.c
27f66153ede1414f439b4256b8707b203b7ed33950ee2887155d9a5be4ad19ce  drivers/soundwire/mediatek/mtk-sdw-common.h
63ab321028387add5e8fc64e60f667c0ce1011aeea173abca8a71ed12cb1acda  drivers/soundwire/mediatek/mtk-sdw-core.c
e4676f25a3d26b5cc2c9a0666bd0f7f2c608543957b3f912caed96106d834795  drivers/soundwire/mediatek/mtk-sdw-core.h
c482e36577d72c02f1eb713e39e8711aa0093cd92cdf7ee9c88d122e80ab68fe  drivers/soundwire/mediatek/mtk-sdw-mach.c
6a1c67da7a0ea0be4cb25270e8aafb5d5779bd56d8f1237f25b8813206ffdc5b  drivers/soundwire/mediatek/mtk-sdw-mach.h
fef501d26dd8394bca825b110d0506417bf11177fbba103134c776bd65c13129  drivers/soundwire/mediatek/mtk-sdw-top.c
a92d60aa4b3406f923f18d3fe9b6deab65fac08c52fe21318ccc7f424de95d5a  drivers/soundwire/mediatek/mtk-sdw-top.h
7bc9a0b5bc7dae9ff3c38d4e0cf510fea774cc968f6d3a128110c6a083fdec5b  drivers/soundwire/mediatek/mtk-sdw.c
893dbd1ade2c51cafea3d0640236aaeaf14cd878c3ac8769fed2f5104a2a7766  drivers/soundwire/mediatek/mtk-sdw.h
c25915dc7b0b0357fd1260229b246c5edbf904e3f956bf8f5d7aa1473fe25663  drivers/soundwire/bus.h
'

[[ "$KREL" =~ ^7\.0\.0-102[1-4]-nvidia ]] ||
	{ echo "Kernel $KREL: not a linux-nvidia 7.0.0-1021..1024 kernel; this module was checked only against those."; exit 1; }
[ -d "/lib/modules/$KREL/build" ] || apt-get install -y "linux-headers-$KREL"
apt-get install -y curl dkms patch

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
echo "== Source (NV-Kernels $COMMIT)"
while read -r sum path; do
	[ -n "$path" ] || continue
	mkdir -p "$WORK/src/$(dirname "$path")"
	curl -fsSL --retry 3 -o "$WORK/src/$path" "$RAW/$path"
	echo "$sum  $WORK/src/$path" | sha256sum -c --quiet -
done <<< "$SUMS"

echo "== Patches"
for p in "$HERE"/kernel/000[1-4]-*.patch; do
	echo "  $(basename "$p")"
	patch -d "$WORK/src" -p1 --quiet --forward < "$p"
done
install -m 644 "$HERE/dkms/Kbuild" "$WORK/src/drivers/soundwire/mediatek/Kbuild"
rm -f "$WORK/src/drivers/soundwire/mediatek/Makefile"
install -m 644 "$HERE/dkms/dkms.conf" "$WORK/src/dkms.conf"

echo "== DKMS $NAME/$VER for $KREL"
dkms remove "$NAME/$VER" --all >/dev/null 2>&1 || true
rm -rf "$SRC"
cp -r "$WORK/src" "$SRC"
dkms add "$NAME/$VER"
dkms build "$NAME/$VER" -k "$KREL"
dkms install "$NAME/$VER" -k "$KREL" --force
modinfo -k "$KREL" -n soundwire-mtk
modinfo -k "$KREL" -F parm soundwire-mtk | grep -q sdw_set_clk_parents || { echo "patched module not picked up"; exit 1; }
update-initramfs -u -k "$KREL"
echo "Done. Reboot; then: cat /sys/module/soundwire_mtk/parameters/sdw_set_clk_parents  (Y)"
