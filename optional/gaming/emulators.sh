#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - optional: x86 emulation for games (FEX-Emu, optionally Hangover)
#
# - FEX-Emu from the official PPA (fex-emu-armv8.4, tested 2610): runs x86-64 and 32-bit x86 Linux programs,
#   incl. AVX/AVX2/FMA3/F16C/BMI2 (256-bit ops split in two: the N1X has SVE2 at 128 bit)
# - cabextract (winetricks needs it for the Windows fonts)
# - ntsync kernel module, loaded at every boot: Windows synchronization in the kernel. Without it every wait/event
#   of every Wine thread is a round trip to the (here emulated, single-threaded) wineserver
# - as the desktop user: the FEX x86 Ubuntu 24.04 RootFS (~1.9 GB in ~/.local/share/fex-emu) and the FEX
#   config with thunks, so x86 programs use the arm64 NVIDIA driver for Vulkan/GL (without them: llvmpipe)
# - --hangover: Hangover 11.16 (arm64 Wine that emulates only the Windows code; becomes the system "wine")
# The Steam snap brings its own FEX and does not need this. See docs/gaming.md.
# Remove: apt remove fex-emu-armv8.4 hangover-wine hangover-libarm64ecfex hangover-libwow64fex hangover-wowbox64;
#         add-apt-repository -r ppa:fex-emu/fex; rm -rf ~/.local/share/fex-emu ~/.config/fex-emu ~/.cache/fex-emu;
#         rm /etc/modules-load.d/ntsync.conf
# Run with: sudo bash optional/gaming/emulators.sh [--hangover]
set -euo pipefail
. "$(dirname "$0")/../../install/lib.sh"
require_root
USERNAME=$(target_user)
UHOME=$(user_home "$USERNAME")
HANGOVER_VER=11.16
HANGOVER_TAR=hangover_${HANGOVER_VER}_ubuntu2604_resolute_arm64.tar
HANGOVER_SHA256=bdf7d91d67367a3dc6e856be3c6ab16e8d3b9049e7cd197844df20a7e4b45c52

echo "== 1/3 FEX-Emu (ppa:fex-emu/fex) and cabextract"
add-apt-repository -y ppa:fex-emu/fex
apt_update
apt-get install -y fex-emu-armv8.4 cabextract curl
modprobe ntsync
printf "# Windows NT synchronization in the kernel for Wine/Proton (no wineserver round trips)\nntsync\n" \
	> /etc/modules-load.d/ntsync.conf

echo "== 2/3 RootFS and thunk config for $USERNAME"
CONF="$UHOME/.config/fex-emu"
runuser -u "$USERNAME" -- mkdir -p "$CONF"
install -o "$USERNAME" -g "$USERNAME" -m 644 "$REPO/config/fex-emu/thunks.json" "$CONF/thunks.json"
sed "s|@CONFIG@|$CONF|" "$REPO/config/fex-emu/Config.json.in" > "$CONF/Config.json"
chown "$USERNAME:" "$CONF/Config.json"
if [ ! -d "$UHOME/.local/share/fex-emu/RootFS/Ubuntu_24_04" ]; then
	runuser -u "$USERNAME" -- env HOME="$UHOME" FEXRootFSFetcher -y -x --distro-name=ubuntu \
		--distro-version=24.04 --distro-list-first --force-ui=tty
fi
# FEXRootFSFetcher writes no Config.json; ours (above) names the RootFS
runuser -u "$USERNAME" -- env HOME="$UHOME" FEXBash -c 'uname -m; grep -m1 -o "avx2" /proc/cpuinfo'

echo "== 3/3 Hangover"
if [ "${1:-}" = --hangover ]; then
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT
	curl -fL -o "$tmp/$HANGOVER_TAR" \
		"https://github.com/AndreRH/hangover/releases/download/hangover-$HANGOVER_VER/$HANGOVER_TAR"
	echo "$HANGOVER_SHA256  $tmp/$HANGOVER_TAR" | sha256sum -c -
	tar -xf "$tmp/$HANGOVER_TAR" -C "$tmp"
	apt-get install -y "$tmp"/hangover-*.deb
else
	echo "skipped (add --hangover)"
fi
echo "Done. Test: FEXBash -c 'uname -m'  -> x86_64"
