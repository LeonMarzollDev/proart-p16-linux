#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - optional: NV Broadcast (community project, snap; CPU modes only on arm64)
#
# NVIDIA Broadcast itself is Windows-only. NV Broadcast (github.com/Hkshoonya/nvidia-broadcast-linux,
# publisher WemakeSense/doczeus) offers background blur/replacement, auto framing, mic noise removal.
# The virtual camera needs v4l2loopback (DKMS; kernel headers come from install/01-kernel.sh).
# The snap's camera and microphone plugs are not auto-connected; this script connects them.
# Remove: snap remove nvbroadcast; apt remove v4l2loopback-dkms; \
#         rm /etc/modprobe.d/nvbroadcast-v4l2loopback.conf /etc/modules-load.d/nvbroadcast-v4l2loopback.conf
# Run with: sudo bash optional/nvbroadcast.sh
set -euo pipefail
. "$(dirname "$0")/../install/lib.sh"
require_root
KREL=$(uname -r)

echo "== 1/3 v4l2loopback (DKMS)"
[ -d "/lib/modules/$KREL/build" ] || { echo "Kernel headers for $KREL missing - run install/01-kernel.sh first"; exit 1; }
apt_update
apt-get install -y v4l2loopback-dkms v4l-utils
dkms status | grep -i v4l2loopback

echo "== 2/3 Virtual camera /dev/video10 'NVbroadcast' (also after reboots)"
cat > /etc/modprobe.d/nvbroadcast-v4l2loopback.conf <<'EOF'
options v4l2loopback devices=1 video_nr=10 card_label="NVbroadcast" exclusive_caps=1 max_buffers=4
EOF
echo v4l2loopback > /etc/modules-load.d/nvbroadcast-v4l2loopback.conf
modprobe -r v4l2loopback 2>/dev/null || true
modprobe v4l2loopback
v4l2-ctl --list-devices | grep -A1 -i nvbroadcast

echo "== 3/3 NV Broadcast snap + permissions"
snap install nvbroadcast
for plug in camera audio-record hardware-observe system-observe process-control; do
	snap connect "nvbroadcast:$plug" && echo "  connected: $plug" || echo "  not possible: $plug"
done

echo
echo "Done. Start NV Broadcast from the app menu; pick the camera 'NVbroadcast' in Zoom/Meet/OBS."
