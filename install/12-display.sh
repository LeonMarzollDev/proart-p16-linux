#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - step 12 (optional): OLED panel colour profile, brightness and HDR checks
#
# Panel: Samsung SDC 0x4235 "ATNA60HC05-0", eDP, 3840x2400, 10 bpc, 30-120 Hz adaptive sync (EDID
# range descriptor, AMD VSDB and DisplayID adaptive-sync block), HDR static metadata (BT.2020,
# 1600 cd/m2 peak, 700 cd/m2 full field), DisplayHDR True Black 1400, 100 % DCI-P3.
# ASUS ships factory colour profiles per panel ID in its Windows display/ProArt package:
#   C:\Windows\System32\spool\drivers\color\AsusICM\H7607BA_10DE_834C4235.icm        (native gamut)
#   C:\Windows\System32\spool\drivers\color\H7607BA_10DE_834C4235_CMDEF.icm          (Windows default)
#   ...\AsusICM\ASUS_sRGB.icm / ASUS_DisplayP3.icm / ASUS_DCIP3.icm                    (gamut modes)
# They are ASUS files and not part of this repository. This step copies them from a mounted Windows
# partition (or a folder you give it) to /usr/share/color/icc/asus-proart-p16/, where colord sees
# them; user/bin/proart-icc then assigns one to the internal panel for your user (GNOME Settings >
# Color shows the same list). Panel IDs other than 834C4235 (other panel lots) are matched by EDID.
#
# Usage: sudo bash install/12-display.sh [DIR-with-icm-files]
#        (default: search /media, /mnt and /run/media for Windows/System32/spool/drivers/color)
# Remove: rm -rf /usr/share/color/icc/asus-proart-p16; per user: colormgr device-remove-profile ...
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_root
DEST=/usr/share/color/icc/asus-proart-p16

echo "== 1/4 Internal panel"
EDID=""
for c in /sys/class/drm/card*-eDP-*; do
	[ -s "$c/edid" ] && EDID="$c/edid" && break
done
PANEL=""
if [ -n "$EDID" ]; then
	# EDID bytes 8-11: manufacturer + product code; ASUS names its profiles 834C<product>
	PANEL=$(od -An -tx1 -j8 -N4 "$EDID" | awk '{printf "%s%s%s%s", toupper($2), toupper($1), toupper($4), toupper($3)}')
	echo "eDP EDID $EDID -> ASUS panel id $PANEL ($(strings "$EDID" | grep -m1 ATNA || echo unknown model))"
else
	echo "No eDP connector with an EDID (is nvidia-drm loaded? install/02-nvidia.sh)"
fi
PANEL=${PANEL:-834C4235}

echo "== 2/4 Find the ASUS profiles"
SRCDIR="${1:-}"
if [ -z "$SRCDIR" ]; then
	SRCDIR=$(find /media /mnt /run/media -maxdepth 6 -type d -ipath '*windows/system32/spool/drivers/color' 2>/dev/null | head -1 || true)
fi
if [ -z "$SRCDIR" ] || [ ! -d "$SRCDIR" ]; then
	echo "No profile folder found. Mount the Windows partition (read-only is enough:"
	echo "  sudo mount -o ro /dev/nvme0n1pX /mnt) or copy the .icm files somewhere, then run:"
	echo "  sudo bash install/12-display.sh /path/to/folder"
	exit 0
fi
mapfile -t files < <(find "$SRCDIR" -maxdepth 2 -type f \( -iname "H7607BA_*_${PANEL}*.icm" -o -iname 'ASUS_sRGB.icm' \
	-o -iname 'ASUS_DisplayP3.icm' -o -iname 'ASUS_DCIP3.icm' \) | sort)
[ ${#files[@]} -gt 0 ] || { echo "No H7607BA profiles for panel $PANEL in $SRCDIR"; exit 1; }

echo "== 3/4 Install them for colord"
apt-get install -y colord >/dev/null
install -d "$DEST"
for f in "${files[@]}"; do
	install -m 644 "$f" "$DEST/$(basename "$f")"
	echo "  $(basename "$f")"
done
systemctl restart colord 2>/dev/null || true

echo "== 4/4 Brightness / HDR / VRR (report only)"
bl=$(ls /sys/class/backlight 2>/dev/null | head -1)
if [ -n "$bl" ]; then
	echo "backlight $bl: $(cat /sys/class/backlight/$bl/brightness)/$(cat /sys/class/backlight/$bl/max_brightness) (type $(cat /sys/class/backlight/$bl/type))"
else
	echo "Warning: no /sys/class/backlight device - the brightness slider will not work."
	echo "         OLED brightness goes through the eDP AUX channel (nvidia-drm); see docs/hardware-extra.md."
fi
echo "nvidia-drm modeset=$(cat /sys/module/nvidia_drm/parameters/modeset 2>/dev/null || echo ?)"
command -v gdctl >/dev/null && gdctl show 2>/dev/null | grep -iE 'eDP|color mode|bt2100|refresh rate mode|variable' | head -8 || true

echo
echo "Done. As your user: user/bin/proart-icc            (list profiles, assign the native one)"
echo "                    user/bin/proart-icc ASUS_sRGB  (sRGB emulation profile, e.g. for web work)"
