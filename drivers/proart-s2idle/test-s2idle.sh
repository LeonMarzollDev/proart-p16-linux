#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Measure one suspend-to-idle cycle on the ASUS ProArt P16 H7607BA: average battery power while
# asleep (from the battery's energy counter), the _DSM calls proart_s2idle made, and wake state.
# Run on battery (charger unplugged), lid open, with: sudo bash test-s2idle.sh [seconds] [funcs]
#   seconds: sleep duration (default 300; short sleeps are dominated by entry/exit)
#   funcs:   _DSM function mask for this run (e.g. 0x3f8 all, 0x180 only 7/8, 0 none)
set -euo pipefail
SECS=${1:-300}
P=/sys/module/proart_s2idle/parameters
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
[ -d $P ] || echo "note: proart_s2idle is not loaded - measuring without _DSM calls"
if [ -n "${2:-}" ] && [ -d $P ]; then echo "$2" > $P/funcs; fi
[ -d $P ] && { echo 1 > $P/debug; echo "funcs=$(cat $P/funcs) enable=$(cat $P/enable)"; }

BAT=
for b in BAT0 BAT1; do
	[ -r /sys/class/power_supply/$b/energy_now ] && grep -q 1 /sys/class/power_supply/$b/present && BAT=$b && break
done
[ -n "$BAT" ] || { echo "no battery with energy_now"; exit 1; }
grep -q '\[s2idle\]' /sys/power/mem_sleep || echo "warning: mem_sleep is not s2idle: $(cat /sys/power/mem_sleep)"
[ "$(cat /sys/class/power_supply/$BAT/status)" = Discharging ] || echo "warning: $BAT is not discharging - unplug the charger"

fan() { cat /sys/class/hwmon/hwmon*/fan1_input 2>/dev/null | head -1; }
e0=$(cat /sys/class/power_supply/$BAT/energy_now); t0=$(date +%s)
echo "before: $BAT energy ${e0} uWh, fan $(fan) rpm"
MARK="proart_s2idle_test_$t0"; echo "$MARK" > /dev/kmsg
rtcwake -m freeze -s "$SECS"
t1=$(date +%s)
sleep 5	# let the EC refresh its counters
e1=$(cat /sys/class/power_supply/$BAT/energy_now)
echo "after:  $BAT energy ${e1} uWh, fan $(fan) rpm, $((t1 - t0)) s"
awk -v a="$e0" -v b="$e1" -v s="$((t1 - t0))" 'BEGIN { if (s > 0) printf "average power asleep: %.2f W (energy counter resolution limits short runs)\n", (a - b) / 1e6 * 3600 / s }'
echo "--- kernel log of this cycle"
dmesg | sed -n "/$MARK/,\$p" | grep -E 'proart_s2idle|PM: |suspend|resume|ACPI' | head -40
cat /sys/kernel/debug/suspend_stats 2>/dev/null | head -5 || true
echo "--- check now: speakers, internal microphone, headphone jack (cs42l43), keyboard, touchpad"
