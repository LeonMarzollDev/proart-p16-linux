#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - step 9: GPU acceleration for snap apps
#
# Inside snaps, NVIDIA's EGL driver fails to load on the N1X because snapd does not expose
# libnvidia-rmapi-tegra.so (needed by libnvidia-eglcore) to snaps. Every snap app (Snap Store,
# WhatsApp clients, Chromium/Electron snaps, ...) then silently renders on the CPU with llvmpipe,
# which costs several watts. This installs a small glvnd vendor shim that loads the missing
# library first; see drivers/snap-egl-shim/snap_egl_shim.c. The host ignores the shim.
#
# Remove: rm /usr/lib/aarch64-linux-gnu/libnvidia-snap-egl.so \
#            /usr/share/glvnd/egl_vendor.d/09_nvidia_snap.json
# Run with: sudo bash install/09-snap-gpu.sh   (then restart the snap apps)
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_root
SRC=$REPO/drivers/snap-egl-shim
LIB=/usr/lib/aarch64-linux-gnu/libnvidia-snap-egl.so

echo "== 1/3 Build and install the EGL shim"
command -v gcc >/dev/null || { apt_update; apt-get install -y build-essential; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
gcc -O2 -Wall -Wextra -shared -fPIC -o "$WORK/libnvidia-snap-egl.so" "$SRC/snap_egl_shim.c"
# libnvidia* is the name snapd's AppArmor rules let snaps map from the host
install -m 644 "$WORK/libnvidia-snap-egl.so" "$LIB"
# snapd links egl_vendor.d/*nvidia*.json from here into every snap
install -m 644 "$SRC/09_nvidia_snap.json" /usr/share/glvnd/egl_vendor.d/

echo "== 2/3 Recreate the snap mount namespaces (they pick up the new vendor file)"
for s in $(snap list 2>/dev/null | awk 'NR > 1 { print $1 }'); do
	/usr/lib/snapd/snap-discard-ns "$s" 2>/dev/null || true
done

echo "== 3/3 Check"
ls -l "$LIB" /usr/share/glvnd/egl_vendor.d/09_nvidia_snap.json
echo
echo "Done. Restart running snap apps; they now render on the NVIDIA GPU."
