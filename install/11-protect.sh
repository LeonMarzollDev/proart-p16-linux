#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - step 11: keep this setup across Ubuntu updates
#
#  1. The UCM profile (install/03-audio.sh) lives in alsa-ucm-conf's directory, but no package ships it
#     yet. Once alsa-ucm-conf ships NVIDIA's profile, dpkg would overwrite the local changes (amps at
#     0 dB, woofer amps switched by the verb, port names; without them the woofers stay silent). Local
#     diversions make dpkg put the package's copies next to ours as *.distrib.
#  2. The packages this setup needs are marked as manually installed, so apt autoremove keeps them.
#  3. apt hook: after every package change config/apt/proart-after-apt renews the WirePlumber mute
#     fix of each user, builds missing ProArt DKMS modules for every installed kernel and logs it
#     (journalctl -t proart-after-apt). It runs once now.
#
# Remove: for f in $(dpkg-divert --list '*mt8901-soundwir*' | awk '{print $3}'); do
#           dpkg-divert --local --no-rename --remove "$f"; done
#         rm /etc/apt/apt.conf.d/80-proart-p16 /usr/local/sbin/proart-after-apt
# Run with: sudo bash install/11-protect.sh
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_root
UCM=/usr/share/alsa/ucm2

echo "== 1/3 UCM profile: local diversions"
for f in "$REPO"/config/ucm2/MediaTek/mt8901-soundwir/*.conf; do
	p="$UCM/MediaTek/mt8901-soundwir/$(basename "$f")"
	dpkg-divert --local --no-rename --divert "$p.distrib" --add "$p" >/dev/null
done
dpkg-divert --local --no-rename --divert "$UCM/conf.d/mt8901-soundwir/mt8901-soundwir.conf.distrib" \
	--add "$UCM/conf.d/mt8901-soundwir/mt8901-soundwir.conf" >/dev/null
dpkg-divert --list '*mt8901-soundwir*' | wc -l | xargs echo "  diverted files:"

echo "== 2/3 Needed packages marked as manually installed"
KREL=$(uname -r)
NEED="lsp-plugins-lv2 alsa-utils dkms build-essential linux-image-$KREL linux-modules-$KREL linux-headers-$KREL
	linux-modules-nvidia-615-open-$KREL nvidia-vaapi-driver libinput-tools gnome-calls ydotool v4l2loopback-dkms
	easyeffects calf-plugins mda-lv2 zam-plugins gir1.2-ayatanaappindicator3-0.1 gir1.2-notify-0.7 firefox"
# only installed ones: apt-mark fails on unknown packages
installed=$(for p in $NEED; do dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" && echo "$p"; done)
apt-mark manual $installed >/dev/null
echo "  $(echo $installed | wc -w) packages"

echo "== 3/3 apt hook"
install -m 755 "$REPO/config/apt/proart-after-apt" /usr/local/sbin/proart-after-apt
cat > /etc/apt/apt.conf.d/80-proart-p16 <<'EOF'
// ASUS ProArt P16 (proart-p16-linux install/11-protect.sh): keep the setup across package updates
DPkg::Post-Invoke { "[ -x /usr/local/sbin/proart-after-apt ] && /usr/local/sbin/proart-after-apt || true"; };
EOF
/usr/local/sbin/proart-after-apt
journalctl -t proart-after-apt --since "-5 min" --no-pager -o cat | sed 's/^/  /'
echo "Done."
