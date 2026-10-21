#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - step 8: webcam anti-flicker 50 Hz
#
# The FHD webcam (uvcvideo, no extra driver needed) defaults to a 60 Hz power-line filter, which
# causes banding under artificial light on 50 Hz mains. Skip this step on 60 Hz mains.
# Remove: rm /etc/udev/rules.d/70-proart-webcam.rules
# Run with: sudo bash install/08-camera.sh
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_root

apt-get install -y v4l-utils >/dev/null
install -m 644 "$REPO/config/udev/70-proart-webcam.rules" /etc/udev/rules.d/70-proart-webcam.rules
udevadm control --reload
udevadm trigger --action=add --subsystem-match=video4linux
for d in /dev/v4l/by-path/*usb-0:1:1.0-video-index0; do
	[ -e "$d" ] && v4l2-ctl -d "$d" -C power_line_frequency
done
echo "Done: webcam anti-flicker set to 50 Hz permanently."
