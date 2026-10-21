#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - user-level part (run as your normal user, NOT as root)
#  - ~/.local/bin: proart-eq (tone control), proart-tweeter (tweeter routing + headphone jack),
#                  pw-id (PipeWire node id helper), proart-fnlock (Fn-lock top-bar indicator),
#                  ui-screenshot / ui-tree (optional desktop helpers)
#  - PipeWire 2-way crossover "ProArt P16 Speakers", WirePlumber device names
#  - environment for NVIDIA VA-API video decoding
#  - systemd user service proart-tweeter, autostart entry for proart-fnlock
# Requires install/03-audio.sh (and install/05-keyboard.sh for the Fn-lock indicator) to have been run first.
# Remove: ./install-user.sh --remove
set -euo pipefail
[ "$(id -u)" -ne 0 ] || { echo "Run this as your normal user, not as root"; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
BIN="$HOME/.local/bin"
PW="$HOME/.config/pipewire/pipewire.conf.d"
WP="$HOME/.config/wireplumber/wireplumber.conf.d"
ENVD="$HOME/.config/environment.d"
UNIT="$HOME/.config/systemd/user"
AUTOSTART="$HOME/.config/autostart"
TOOLS="proart-eq proart-tweeter proart-fnlock pw-id ui-screenshot ui-tree easyeffects-start"

restart_audio() {
	systemctl --user restart pipewire pipewire-pulse wireplumber
	sleep 4
}

if [ "${1:-}" = "--remove" ]; then
	echo "== Removing the user-level ProArt P16 files"
	systemctl --user disable --now proart-tweeter.service 2>/dev/null || true
	pkill -f "$BIN/proart-fnlock" 2>/dev/null || true
	rm -f "$AUTOSTART/proart-fnlock.desktop"
	for t in $TOOLS; do rm -f "$BIN/$t"; done
	rm -f "$PW/60-proart-2way.conf" "$WP/51-proart-names.conf" "$ENVD/90-nvidia-vaapi.conf" "$UNIT/proart-tweeter.service"
	systemctl --user daemon-reload
	restart_audio
	echo "Done (log out and back in to drop the VA-API environment)."
	exit 0
fi

echo "== 1/5 Tools -> $BIN"
install -d "$BIN"
for t in $TOOLS; do install -m 755 "$HERE/bin/$t" "$BIN/$t"; done

echo "== 2/5 PipeWire crossover, WirePlumber names, VA-API environment"
install -d "$PW" "$WP" "$ENVD"
install -m 644 "$REPO/config/pipewire/60-proart-2way.conf" "$PW/"
install -m 644 "$REPO/config/wireplumber/51-proart-names.conf" "$WP/"
install -m 644 "$REPO/config/environment.d/90-nvidia-vaapi.conf" "$ENVD/"

echo "== 3/5 systemd user service proart-tweeter"
install -d "$UNIT"
install -m 644 "$HERE/systemd/proart-tweeter.service" "$UNIT/"
systemctl --user daemon-reload
restart_audio
systemctl --user enable --now proart-tweeter.service
sleep 3

echo "== 4/5 Levels and defaults"
# both hardware sinks stay at 100 %; the volume is controlled on "ProArt P16 Speakers" only
for n in alsa_output.platform-mtk_sdw_mc.HiFi__Speaker__sink \
         alsa_output.platform-mtk_sdw_mc.HiFi__Headphones__sink proart_speakers; do
	id=$("$BIN/pw-id" "$n")
	[ -n "$id" ] && wpctl set-volume "$id" 1.0
done
mic=$("$BIN/pw-id" alsa_input.platform-mtk_sdw_mc.HiFi__Mic__source)
[ -n "$mic" ] && wpctl set-default "$mic"
wpctl inspect @DEFAULT_AUDIO_SINK@ | grep " node.description" || true
wpctl inspect @DEFAULT_AUDIO_SOURCE@ | grep " node.description" || true
"$BIN/proart-eq"

echo "== 5/5 Fn-lock indicator (top bar + notification on Fn+Esc)"
install -d "$AUTOSTART"
sed "s|^Exec=.*|Exec=$BIN/proart-fnlock|" "$HERE/autostart/proart-fnlock.desktop" > "$AUTOSTART/proart-fnlock.desktop"
if ls /sys/bus/hid/devices/*0B05:4B42*/fn_lock >/dev/null 2>&1; then
	pkill -f "$BIN/proart-fnlock" 2>/dev/null || true
	setsid -f "$BIN/proart-fnlock" >/dev/null 2>&1 < /dev/null
	echo "proart-fnlock started"
else
	echo "fn_lock attribute not found - run install/05-keyboard.sh first; the indicator starts at the next login"
fi

echo
echo "Done. Log out and back in once so the VA-API environment reaches Firefox."
