#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - step 7: hardware video decoding (NVDEC via VA-API) and Firefox
#
#  - nvidia-vaapi-driver: VA-API on top of NVDEC (AV1, VP9 incl. 10-bit, HEVC, H.264), checked with vainfo
#  - Firefox from Mozilla's APT repository (arm64 .deb). The Ubuntu snap uses the mesa-2404 graphics
#    content snap and cannot use the NVIDIA driver at all: video decodes on the CPU and WebRender
#    renders in software.
# The VA-API environment (LIBVA_DRIVER_NAME, NVD_BACKEND, MOZ_DISABLE_RDD_SANDBOX) is installed by
# user/install-user.sh; the Firefox prefs for every profile by step 3 (config/firefox/proart-nvidia.js:
# Vulkan video decoding; VA-API cannot export frames on the N1X). See docs/technical-notes.md.
# Profiles: copy ~/snap/firefox/common/.mozilla/firefox to ~/.mozilla/ (with Firefox closed) and
# select the profile in about:profiles. The snap stays installed as a fallback.
# Remove: apt remove firefox nvidia-vaapi-driver; rm /etc/apt/sources.list.d/mozilla.list \
#         /etc/apt/preferences.d/mozilla /etc/apt/keyrings/packages.mozilla.org.asc
# Run with: sudo bash install/07-video-firefox.sh
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_root
MOZILLA_FPR=35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3

echo "== 1/2 nvidia-vaapi-driver + vainfo"
apt_update
apt-get install -y nvidia-vaapi-driver vainfo curl gpg

echo "== 2/2 Firefox from Mozilla's APT repository"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg -o /etc/apt/keyrings/packages.mozilla.org.asc
GNUPGTMP=$(mktemp -d)
fpr=$(gpg --homedir "$GNUPGTMP" -n -q --import --import-options import-show /etc/apt/keyrings/packages.mozilla.org.asc |
	awk '/pub/{getline; gsub(/^ +| +$/,""); print}')
rm -rf "$GNUPGTMP"
if [ "$fpr" != "$MOZILLA_FPR" ]; then
	echo "Mozilla signing key fingerprint mismatch ($fpr) - aborting"
	rm -f /etc/apt/keyrings/packages.mozilla.org.asc
	exit 1
fi
echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
	> /etc/apt/sources.list.d/mozilla.list
cat > /etc/apt/preferences.d/mozilla <<'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF
apt_update
# Ubuntu's "firefox" deb is a transitional package for the snap with a higher epoch, hence the downgrade.
apt-get install -y --allow-downgrades firefox
dpkg -l firefox | tail -1

echo "== 3/3 Hardware video decoding for every Firefox profile (default prefs)"
# read before any profile, so they apply to new and existing ones; a profile can still change them.
# Not an enterprise policy: Firefox reads gfx.blocklist.all before policies are applied.
install -m 644 "$REPO/config/firefox/proart-nvidia.js" /usr/lib/firefox/defaults/pref/

echo
echo "Done. Next (as your user): user/install-user.sh, log out and back in, and check that the dock"
echo "launches /usr/lib/firefox/firefox (not the snap). about:support shows the decoder per codec."
