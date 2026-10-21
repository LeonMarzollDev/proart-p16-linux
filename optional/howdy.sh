#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - optional: Howdy (face login with the IR camera), stage 1: build + configure
#
# Login and sudo stay unchanged; optional/howdy-enable.sh activates PAM after a successful test.
# Howdy 3 (beta) is built from source at a fixed commit (no package exists for Ubuntu 26.04 / arm64);
# dlib goes into its own venv instead of the system Python.
# The IR camera's emitter strobes (every second frame is dark), hence dark_threshold = 90.
# Next steps (as root):  /usr/local/bin/howdy -U <user> -y add     (look into the camera)
#                        /opt/howdy-venv/bin/python3 /usr/local/lib/aarch64-linux-gnu/howdy/compare.py <user>
# Remove: rm -rf /opt/howdy-src /opt/howdy-venv /usr/local/etc/howdy /usr/local/lib/aarch64-linux-gnu/howdy* \
#         /usr/local/share/dlib-data /usr/local/bin/howdy /usr/lib/aarch64-linux-gnu/security/pam_howdy.so
# Run with: sudo bash optional/howdy.sh
set -euo pipefail
. "$(dirname "$0")/../install/lib.sh"
require_root
COMMIT=d3ab99382f88f043d15f15c1450ab69433892a1c
VENV=/opt/howdy-venv
SRC=/opt/howdy-src
IRCAM=/dev/v4l/by-path/platform-NVDA8001:00-usb-0:1:1.2-video-index0

echo "== 1/5 Build dependencies"
apt_update
apt-get install -y git meson ninja-build cmake build-essential pkg-config \
	python3-dev python3-venv python3-numpy python3-opencv libopencv-dev \
	libpam0g-dev libinih-dev libevdev-dev wget bzip2 v4l-utils

echo "== 2/5 dlib (face recognition) in $VENV - this takes a few minutes"
[ -x "$VENV/bin/python3" ] || python3 -m venv --system-site-packages "$VENV"
CMAKE_BUILD_PARALLEL_LEVEL=$(nproc) "$VENV/bin/pip" install --no-cache-dir dlib
"$VENV/bin/python3" -c "import dlib, cv2, numpy; print('dlib', dlib.__version__, '| opencv', cv2.__version__)"

echo "== 3/5 Build Howdy (commit ${COMMIT:0:10}) and install it to /usr/local"
[ -d "$SRC/.git" ] || git clone https://github.com/boltgolt/howdy.git "$SRC"
git -C "$SRC" fetch --quiet origin
git -C "$SRC" checkout --quiet "$COMMIT"
cd "$SRC"
rm -rf build
meson setup build --prefix=/usr/local \
	-Dpython_path="$VENV/bin/python3" \
	-Dpam_dir=/usr/lib/aarch64-linux-gnu/security \
	-Dinstall_pam_config=true
meson compile -C build
meson install -C build

echo "== 4/5 Download the dlib models"
cd /usr/local/share/dlib-data
ls ./*.dat >/dev/null 2>&1 || ./install.sh
ls -l ./*.dat

echo "== 5/5 Configuration: IR camera, dark threshold (the IR emitter strobes)"
CFG=/usr/local/etc/howdy/config.ini
# timeout 7 s and certainty 4.0 (Howdy scale: lower = stricter): with a single face model the default
# 4 s / 3.5 timed out often; 4.0 is still strict with an IR camera. Add several models (see README).
sed -i "s|^device_path = .*|device_path = $IRCAM|; s|^dark_threshold = .*|dark_threshold = 90|; s|^timeout = .*|timeout = 7|; s|^certainty = .*|certainty = 4.0|" "$CFG"
grep -E "^(device_path|dark_threshold|certainty|timeout)" "$CFG"

echo
echo "Done (login/sudo unchanged). Next: enroll your face as root:"
echo "  /usr/local/bin/howdy -U $(target_user 2>/dev/null || echo "<user>") -y add"
