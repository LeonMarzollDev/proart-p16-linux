#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - optional: keep the internal audio working across long sleeps
#
# After a few minutes of s2idle the SoC's audio power domain loses power and the cs42l43 (mic,
# headphone jack, tweeters) stops producing data until a reboot. This installs a systemd sleep hook
# that asks the audio firmware to keep the domain powered while the laptop sleeps (slightly
# higher sleep power). See config/system-sleep/proart-audio.
# Status: being tested (docs/technical-notes.md section 9) - not yet confirmed over a long sleep.
# Remove: rm /usr/lib/systemd/system-sleep/proart-audio
# Run with: sudo bash optional/sleep-audio.sh
set -euo pipefail
. "$(dirname "$0")/../install/lib.sh"
require_root

echo "== Sleep hook"
install -m 755 "$REPO/config/system-sleep/proart-audio" /usr/lib/systemd/system-sleep/proart-audio
[ -w /sys/bus/platform/devices/NVDA6210:00/pwrap_power_ctrl_req ] ||
	echo "Warning: power_wrap request node not found - the hook will only log that it cannot act."
echo "Done. journalctl -t proart-audio shows what the hook does on each sleep."
