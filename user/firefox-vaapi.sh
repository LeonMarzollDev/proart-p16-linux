#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Firefox prefs for NVIDIA hardware video decoding (nvidia-vaapi-driver), written to user.js.
# Run as your user with Firefox closed:  user/firefox-vaapi.sh ~/.mozilla/firefox/<profile folder>
# Without an argument, the profile folders found under ~/.mozilla/firefox are listed.
# Remove: delete the three lines below the "ProArt P16" comment from <profile>/user.js
set -euo pipefail
[ "$(id -u)" -ne 0 ] || { echo "Run this as your normal user, not as root"; exit 1; }
if [ $# -ne 1 ]; then
	echo "usage: $0 <profile folder>"
	echo "profile folders:"
	find "$HOME/.mozilla/firefox" -maxdepth 1 -mindepth 1 -type d -name "*.*" -printf "  %p\n" 2>/dev/null || true
	exit 1
fi
PROFILE=$1
[ -f "$PROFILE/prefs.js" ] || { echo "$PROFILE does not look like a Firefox profile (no prefs.js)"; exit 1; }
if pgrep -x firefox-bin >/dev/null || pgrep -x firefox >/dev/null; then
	echo "Please close Firefox first"; exit 1
fi
grep -qs "media.hardware-video-decoding.force-enabled" "$PROFILE/user.js" || {
	echo '// ProArt P16: NVIDIA hardware video decoding (VA-API through nvidia-vaapi-driver)'
	echo 'user_pref("media.hardware-video-decoding.force-enabled", true);'
} >> "$PROFILE/user.js"
for pref in media.ffmpeg.vaapi.enabled widget.dmabuf.force-enabled; do
	grep -qs "\"$pref\"" "$PROFILE/user.js" || echo "user_pref(\"$pref\", true);" >> "$PROFILE/user.js"
done
cat "$PROFILE/user.js"
echo "Done. Start Firefox and check about:support -> Media -> hardware decoding."
