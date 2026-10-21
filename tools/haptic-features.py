#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Read-only diagnosis of the haptic touchpad (ASUS ASTH0001 haptic controller + PixArt 093A:4F01).
# Only reads HID feature reports (HIDIOCGFEATURE); nothing is written to the devices.
# Run as root:  sudo python3 -I tools/haptic-features.py [--out FILE]
import argparse
import fcntl
import glob
import os
import pwd

DEVICES = {
    "ASTH0001 (ASUS haptic controller)": ("i2c-ASTH0001:00", [0x07, 0x5A]),
    "Touchpad 093A:4F01": ("i2c-3030443150435341:00", [0x02, 0x06, 0x07, 0x09, 0x0D, 0x35, 0x03, 0x05]),
}


def hidiocgfeature(length):
    return (3 << 30) | (length << 16) | (ord("H") << 8) | 0x07


def invoking_user():
    uid = os.environ.get("SUDO_UID") or os.environ.get("PKEXEC_UID")
    return pwd.getpwuid(int(uid)) if uid else None


user = invoking_user()
ap = argparse.ArgumentParser()
ap.add_argument("--out", default=os.path.join(user.pw_dir if user else ".", "haptic-features.txt"))
out = ap.parse_args().out

lines = []
for label, (i2c, reports) in DEVICES.items():
    nodes = glob.glob(f"/sys/bus/i2c/devices/{i2c}/0018:*/hidraw/hidraw*")
    if not nodes:
        lines.append(f"{label}: no hidraw device found")
        continue
    dev = "/dev/" + os.path.basename(nodes[0])
    lines.append(f"== {label} ({dev})")
    fd = os.open(dev, os.O_RDWR)
    for rid in reports:
        buf = bytearray(300)
        buf[0] = rid
        try:
            n = fcntl.ioctl(fd, hidiocgfeature(len(buf)), buf)
            lines.append(f"  report 0x{rid:02X}: {bytes(buf[:max(n, 1)]).hex(' ')}")
        except OSError as e:
            lines.append(f"  report 0x{rid:02X}: error {e}")
    os.close(fd)

with open(out, "w") as f:
    f.write("\n".join(lines) + "\n")
if user:
    os.chown(out, user.pw_uid, user.pw_gid)
print("\n".join(lines))
print(f"-> {out}")
