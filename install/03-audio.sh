#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - step 3: internal audio (root part)
#
#  1. UCM profile for the MT8901 SoundWire card (NVIDIA, alsa-ucm-conf PR #862; until a release ships it)
#  2. ASUS speaker tuning for the two Cirrus CS35L56 woofer amps. linux-firmware has no tuning for
#     this model (SSID 1043:1484). The files are taken unmodified from ASUS' Windows audio driver,
#     which is downloaded and unpacked (not executed) here. They are Cirrus Logic / ASUS licensed.
#  3. proart_audio (DKMS): gives the amps the firmware UID "10431484". The MT8901 machine driver sets
#     no PCI SSID, so without it cs35l56 only looks for generic files and loads no tuning.
# The 2-way crossover (woofers + tweeters) is user-level: run user/install-user.sh after rebooting.
#
# Remove: dkms remove proart-audio/1.0 --all; rm -rf /usr/src/proart-audio-1.0 \
#         /etc/modprobe.d/proart-audio.conf \
#         /usr/share/alsa/ucm2/MediaTek/mt8901-soundwir /usr/share/alsa/ucm2/conf.d/mt8901-soundwir \
#         /lib/firmware/updates/cirrus/cs35l56-b0-dsp1-misc-10431484*
# Run with: sudo bash install/03-audio.sh
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_root
KREL=$(uname -r)
UCM=/usr/share/alsa/ucm2
FW=/lib/firmware/updates/cirrus
BASE=cs35l56-b0-dsp1-misc-10431484
ASUS_EXE=Audio_Driver_ARM_Cirrus_Z_V1.0.678.52824Sub3_49783.exe
ASUS_URL="https://dlcdnets.asus.com/pub/ASUS/nb/Image/Driver/Audio/49783/$ASUS_EXE?model=H7407BA"
ASUS_SHA256=01ffa79558813cf9e943d63b4a39289471915ab865c32a1138ffe8382175355f
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "== 1/4 UCM profile mt8901-soundwir"
install -d "$UCM/MediaTek/mt8901-soundwir" "$UCM/conf.d/mt8901-soundwir"
install -m 644 "$REPO"/config/ucm2/MediaTek/mt8901-soundwir/*.conf "$UCM/MediaTek/mt8901-soundwir/"
ln -sfn ../../MediaTek/mt8901-soundwir/mt8901-soundwir.conf "$UCM/conf.d/mt8901-soundwir/mt8901-soundwir.conf"

echo "== 2/4 ASUS speaker tuning (CS35L56, SSID 1043:1484) from the ASUS Windows driver"
apt_update
apt-get install -y curl 7zip dkms build-essential
curl -fL --retry 3 -o "$WORK/driver.exe" "$ASUS_URL"
echo "$ASUS_SHA256  $WORK/driver.exe" | sha256sum -c -
# The installer is an Inno Setup executable with the driver package appended as a 7z archive.
offset=$(LC_ALL=C grep -obUaP '7z\xBC\xAF\x27\x1C' "$WORK/driver.exe" | head -1 | cut -d: -f1)
[ -n "$offset" ] || { echo "no 7z archive found in the ASUS driver"; exit 1; }
tail -c +$((offset + 1)) "$WORK/driver.exe" > "$WORK/driver.7z"
7z x -y -o"$WORK/driver" "$WORK/driver.7z" >/dev/null
X="$WORK/driver/XU_Ext"
install -d "$FW"
install -m 644 "$X/fw/35L56/3.13.4/dflt/b0_dflt_35l56_3.13.4.wmfw" "$FW/$BASE-spkid0.wmfw"
install -m 644 "$X/tn/35L56/1484/dflt/b0_dflt_1484_lw_l1u0.bin"     "$FW/$BASE-spkid0-l1u0.bin"
install -m 644 "$X/tn/35L56/1484/dflt/b0_dflt_1484_rw_l1u1.bin"     "$FW/$BASE-spkid0-l1u1.bin"
# The driver names the files after the speaker-ID pin; Windows uses this tuning whatever the pin
# says, so spkid1 and the no-spkid names point to the same files.
for f in .wmfw -l1u0.bin -l1u1.bin; do
	ln -sfn "$BASE-spkid0$f" "$FW/$BASE-spkid1$f"
	ln -sfn "$BASE-spkid0$f" "$FW/$BASE$f"
done
ls -l "$FW" | grep 10431484

echo "== 3/4 proart_audio (DKMS), loaded before snd_soc_cs35l56_sdw"
VER=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$REPO/drivers/proart-audio/dkms.conf")
dkms remove "proart-audio/$VER" --all >/dev/null 2>&1 || true
rm -rf "/usr/src/proart-audio-$VER"
install -d "/usr/src/proart-audio-$VER"
install -m 644 "$REPO"/drivers/proart-audio/{proart_audio.c,Makefile,dkms.conf} "/usr/src/proart-audio-$VER/"
dkms add "proart-audio/$VER"
dkms build "proart-audio/$VER" -k "$KREL"
dkms install "proart-audio/$VER" -k "$KREL"
echo "softdep snd_soc_cs35l56_sdw pre: proart_audio" > /etc/modprobe.d/proart-audio.conf
# The softdep is enough. A modules-load.d entry would be copied into the initramfs by dracut,
# where loading fails ("Invalid argument") and marks systemd-modules-load.service as failed.
rm -f /etc/modules-load.d/proart-audio.conf

echo "== 4/4 Update the initramfs"
update-initramfs -u -k "$KREL"

# Per-unit speaker calibration: cs35l56 reads it from the UEFI variable the Windows driver uses
# (CirrusSmartAmpCalibrationData) and applies it once the tuning above is loaded. Report only.
CAL=/sys/firmware/efi/efivars/CirrusSmartAmpCalibrationData-02f9af02-7734-4233-b43d-93fe5aa35db3
if [ -e "$CAL" ]; then
	echo "Speaker calibration: UEFI variable present ($(stat -c %s "$CAL") bytes), applied by cs35l56"
else
	echo "Speaker calibration: no CirrusSmartAmpCalibrationData UEFI variable - amps use the default"
fi

# Optional: the patched SoundWire manager for audio after long sleeps (research/audio-suspend.md)
if [ "${PROART_SDW_DKMS:-0}" = 1 ]; then
	bash "$REPO/patches/audio/install-sdw-dkms.sh"
else
	echo "Audio after long sleeps: sudo bash patches/audio/install-sdw-dkms.sh (patched soundwire-mtk)"
	echo "                         and/or sudo bash optional/sleep-audio.sh (sleep hook fallback)"
fi

echo
echo "Done. Reboot, then run (as your user):  user/install-user.sh"
