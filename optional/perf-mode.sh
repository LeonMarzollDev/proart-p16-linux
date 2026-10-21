#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - optional: simple CPU performance modes
#
# asus-wmi (fan/power profiles from MyASUS) does not exist on arm64, and power-profiles-daemon only
# offers placeholder profiles here. This installs "perf-mode", which switches the cpufreq governor:
#   perf-mode performance | balanced | quiet | status
# and a boot service that selects "balanced" (schedutil). Fan curves and power limits stay with the EC.
# Remove: systemctl disable --now perf-mode.service; rm /etc/systemd/system/perf-mode.service /usr/local/bin/perf-mode
# Run with: sudo bash optional/perf-mode.sh
set -euo pipefail
. "$(dirname "$0")/../install/lib.sh"
require_root

cat > /usr/local/bin/perf-mode <<'EOF'
#!/bin/bash
# perf-mode performance|balanced|quiet|status - cpufreq governor for all CPU policies
case "${1:-status}" in
	performance) gov=performance ;;
	balanced)    gov=schedutil ;;
	quiet)       gov=powersave ;;
	status)      cat /sys/devices/system/cpu/cpufreq/policy*/scaling_governor | sort | uniq -c; exit 0 ;;
	*)           echo "usage: perf-mode performance|balanced|quiet|status"; exit 1 ;;
esac
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
for p in /sys/devices/system/cpu/cpufreq/policy*; do echo $gov > "$p/scaling_governor"; done
echo "mode: $1 ($gov)"
EOF
chmod 755 /usr/local/bin/perf-mode
cat > /etc/systemd/system/perf-mode.service <<'EOF'
[Unit]
Description=CPU performance mode at boot (balanced)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/perf-mode balanced

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now perf-mode.service
/usr/local/bin/perf-mode status
echo "Done."
