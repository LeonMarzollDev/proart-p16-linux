#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Haptic touchpad probe (PixArt 093A:4F01):
#  1) 4 s light touch, 2) 4 s firm presses -> pressure values (ABS_MT_PRESSURE) and BTN_LEFT clicks
#  3) vibration patterns 3..7 with intensity 4 through HID output report 0x45
#     (byte 1 = waveform ordinal from the haptic waveform list, byte 2 = intensity 0..4)
# Findings on the H7607BA: the pad reports pressure ~80-120 and real BTN_LEFT clicks on firm presses,
# the actuator vibrates on report 0x45, but there is no auto-trigger: the host has to fire the
# vibration (not implemented by this project yet).
# Run as root:  sudo python3 -I tools/haptic-probe.py [--out FILE] [--no-vibration]
import argparse
import glob
import os
import pwd
import select
import struct
import time

TP = "/sys/bus/i2c/devices/i2c-3030443150435341:00/0018:*"
EV_ABS, EV_KEY = 3, 1
ABS_MT_PRESSURE, ABS_PRESSURE, BTN_LEFT = 0x3A, 0x18, 0x110

uid = os.environ.get("SUDO_UID") or os.environ.get("PKEXEC_UID")
user = pwd.getpwuid(int(uid)) if uid else None
ap = argparse.ArgumentParser()
ap.add_argument("--out", default=os.path.join(user.pw_dir if user else ".", "haptic-probe.txt"))
ap.add_argument("--no-vibration", action="store_true")
opts = ap.parse_args()
log = []


def say(msg):
    print(msg, flush=True)
    log.append(msg)


hidraw = "/dev/" + os.path.basename(glob.glob(TP + "/hidraw/hidraw*")[0])
event = None
for inp in glob.glob(TP + "/input/input*"):
    if open(inp + "/name").read().strip().endswith("Touchpad"):
        event = "/dev/input/" + os.path.basename(glob.glob(inp + "/event*")[0])
say(f"touchpad: {event}, {hidraw}")


def measure(prompt, seconds=4):
    say(prompt)
    time.sleep(1.5)
    fd = os.open(event, os.O_RDONLY | os.O_NONBLOCK)
    values, clicks, end = [], 0, time.time() + seconds
    while time.time() < end:
        if not select.select([fd], [], [], 0.1)[0]:
            continue
        data = os.read(fd, 24 * 256)
        for i in range(0, len(data) - 23, 24):
            _, _, typ, code, value = struct.unpack("qqHHi", data[i:i + 24])
            if typ == EV_ABS and code in (ABS_MT_PRESSURE, ABS_PRESSURE) and value > 0:
                values.append(value)
            elif typ == EV_KEY and code == BTN_LEFT and value == 1:
                clicks += 1
    os.close(fd)
    if values:
        values.sort()
        say(f"  {len(values)} values, min={values[0]} median={values[len(values) // 2]} "
            f"p90={values[int(len(values) * 0.9)]} max={values[-1]}, clicks={clicks}")
    else:
        say(f"  no pressure values, clicks={clicks}")


measure("Step 1: in a moment, rest one finger LIGHTLY on the touchpad for 4 s and move it slowly ...")
measure("Step 2: in a moment, press FIRMLY on the touchpad several times for 4 s ...")

if not opts.no_vibration:
    say("Step 3: finger off the touchpad - 5 vibrations follow, 2 s apart (rest a hand lightly on it).")
    time.sleep(2)
    hd = os.open(hidraw, os.O_RDWR)
    for ordinal in range(3, 8):
        try:
            os.write(hd, bytes([0x45, ordinal, 4]))
            say(f"  pattern {ordinal} sent")
        except OSError as e:
            say(f"  pattern {ordinal}: error {e}")
        time.sleep(2)
    os.close(hd)

with open(opts.out, "w") as f:
    f.write("\n".join(log) + "\n")
if user:
    os.chown(opts.out, user.pw_uid, user.pw_gid)
say(f"Done -> {opts.out}. Which patterns (3-7) could you feel?")
