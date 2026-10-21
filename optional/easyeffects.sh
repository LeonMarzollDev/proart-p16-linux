#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - optional: EasyEffects + community presets
#
# Not needed for good sound: the 2-way crossover (user/install-user.sh) already fixes the speakers.
# EasyEffects adds effects on top (spatial/"3D", bass enhancement). Dolby Atmos itself is not
# available for Linux. Presets: JackHack96/EasyEffects-Presets (+ impulse responses) and
# Digitalone1's LoudnessEqualizer ("Laptop"), plus "ProArt P16 Atmos" (Bass Enhancing + Perfect EQ
# with the Dolby Atmos impulse response). Note: "ProArt P16 Atmos" was made before the tweeters
# were enabled and cuts the mids; prefer "Dolby Atmos" or "Laptop" on top of the crossover.
# Options: --autostart   also start EasyEffects at login with the preset given in $PRESET
# Remove: apt remove easyeffects; rm -rf ~/.local/share/easyeffects ~/.config/autostart/easyeffects-service.desktop
# Run with: sudo bash optional/easyeffects.sh [--autostart]
set -euo pipefail
. "$(dirname "$0")/../install/lib.sh"
require_root
USERNAME=$(target_user)
UHOME=$(user_home "$USERNAME")
PRESET=${PRESET:-Dolby Atmos}
R=https://raw.githubusercontent.com/JackHack96/EasyEffects-Presets/master
D="$UHOME/.local/share/easyeffects"   # EasyEffects >= 8 keeps presets in the data directory

echo "== 1/3 EasyEffects and effect plugins"
apt_update
apt-get install -y easyeffects lsp-plugins-lv2 calf-plugins zam-plugins mda-lv2 curl python3

echo "== 2/3 Presets and impulse responses -> $D"
enc() { python3 -I -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$1"; }
install -d "$D/output" "$D/irs"
for f in "Advanced Auto Gain.json" "Bass Boosted.json" "Bass Enhancing + Perfect EQ - Low Latency.json" \
	"Bass Enhancing + Perfect EQ.json" "Boosted.json" "Dolby Atmos.json" "Loudness+Autogain.json" \
	"Perfect EQ.json" "Speaker Sync.json"; do
	curl -sfL "$R/$(enc "$f")" -o "$D/output/$f"
done
curl -sfL https://raw.githubusercontent.com/Digitalone1/EasyEffects-Presets/master/LoudnessEqualizer.json -o "$D/output/Laptop.json"
curl -sf "https://api.github.com/repos/JackHack96/EasyEffects-Presets/contents/irs" |
	python3 -I -c "import json,sys;[print(e['name']) for e in json.load(sys.stdin)]" |
	while IFS= read -r f; do curl -sfL "$R/irs/$(enc "$f")" -o "$D/irs/$f"; done
python3 -I - "$D/output/Bass Enhancing + Perfect EQ.json" "$D/output/ProArt P16 Atmos.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
for v in d["output"].values():
    if isinstance(v, dict) and "kernel-name" in v:
        v["kernel-name"] = "Dolby ATMOS ((128K MP3)) 1.Default"
json.dump(d, open(sys.argv[2], "w"), indent=4)
EOF
chown -R "$USERNAME:" "$UHOME/.local/share/easyeffects"
ls "$D/output"

echo "== 3/3 Autostart"
if [ "${1:-}" = "--autostart" ]; then
	install -d -o "$USERNAME" -g "$USERNAME" "$UHOME/.config/autostart" "$UHOME/.local/bin"
	install -m 755 -o "$USERNAME" -g "$USERNAME" "$REPO/user/bin/easyeffects-start" "$UHOME/.local/bin/easyeffects-start"
	cat > "$UHOME/.config/autostart/easyeffects-service.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Easy Effects (background)
Comment=Sound effects for the ProArt P16 speakers, preset "$PRESET"
Exec=$UHOME/.local/bin/easyeffects-start "$PRESET"
Icon=com.github.wwmm.easyeffects
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
	chown "$USERNAME:" "$UHOME/.config/autostart/easyeffects-service.desktop"
	echo "EasyEffects starts at login with \"$PRESET\"."
else
	echo "No autostart (pass --autostart to enable it). Start 'Easy Effects' from the app menu."
fi
echo "Done."
