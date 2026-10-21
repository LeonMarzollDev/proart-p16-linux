#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copy the ACPI tables to a folder in the invoking user's home and decompile them with iasl
# (acpica-tools is unpacked locally, not installed). For analysing DSDT/SSDT methods.
# The MSDM table (Windows product key) is left out.
# Run with: sudo bash tools/dump-acpi.sh [target folder]   (default: ~/acpi-tables)
set -euo pipefail
. "$(dirname "$0")/../install/lib.sh"
require_root
USERNAME=$(target_user)
DST=${1:-$(user_home "$USERNAME")/acpi-tables}
install -d "$DST/raw" "$DST/dsl"
cp -r /sys/firmware/acpi/tables/. "$DST/raw/" 2>/dev/null || true
# MSDM holds the Windows product key - never needed for analysis, easily shared by accident
rm -f "$DST/raw/MSDM"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
(cd "$WORK" && apt-get download acpica-tools >/dev/null && dpkg-deb -x acpica-tools_*.deb x)
IASL="$WORK/x/usr/bin/iasl"
cp "$DST/raw/DSDT" "$DST/dsl/DSDT.dat"
for f in "$DST"/raw/SSDT*; do cp "$f" "$DST/dsl/$(basename "$f").dat"; done
cd "$DST/dsl"
"$IASL" -e SSDT*.dat -d DSDT.dat >/dev/null 2>&1 || true
for f in SSDT*.dat; do "$IASL" -e DSDT.dat -d "$f" >/dev/null 2>&1 || true; done
chown -R "$USERNAME:" "$DST"
ls -l "$DST/dsl"/*.dsl
