#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Touchpad diagnosis (PixArt 093A:4F01), read-only, 8 s:
# raw hidraw reports + all three evdev nodes + interrupt count + mode feature reports.
# Useful to tell apart "pad sends nothing", "pad stuck in mouse mode" and "data arrives but
# libinput ignores it" (the H7607BA case: pressure ~80-120 on a 0-65535 range, see install/06-touchpad.sh).
# Run as root:  sudo python3 -I tools/touchpad-diag.py [--out FILE]
import argparse
import fcntl
import glob
import os
import pwd
import select
import struct
import time

TP = "/sys/bus/i2c/devices/i2c-3030443150435341:00/0018:*"
uid = os.environ.get("SUDO_UID") or os.environ.get("PKEXEC_UID")
user = pwd.getpwuid(int(uid)) if uid else None
ap = argparse.ArgumentParser()
ap.add_argument("--out", default=os.path.join(user.pw_dir if user else ".", "touchpad-diag.txt"))
out = ap.parse_args().out
log = []


def say(msg):
    print(msg, flush=True)
    log.append(msg)


def irqs():
    for line in open("/proc/interrupts"):
        if "3030443150435341" in line:
            return sum(int(x) for x in line.split()[1:] if x.isdigit())
    return -1


def get_feature(fd, rid, size=8):
    buf = bytearray(size)
    buf[0] = rid
    try:
        n = fcntl.ioctl(fd, (3 << 30) | (size << 16) | (ord("H") << 8) | 0x07, buf)
        return bytes(buf[:n]).hex(" ")
    except OSError as e:
        return f"error {e.errno}"


hidraw = "/dev/" + os.path.basename(glob.glob(TP + "/hidraw/hidraw*")[0])
nodes = {}
for inp in sorted(glob.glob(TP + "/input/input*")):
    name = open(inp + "/name").read().strip().split()[-1]
    ev = glob.glob(inp + "/event*")
    if ev:
        nodes[name] = "/dev/input/" + os.path.basename(ev[0])
say(f"hidraw={hidraw} evdev={nodes}")

hfd = os.open(hidraw, os.O_RDWR | os.O_NONBLOCK)
say(f"feature 0x03 (input mode, 3 = touchpad): {get_feature(hfd, 0x03)}")
say(f"feature 0x05 (surface/button switch):    {get_feature(hfd, 0x05)}")
say(f"feature 0x06 (button type):              {get_feature(hfd, 0x06)}")

efds = {os.open(path, os.O_RDONLY | os.O_NONBLOCK): name for name, path in nodes.items()}
say("Now for 8 seconds: move a finger over the touchpad, tap a few times and press firmly ...")
time.sleep(1)
irq0, t0 = irqs(), time.time()
raw_ids, raw_samples = {}, []
ev_counts = {name: {} for name in nodes}
ev_samples = []
while time.time() < t0 + 8:
    ready, _, _ = select.select([hfd] + list(efds), [], [], 0.1)
    for fd in ready:
        data = os.read(fd, 4096)
        if fd == hfd:
            raw_ids[data[0]] = raw_ids.get(data[0], 0) + 1
            if len(raw_samples) < 25:
                raw_samples.append(f"{time.time() - t0:6.3f} len={len(data)} {data.hex(' ')}")
            continue
        name = efds[fd]
        for i in range(0, len(data) - 23, 24):
            _, _, typ, code, value = struct.unpack("qqHHi", data[i:i + 24])
            key = f"{typ}:{code:#x}"
            ev_counts[name][key] = ev_counts[name].get(key, 0) + 1
            if typ != 0 and len(ev_samples) < 40:
                ev_samples.append(f"{time.time() - t0:6.3f} {name} type={typ} code={code:#x} value={value}")
say(f"interrupts in 8 s: {irqs() - irq0}")
say(f"hidraw reports per id: { {hex(k): v for k, v in raw_ids.items()} }")
for name, counts in ev_counts.items():
    say(f"evdev {name}: {sum(counts.values())} events {dict(sorted(counts.items()))}")
log.append("--- hidraw samples")
log.extend(raw_samples)
log.append("--- evdev samples")
log.extend(ev_samples)
for fd in list(efds) + [hfd]:
    os.close(fd)
with open(out, "w") as f:
    f.write("\n".join(log) + "\n")
if user:
    os.chown(out, user.pw_uid, user.pw_gid)
say(f"Done -> {out}")
