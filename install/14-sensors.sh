#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - step 14 (optional, UNVERIFIED on hardware): ambient light sensor
#
# The ambient light sensor sits in a "HID Sensor Collection V2" behind HID over SPI:
# \_SB.SENH, _HID MSFW1111, _CID PNP0C51, on \_SB.SPI3 (NVDA0210, spi-mt65xx), interrupt GPIO 0xBE.
# Windows shows it as the system LightSensor. Linux 7.0 and linux-nvidia have no HID-over-SPI
# transport; the series "Add spi-hid transport driver" (v4, June 2026) is still under review.
# This step builds that series' core + ACPI glue out of tree (drivers/spi-hid, DKMS), then the
# stock hid-sensor-hub + hid-sensor-als drivers expose the sensor as iio "als" and iio-sensor-proxy
# hands it to GNOME (Settings > Power > "Automatic Screen Brightness").
# The webcam's presence sensor (636e:0bdb interface 4, hid-sensor-prox) needs nothing.
# There is no accelerometer, gyroscope or hinge sensor in this laptop (Windows enumerates none).
#
# Needs: linux-nvidia >= 7.0.0-1022 (spi-mt65xx binds over ACPI from that version on).
# Remove: dkms remove spi-hid/<version> --all; rm -rf /usr/src/spi-hid-*; update-initramfs -u
# Run with: sudo bash install/14-sensors.sh
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_root
KREL=$(uname -r)
D="$REPO/drivers/spi-hid"
VER=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$D/dkms.conf")
SRC=/usr/src/spi-hid-$VER

echo "== 1/5 Sensor hub present?"
SENH=$(grep -l '^MSFW1111$' /sys/bus/acpi/devices/*/hid 2>/dev/null | head -1 | xargs -r dirname)
if [ -z "$SENH" ]; then
	echo "No MSFW1111 ACPI device: not a ProArt P16 H7607BA (or different firmware). Nothing to do."
	exit 0
fi
echo "ACPI $(basename "$SENH"), status $(cat "$SENH/status" 2>/dev/null || echo ?)"
# a kernel that ships its own spi-hid needs nothing from here
if modinfo -F filename spi_hid_acpi 2>/dev/null | grep -qv '/updates/'; then
	echo "Kernel $KREL already ships spi_hid_acpi: skipping the DKMS build."
	SKIP_DKMS=1
fi

echo "== 2/5 Packages"
apt_update
apt-get install -y dkms build-essential patchutils curl iio-sensor-proxy

if [ -z "${SKIP_DKMS:-}" ]; then
	echo "== 3/5 DKMS package spi-hid $VER (posted series, not mainline)"
	bash "$D/prepare.sh"
	for old in $(dkms status spi-hid 2>/dev/null | sed -n 's#^spi-hid/\([^,]*\),.*#\1#p' | sort -u); do
		dkms remove "spi-hid/$old" --all || true
	done
	rm -rf /usr/src/spi-hid-*
	install -d "$SRC/src"
	install -m 644 "$D"/{Makefile,compat.h,dkms.conf} "$SRC/"
	install -m 644 "$D"/src/* "$SRC/src/"
	dkms add "spi-hid/$VER"
	dkms build "spi-hid/$VER" -k "$KREL"
	dkms install "spi-hid/$VER" -k "$KREL"
else
	echo "== 3/5 (skipped)"
fi

echo "== 4/5 Load the transport and the sensor drivers"
modprobe spi_hid_acpi || true
modprobe hid_sensor_hub || true
modprobe hid_sensor_als || true
sleep 2
journalctl -k -b --no-pager -o cat | grep -iE 'spi.hid|spi_hid|MSFW1111|hid-sensor' | tail -8 || true
als=""
for d in /sys/bus/iio/devices/iio:device*; do
	[ -e "$d/in_illuminance_raw" ] || [ -e "$d/in_illuminance_input" ] || continue
	als=$d
done
if [ -n "$als" ]; then
	echo "ALS: $(cat "$als/name") at $als, raw $(cat "$als"/in_illuminance_raw 2>/dev/null || cat "$als"/in_illuminance_input)"
else
	echo "Warning: no iio illuminance channel appeared. Check 'journalctl -k -b | grep -i spi' and"
	echo "         'ls /sys/bus/spi/devices' (spi-MSFW1111:00 must exist; the SPI3 controller has to bind first)."
fi

echo "== 5/5 Update the initramfs, restart iio-sensor-proxy"
update-initramfs -u -k "$KREL"
systemctl restart iio-sensor-proxy 2>/dev/null || true
command -v monitor-sensor >/dev/null && timeout 3 monitor-sensor 2>/dev/null | grep -i light | head -2 || true

echo
echo "Done. GNOME: Settings > Power > Automatic Screen Brightness (needs a working panel backlight)."
