#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Fetch the posted "Add spi-hid transport driver" series (v4, 9 June 2026: Jarrett Schultz,
# Angela Czubak, Dmitry Antipov, Jingyuan Liang; not in mainline yet) and unpack only the files
# under drivers/hid/spi-hid/ into src/, so it can be built out of tree with DKMS.
#
# The patches are taken from a pinned commit of omarchy-pkgs, which carries the series unchanged
# as patches 2110-2120 (lore.kernel.org has no stable per-patch URL). Every file is checked
# against patches.sha256. Patches 2110 (documentation), 2111 (BUS_SPI name in hid-core +
# HID_SPI_DEVICE macro, replaced by compat.h) and 2118 (DT binding) are not needed out of tree.
#
# Usage: bash drivers/spi-hid/prepare.sh [--offline DIR]   (DIR: the .patch files, already downloaded)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
COMMIT=b3c3d6d656ea553bef1ca05273cab85864c929bb
BASE="https://raw.githubusercontent.com/omacom/omarchy-pkgs/$COMMIT/pkgbuilds/linux-omarchy-aarch64"
CACHE="$HERE/.patches"
command -v filterdiff >/dev/null || { echo "filterdiff missing: apt install patchutils"; exit 1; }

mkdir -p "$CACHE"
if [ "${1:-}" = --offline ]; then
	cp "${2:?directory with the patches}"/21*.patch "$CACHE"/
fi
while read -r sum name; do
	[ -f "$CACHE/$name" ] || curl -fsSL --retry 3 "$BASE/$name" -o "$CACHE/$name"
done < "$HERE/patches.sha256"
(cd "$CACHE" && sha256sum -c --quiet "$HERE/patches.sha256") || { echo "checksum mismatch - not building"; exit 1; }

rm -rf "$HERE/src.tmp"; mkdir -p "$HERE/src.tmp"
while read -r sum name; do
	filterdiff -i '*drivers/hid/spi-hid/*' "$CACHE/$name" |
		(cd "$HERE/src.tmp" && patch -p1 -s --no-backup-if-mismatch)
done < "$HERE/patches.sha256"
rm -rf "$HERE/src"
mv "$HERE/src.tmp/drivers/hid/spi-hid" "$HERE/src"
rm -rf "$HERE/src.tmp"
# the series' own Kbuild file is replaced by ../Makefile
mv "$HERE/src/Makefile" "$HERE/src/Makefile.series"
rm -f "$HERE/src/Kconfig"
echo "spi-hid sources ready in $HERE/src ($(ls "$HERE/src" | tr '\n' ' '))"
