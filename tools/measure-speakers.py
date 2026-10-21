#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Acoustic speaker measurement with the built-in microphone (run as your user, not root).
#
#   response: plays a 40 Hz - 20 kHz log sweep to --target and records it with --mic;
#             prints 1/3-octave band levels relative to 1 kHz (or absolute with --abs).
#   latency:  plays a 600 Hz burst (woofers only) and a 6 kHz burst (tweeters only) 0.6 s apart and
#             reports how much later the tweeters arrive than the woofers (+ = later). This is how the
#             20.5 ms CS35L56 DSP delay of the H7607BA woofers was found and compensated.
#
# The built-in microphone is not a measurement microphone: use the results for relative comparisons
# (before/after, branch A vs B), not as an absolute frequency response.
# EasyEffects moves every stream to its own sink; quit it first (easyeffects -q).
#
#   tools/measure-speakers.py response [--target proart_speakers] [--abs]
#   tools/measure-speakers.py latency  [--target proart_speakers] [--runs 3]
import argparse
import math
import os
import subprocess
import sys
import tempfile
import time
import wave

import numpy as np

RATE = 48000
BANDS = [63, 125, 250, 500, 1000, 2000, 3150, 4000, 6300, 8000, 10000, 12500, 16000]
DEFAULT_MIC = "alsa_input.platform-mtk_sdw_mc.HiFi__Mic__source"


def write_wav(path, mono):
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(np.repeat((np.clip(mono, -1, 1) * 32767).astype(np.int16), 2).tobytes())


def play_and_record(wav, target, mic, tmp):
    rec = os.path.join(tmp, "rec.wav")
    r = subprocess.Popen(["pw-record", "--target", mic, "--rate", str(RATE), "--channels", "2",
                          "--format", "s16", rec], stderr=subprocess.DEVNULL)
    time.sleep(0.8)
    subprocess.run(["pw-play", "--target", target, wav], check=True)
    time.sleep(0.8)
    r.terminate()
    r.wait()
    with wave.open(rec) as w:
        x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(float)
    os.remove(rec)
    return x.reshape(-1, 2).mean(axis=1)


def response(args, tmp):
    dur = 6.0
    t = np.arange(int(RATE * dur)) / RATE
    k = math.log(20000 / 40)
    sweep = np.sin(2 * math.pi * 40 * dur / k * (np.exp(t / dur * k) - 1))
    sweep *= np.minimum(1, np.minimum(t / 0.05, (dur - t) / 0.05))
    wav = os.path.join(tmp, "sweep.wav")
    write_wav(wav, sweep * 10 ** (args.level / 20))
    x = play_and_record(wav, args.target, args.mic, tmp)
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x)))) ** 2
    f = np.fft.rfftfreq(len(x), 1 / RATE)
    v = {fc: 10 * math.log10(spec[(f >= fc / 2 ** (1 / 6)) & (f < fc * 2 ** (1 / 6))].mean() + 1e-12)
         for fc in BANDS}
    ref = 0 if args.abs else v[1000]
    print("band (Hz): " + " ".join(f"{fc:>6}" for fc in BANDS))
    print(("abs (dB):  " if args.abs else "rel. 1 kHz:") + " ".join(f"{v[fc] - ref:+6.1f}" for fc in BANDS))


def latency(args, tmp):
    def burst(freq, ms):
        n = int(RATE * ms / 1000)
        return np.sin(2 * math.pi * freq * np.arange(n) / RATE) * np.hanning(n)

    woofer, tweeter = burst(600, 12), burst(6000, 3)
    t_w, t_t = 0.6, 1.2
    sig = np.zeros(int(RATE * 2.0))
    sig[int(t_w * RATE):int(t_w * RATE) + len(woofer)] += woofer * 0.4
    sig[int(t_t * RATE):int(t_t * RATE) + len(tweeter)] += tweeter * 0.4
    wav = os.path.join(tmp, "bursts.wav")
    write_wav(wav, sig)
    results = []
    for _ in range(args.runs):
        x = play_and_record(wav, args.target, args.mic, tmp)

        def arrival(template):
            c = np.abs(np.correlate(x, template, mode="valid"))
            return np.argmax(np.convolve(c, np.ones(48) / 48, mode="same")) / RATE

        results.append(((arrival(tweeter) - t_t) - (arrival(woofer) - t_w)) * 1000)
    print("tweeters relative to woofers (ms, + = later):",
          " ".join(f"{v:+.2f}" for v in results), "| median", f"{np.median(results):+.2f}")


def main():
    if os.geteuid() == 0:
        sys.exit("run this as your normal user (it needs your PipeWire session)")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["response", "latency"])
    ap.add_argument("--target", default="proart_speakers", help="sink node.name to play to")
    ap.add_argument("--mic", default=DEFAULT_MIC, help="source node.name to record from")
    ap.add_argument("--level", type=float, default=-14.0, help="sweep level in dBFS (response)")
    ap.add_argument("--abs", action="store_true", help="absolute band levels instead of relative to 1 kHz")
    ap.add_argument("--runs", type=int, default=3, help="repetitions (latency)")
    args = ap.parse_args()
    if subprocess.run(["pgrep", "-x", "easyeffects"], capture_output=True).returncode == 0:
        print("warning: EasyEffects is running and will capture the test signal (easyeffects -q)")
    with tempfile.TemporaryDirectory() as tmp:
        (response if args.mode == "response" else latency)(args, tmp)


if __name__ == "__main__":
    main()
