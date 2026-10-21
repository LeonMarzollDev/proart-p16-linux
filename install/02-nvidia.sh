#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - step 2: NVIDIA 615 user space for the RTX Spark GPU (PCI 10de:2e03)
#
# The open kernel modules come prebuilt for the linux-nvidia kernel (install/01-kernel.sh), so no
# DKMS build is needed; older kernels stay a clean fallback without the NVIDIA driver.
# The GPU drives the internal OLED panel (eDP, 3840x2400 @ 120 Hz) through nvidia-drm.
# Remove: apt remove nvidia-headless-no-dkms-615-open nvidia-utils-615 libnvidia-gl-615 ...
# Run with: sudo bash install/02-nvidia.sh
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_root
NV=615

apt_update
apt-get install -y \
	"nvidia-headless-no-dkms-$NV-open" \
	"nvidia-utils-$NV" \
	"libnvidia-gl-$NV" \
	"libnvidia-decode-$NV" \
	"libnvidia-encode-$NV" \
	"libnvidia-extra-$NV" \
	"libnvidia-fbc1-$NV" \
	"libnvidia-cfg1-$NV" \
	"xserver-xorg-video-nvidia-$NV"

echo
echo "Done. Reboot now. If the screen stays black: GRUB -> 'Advanced options' -> previous kernel."
