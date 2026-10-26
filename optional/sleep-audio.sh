#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - optional: keep the internal audio working across long sleeps
#
# After a few minutes of s2idle the cs42l43 (mic, headphone jack, tweeters) stopped producing data
# and the speakers crackled until a reboot. This installs a systemd sleep hook that
#   - keeps the audio power domain on while sleeping (always-on SSPM scene; slightly higher sleep
#     power), and
#   - after waking, selects the APLL2 parents of the SoundWire clocks again and restarts link 1,
#     unless the patched soundwire-mtk (patches/audio/install-sdw-dkms.sh) already does that.
# Settings: /etc/default/proart-audio (PROART_AUDIO_KEEP_ON, PROART_AUDIO_RESUME_CLK; 1 = on).
# See config/system-sleep/proart-audio and research/audio-suspend.md.
# Status: not yet confirmed over a long sleep on the laptop.
# Remove: rm /usr/lib/systemd/system-sleep/proart-audio /etc/default/proart-audio
# Run with: sudo bash optional/sleep-audio.sh
set -euo pipefail
. "$(dirname "$0")/../install/lib.sh"
require_root

echo "== Sleep hook"
install -m 755 "$REPO/config/system-sleep/proart-audio" /usr/lib/systemd/system-sleep/proart-audio
[ -e /etc/default/proart-audio ] || cat > /etc/default/proart-audio <<'EOF'
# ProArt P16 audio sleep hook (/usr/lib/systemd/system-sleep/proart-audio). 1 = on, 0 = off.
# Keep the audio power domain on during sleep (costs some sleep power):
PROART_AUDIO_KEEP_ON=1
# After waking: SoundWire clock parents + link 1 restart (skipped with the patched soundwire-mtk):
PROART_AUDIO_RESUME_CLK=1
EOF
[ -w /sys/bus/platform/devices/NVDA6210:00/pwrap_power_ctrl_req ] ||
	echo "Warning: power_wrap request node not found - the hook will only log that it cannot act."
echo "Done. journalctl -t proart-audio shows what the hook does on each sleep."
