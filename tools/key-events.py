#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Record key events of the ASUS ProArt P16 internal keyboard (0B05:4B42) for a few seconds and log the
# keyboard backlight level next to them. Needs root to read /dev/input.
#   Usage: pkexec python3 -I key-events.py [seconds]
import glob
import os
import select
import struct
import sys
import time

SECONDS = float(sys.argv[1]) if len(sys.argv) > 1 else 10
LED = "/sys/class/leds/asus::kbd_backlight/brightness"
EV_KEY, EV_MSC = 0x01, 0x04
NAMES = {}
try:
    import evdev.ecodes as ec  # optional, only for nicer key names
    NAMES = {v: k for k, v in ec.KEY.items() if isinstance(k, str)}
except ImportError:
    pass

devices = []
for inp in glob.glob("/sys/bus/hid/devices/*0B05:4B42*/input/input*"):
    for ev in glob.glob(inp + "/event*"):
        devices.append("/dev/input/" + os.path.basename(ev))
if not devices:
    sys.exit("keyboard 0B05:4B42 not found")

fds = {os.open(d, os.O_RDONLY | os.O_NONBLOCK): d for d in devices}
# raw HID reports (before any driver mapping)
raw = {}
for hr in glob.glob("/sys/bus/hid/devices/*0B05:4B42*/hidraw/hidraw*"):
    raw[os.open("/dev/" + os.path.basename(hr), os.O_RDONLY | os.O_NONBLOCK)] = os.path.basename(hr)
led = lambda: open(LED).read().strip() if os.path.exists(LED) else "-"
time.sleep(2)
print(f"Recording {SECONDS:.0f} s from {', '.join(devices)} - press the keys now (backlight now {led()})", flush=True)
end = time.time() + SECONDS
while time.time() < end:
    ready, _, _ = select.select(list(fds) + list(raw), [], [], 0.2)
    for fd in ready:
        if fd in raw:
            print(f"  raw {raw[fd]}: {os.read(fd, 256).hex(' ')}", flush=True)
            continue
        data = os.read(fd, 24 * 64)
        for i in range(0, len(data) - 23, 24):
            _, _, typ, code, value = struct.unpack("qqHHi", data[i:i + 24])
            if typ == EV_KEY:
                state = {0: "up", 1: "down", 2: "repeat"}.get(value, value)
                print(f"key {code:#05x} {NAMES.get(code, ''):22} {state:6} backlight={led()}", flush=True)
            elif typ == EV_MSC:
                print(f"  scancode {value:#x}", flush=True)
for fd in list(fds) + list(raw):
    os.close(fd)
time.sleep(0.5)
print(f"done, backlight now {led()}")
