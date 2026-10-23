# Technical notes

What was broken on the ASUS ProArt P16 H7607BA under Ubuntu 26.04 and why the fixes in this
repository look the way they do.

## 1. Kernel: generic -> linux-nvidia >= 7.0.0-1023

- The generic Ubuntu kernel has no driver for the MT8901 I2C controllers (`NVDA0200`) and GPIO
  controller (`NVDA9221`): keyboard, touchpad and touchscreen do not exist.
- `linux-nvidia-hwe-26.04` (the "nvidia-bos" flavour, 7.0.0-2018) adds I2C/GPIO but no audio.
- `linux-nvidia` 7.0.0-1023 (resolute-proposed at the time of writing) adds NVIDIA's N1X audio stack
  (`soundwire-mtk`, `snd-soc-mt8901-afe`, `snd-sof-mt8901`, machine driver; NV-Kernels PRs #566/#567)
  and `nvidia_ffa_ec` bound to `ARML0002`.

## 2. SSPM hidden by `_OSI("Windows 2022")` -> `acpi_osi="!Windows 2022"`

On 7.0.0-1023 the new `power_wrap_drv` (`NVDA6210`) powers devices through SCMI. SCMI needs the SSPM
(`NVDA8400`), but its `_STA` is:

```
If (_OSI ("Windows 2022")) { Return (Zero) } Else { Return (0x0F) }
```

Linux answers `_OSI` for every Windows version, so SSPM is hidden, `scmi ret = -19`, and USB, I2C,
SPI and the audio DSP stay powered off (`pwrap probe failed`, `xhci-hcd ... error -22`): no internal
or external keyboard, no touchpad. The same pattern hides `COM1-3`, `SVP0`, `HFRP`, `NH1X`, `NMAP` -
devices the firmware deliberately exposes to non-Windows operating systems. With
`acpi_osi="!Windows 2022"` everything powers up. Side effect: the ASUS `MSOS` method reports
"Windows 2015" (`OSFG`) instead of "Windows 2022"; no impact was observed.

## 3. Battery: the EC echoes the ACPI requests

With 1023 + acpi_osi, `BAT0` appears with correct static data (design 99.9 Wh, 16.046 V, "ASUS
Battery") - those come from EC shared memory (`\_SB.AECB`, fields `B0DC/B0FC/B0DV`). All live values
are wrong: 0 %, 0 mV, AC offline, cycle count -989719533.

The cycle count gave it away: the AML computes `(RWEC(0xC4,{0x2F}) << 8) + RWEC(0xC4,{0x2E})`. With
the request `13 01 01 C4` echoed back unchanged, that is exactly `0xC5021413` = -989719533. So the
FF-A path returns success but the response never replaces the request in the AML buffer.

`drivers/proart-ffa-probe` sent the same commands directly with `FFA_MSG_SEND_DIRECT_REQ2`:

| request | response x4 | meaning |
|---|---|---|
| ASUS `0x15` (GBST) | `45a81852 000000e0` | current 0 mA, remaining 6226 mAh, 17832 mV |
| ASUS `0x0c` reg `0x90` | `3` | bit 0: AC present |
| ASUS `0x13` reg `0xc4/0x2e` | `2` | cycle count 2 |
| ODP battery `0x1`/`0x2`/`0x3` | `2`/`0`/`2` | not implemented by ASUS |

The EC answers direct requests correctly, so `drivers/proart-battery` polls it and registers
`BAT1`/`ADP1`, unbinding the broken ACPI `BAT0`/`AC0`. The ACPI path (FFH handler / AML buffer
round trip) should be fixed in the kernel eventually; until then this driver is the workaround.

### Fan modes, charge limit, fan speed (proart_battery 1.2)

The same broken path makes the ASUS WMI methods (`\_SB.ATKD.WMNB`, SSDT2) useless, and asus-wmi
is x86-only anyway. Their EC side is plain register traffic, so the driver repeats it:

- EC registers are read with `0x0c` and written with `0x0b` (`x4` as for reads, the value in `x5`
  bits 8..39 - the AML buffer puts `DATS` right after the 4-byte length).
- The WMI functions use a mailbox (AML `WEBC`/`REBC`): data at register `0x40`, command at `0x6e`,
  control at `0x6f`. Write: wait for control 0, data, control |= 0x80, command. Read: control |=
  0x20, command, wait for bit 7, read data, control |= 0x40.
- `DEVS 0x00120075` (MyASUS fan mode): clear bit 0 of EC register 5 (`0xc4` read / `0xc5`
  write), mailbox `0x23` [0] and `0x2a` [0], once per boot a clean-up of EC RAM `0xd000`/`0xd800`
  while `\_SB.ECFG` is 1, bit 0 of register 5 set for silent, then mailbox `0x11` [mode, 0] with
  mode 1 standard, 4 performance, 2 silent. Registered as platform profile
  `balanced`/`performance`/`quiet`, which power-profiles-daemon shows as GNOME's power modes.
- `DEVS 0x00120057` (MyASUS battery care): mailbox `0x06` [percent, 0]. Mailbox read `0x05`
  returns the limit in byte 0 (bit 7 set while no limit was ever applied: `e4` = 100 %). The EC
  ignores requests for about a second afterwards (the AML sleeps 1 s), so the driver waits too.
  Exposed as `charge_control_end_threshold`. UPower only imports its `CHARGE_LIMIT` hwdb entry
  for batteries with a start threshold, so `config/udev/61-proart-battery.rules` adds it for BAT1;
  GNOME then shows "Preserve battery health" (80 %).
- Fan speed: EC registers `0xc6`/`0xc7` (rpm, as `FAN0._FST`); the ACPI fan (`PNP0C0B:00`, which
  reported 164613644 rpm) is unbound.
- Thermal zones: TSOC, TS0E/TS0P/TS1E/TS1P, TGPU, TDLA and TUNC read SoC sensor registers
  (MMIO) and are real. `PSYS` and `PSOC` return system and SoC power in mW (PSYS 30.1 W while the
  battery delivered 32.3 W; PSOC 65 W at full load in performance mode), which Linux showed as
  1000-6000 C. `THRM` (EC register `0x98`) and `THZ0` (EC RAM `0x0700`) go through the broken EC
  path and only return fallback values (60 C, 19 C). The driver unbinds these four and reports
  fan, both EC temperatures and both power values through hwmon `proart_ec`.

- Power off: after `systemctl poweroff` the laptop could not be switched on with the power
  button until the charger was plugged in, and the RTC came back as 2000-01-01 - the EC had cut
  the battery. Reboots and forced power-offs (holding the button) kept the RTC. arm64 Linux
  reboots via UEFI `ResetSystem()` but powers off via PSCI `SYSTEM_OFF`; the ACPI sleep control
  register is empty and there is no `_PTS`. proart_battery 1.4 powers off via
  `ResetSystem(EfiResetShutdown)` (sys-off handler above PSCI's priority). Verified: power-off on
  battery without the fix -> RTC 2000-01-01 and boot only with the charger; with the fix -> RTC
  correct two minutes later and boot on battery with the power button.

Measured on battery, 35 s full load on all cores, real clock from the CPPC feedback counters:

| GNOME mode | ASUS mode | all-core clock | fan | battery draw |
|---|---|---|---|---|
| Power Saver | silent (2) | 2.1 GHz | 2500-3000 rpm | 38 W |
| Balanced | standard (1) | 3.0 GHz | up to 4800 rpm | 74 W |
| Performance | performance (4) | 3.2 GHz (single cores 3.5) | up to 6500 rpm | 89 W |

## 4. Audio

### 4.1 UCM profile

The card only offered a dummy output: Ubuntu's alsa-ucm-conf has no profile for `mt8901-soundwir`.
NVIDIA's profiles (alsa-ucm-conf PR #862) select `HiFi-cs42l43-cs35l56x2.conf` for this laptop
(CS42L43 + 2x CS35L56, all on link 1). Speakers, headphones, internal and headset mic work with it.

Local changes to that file: the amps run at 0 dB (see 4.2), and the port names are the ones GNOME
shows. GNOME labels the ports of a card "<port> – <card>", so `51-proart-names.conf` gives the card
an empty description and the UCM comments read "ProArt P16 Microphone", "ProArt P16 Headphones" and
"ProArt P16 Headset Microphone". The woofer port is hidden (`api.acp.hidden-ports`), since the
speakers are the 2-way sink of 4.3. PipeWire never enables a hidden port (route selection skips it,
`acp_device_set_port` refuses it), so the woofer amp switches moved from the Speaker device to the
verb's enable sequence.

### 4.2 ASUS speaker tuning and the missing SSID

The CS35L56 amps logged `FIRMWARE_MISSING` / "Calibration disabled": linux-firmware has no tuning
for SSID `1043:1484`. ASUS ships it in its Windows audio driver
(`XU_Ext/tn/35L56/1484/dflt/b0_dflt_1484_{lw_l1u0,rw_l1u1}.bin` + `fw/35L56/3.13.4/.../*.wmfw`).
Installing them was not enough: cs35l56 derives `dsp.system_name` from the card's PCI SSID
(`snd_soc_card_get_pci_ssid`) or the `cirrus,firmware-uid` property, and the MT8901 machine driver
sets neither, so only generic file names were tried. One generic file for both amps is wrong - the
left/right tunings differ in real parameters (e.g. at offset 2272: `00 00` vs `FF FF 7F`).
`drivers/proart-audio` attaches `cirrus,firmware-uid = "10431484"`; afterwards both amps load
firmware v3.13.4 plus their own tuning and report "Calibration applied".

### 4.3 The laptop has 2-way speakers; NVIDIA's profile drives only the woofers

The sound stayed dull ("behind something"). Measured with the built-in microphone, the woofer
output collapses above ~3 kHz (-40 dB at 4 kHz relative to 1 kHz). The ASUS tuning files are called
`lw`/`rw` - left/right **woofer** - and low-pass on purpose. The CS42L43 has its own speaker amp
(`cs42l43 Speaker Digital Switch` was off, `Speaker L/R Input 1` = None): that is where the
**tweeters** are. Routing `DP5RX1/2` to it and playing on the `DL1` (UCM "Headphones") stream:

| band (abs, dB) | 1 kHz | 3.15 kHz | 4 kHz | 8 kHz | 10 kHz | 16 kHz |
|---|---|---|---|---|---|---|
| woofers only | 146 | 129 | 107 | 109 | 101 | 94 |
| tweeters only (HP 2.5 kHz) | 104 | 133 | 129 | 126 | 122 | 117 |

Feeding the tweeters from `DL0` (`PDI2 -> DP2`) only works while a `DL1` stream keeps the codec's
`DP5` port running, and then two host ports write the same codec port - not usable. The fix is a
software crossover (`config/pipewire/60-proart-2way.conf`), which is also what Dolby does on Windows:

- virtual sink `proart_speakers` -> tone control -> limiter -> split
- woofer branch: full range to `DL0` (the ASUS tuning does the low-pass)
- tweeter branch: Linkwitz-Riley 4th-order high-pass 1.8 kHz -> high shelf from 5.5 kHz -> +9 dB ->
  delay -> LSP limiter (-1 dBFS; the CS42L43 digital gain clips above 0 dBFS) -> `DL1`
- a 4-channel `module-combine-stream` sink sends both branches to the two hardware sinks

### 4.4 Time alignment: 20.5 ms

`tools/measure-speakers.py latency` plays a 600 Hz burst (woofers only) and a 6 kHz burst
(tweeters only) in one stream. The tweeters arrived **20.5 ms earlier** (three runs: -21.5, -20.5,
-20.3 ms) - the processing delay of the CS35L56 DSP. The tweeter branch is delayed by 20.5 ms;
measured afterwards: +0.04 / +0.13 / +0.29 ms.

Result relative to 1 kHz (woofers only -> final 2-way): 4 kHz -40 -> -10 dB, 8 kHz -44 -> -17 dB,
16 kHz -56 -> -28 dB (the built-in microphone itself rolls off at the top end).

### 4.5 Headphone jack

The tweeters and the headphone amp share `DL1`/`DP5`. `user/bin/proart-tweeter` (systemd user
service) watches the `Headphone Jack` control (`iface=CARD`) with `alsactl monitor`: on insert it
mutes the tweeter amp and makes "ProArt P16 Headphones" the default sink, on removal it reverts.

### 4.6 Don't let the internal microphone drive the speakers

PipeWire puts nodes that are linked to each other into one graph, and the device with the highest
`priority.driver` clocks it. The internal mic (`HiFi__Mic__source`, ALSA default 1616) outranks the
speakers (1000). On its own that is harmless. But an app that links the mic and the speakers, such
as `module-echo-cancel` with `monitor.mode` on the default sink (a voice assistant's echo filter),
makes the mic the clock for every sound. After a few minutes the mic's timer-based scheduling
derails: the driver waits ~44 ms per 5.3 ms quantum (pw-top W/Q ~8), the capture PCM hits XRUN
several times a second, `spa.audioconvert: out of buffers` repeats every ~2.5 s, and notifications,
calls and music crackle. The DMA itself keeps running at 48 kHz (hw_ptr), RT priorities are set and
the SoundWire port setup is consistent, so this is a timing issue in the MT8901 capture path.

Workarounds tried that make it worse: the mic as follower (`priority.driver` below the speakers)
resyncs constantly; interrupt-driven scheduling (`api.alsa.disable-tsched`, 256-frame periods)
gave ~900 XRUNs per minute. What works: keep the mic and the speakers in separate graphs, i.e. no
echo filter or sink-monitor tap together with the internal mic. With a plain capture stream on the
mic, measured over 2-3 minutes with notifications playing: 0 XRUNs, 48000 frames/s, 0 errors.

### 4.7 Measurement pitfalls

- After a PipeWire restart, WirePlumber picked the monitor of the new virtual sink as the default
  source; recordings then contained the digital signal, not the microphone. Always pass `--target`.
- EasyEffects moves every stream (also `pw-play --target ...`) to its own sink; quit it before measuring.
- The CS42L43 `Speaker Digital Volume` applies live; it compressed at +12 dB because the test
  signal plus shelf exceeded 0 dBFS.

## 5. Video: hardware decoding in Firefox

4K YouTube stuttered: Firefox's RDD process used 300-700 % CPU, the GPU decoder 0 %.

- The Ubuntu Firefox snap gets its graphics stack from the `mesa-2404` content snap and cannot
  use the NVIDIA driver at all. Mozilla's arm64 `.deb` uses the system libraries.
- Firefox 158 blocklists hardware video decoding for every NVIDIA GPU on Linux
  (`FEATURE_HARDWARE_VIDEO_DECODING_NO_LINUX_NVIDIA`). `media.hardware-video-decoding.force-enabled`
  overrides that (a user force-enable ranks above the blocklist in `FeatureState::GetValue`);
  `gfx.blocklist.all = -1` does not, it is ignored in release builds.
- VA-API: `nvidia-vaapi-driver` 0.0.14 decodes on the N1X (vainfo: AV1, VP9 incl. profile 2,
  HEVC Main/10/12, H.264), but cannot export the decoded surfaces (`direct_realiseSurface: Unable
  to realise surface`; `vaExportSurfaceHandle` fails with `NVD_BACKEND=direct` and `egl`).
  Firefox's VA-API path needs the export and falls back to dav1d/libvpx after the first frame.
- Vulkan video decoding works: Firefox picks the "NVIDIA RTX Spark N1X" Vulkan device, NVDEC
  decodes and the frames go to the compositor as DMA-BUF. Release builds block it for all GPUs
  (`FEATURE_VIDEO_DECODING_VULKAN_DISABLED`, allowed only in Nightly for NVIDIA >= 580.76.5);
  `media.hardware-video-decoding-vulkan.force-enabled` lifts that. Measured with 4K test clips:
  AV1 NVDEC 3-4 %, VP9 8-9 %, H.264 6 %, RDD process 0-10 % CPU, no software fallback.
  YouTube 2160p60 (VP9/AV1): NVDEC 11-19 %, RDD process 20-30 % CPU instead of 260-700 %.
- `install/07-video-firefox.sh` puts these prefs into `/usr/lib/firefox/defaults/pref/`, so
  they apply to every profile (`config/firefox/proart-nvidia.js`). The environment
  (`MOZ_DISABLE_RDD_SANDBOX=1` for `/dev/nvidia*`, `LIBVA_DRIVER_NAME`, `NVD_BACKEND`) comes from
  `user/install-user.sh`.
- Make sure the dock/default browser points to `firefox.desktop`, not `firefox_firefox.desktop` (snap).

### Snap apps render on the CPU

The cause above is general: on the N1X, `libnvidia-eglcore`, `-glcore` and `-glsi` link against
`libnvidia-rmapi-tegra.so`. snap-confine exposes host NVIDIA libraries to snaps from a fixed list
(`cmd/snap-confine/mount-support-nvidia.c`, checked against snapd 2.77.1 and master), and that
list has no `libnvidia-rmapi-tegra`. `libEGL_nvidia` then fails to load inside every snap and
glvnd silently falls back to Mesa llvmpipe. Seen with a Qt WebEngine snap that used
40-350 % CPU for its window.

`LD_LIBRARY_PATH` cannot be passed into a snap here (snap.yaml overrides it), so
`install/09-snap-gpu.sh` installs a glvnd EGL vendor shim (`drivers/snap-egl-shim/`):

- `/usr/lib/aarch64-linux-gnu/libnvidia-snap-egl.so` loads `libnvidia-rmapi-tegra.so.*` by its
  `/var/lib/snapd/hostfs` path, then forwards `__egl_Main` to `libEGL_nvidia.so.0`. Once a library
  with that soname is loaded, the linker satisfies the `DT_NEEDED` entries with it.
- `/usr/share/glvnd/egl_vendor.d/09_nvidia_snap.json` points to the shim's hostfs path. snapd links
  `*nvidia*.json` from that directory into every snap. On the host the path does not exist, so
  glvnd skips the vendor.
- The `libnvidia*` name matches snapd's AppArmor rule for host NVIDIA libraries.

Test inside `snap run --shell <snap>` with a surfaceless EGL context: without the shim
"Mesa / llvmpipe", with it "NVIDIA / NVIDIA RTX Spark N1X". Only EGL is covered (GLX and Vulkan
inside snaps still fail). The proper fix is adding `libnvidia-rmapi-tegra.so*` to snapd's list.

## 5b. Power saving

- PCIe ASPM: the firmware leaves L1 and the L1 substates off on every link (SSD, Wi-Fi, SD reader)
  although `_OSC` hands PCIe control to the OS. Linux' `default` ASPM policy keeps the firmware
  setting, and the per-device `link/l1_aspm` switches have no effect under that policy.
  `powersupersave` (L1 + L1.1/L1.2) ran without AER/link errors under a 2 GB direct read, a full
  Timeshift snapshot and Wi-Fi traffic, and under ~28 W of desktop load the difference was within
  the measurement noise. But with it, s2idle sleeps of more than a few minutes did not wake up
  (the log ends at `PM: suspend entry`; with ASPM on, the nvme driver keeps the SSD in D0 with
  APST + L1.2 over suspend instead of shutting it down). With the `default` policy long sleeps wake
  up, so the policy stays at `default`; `install/10-power.sh` removes the setting of earlier
  versions.
- The SD reader (GL9767, `sdhci-pci`) cannot runtime-suspend: sdhci-pci only allows it with a
  card-detect GPIO, so it stays in D0.
- Display: 3840x2400 at 120 Hz runs in mutter's variable refresh mode (30-120 Hz) already.
- CPU: EAS is active (`sched_energy_aware=1`, capacities 699 / 998 / 1024), cpuidle uses the
  LPI WFI and core-off states, USB devices runtime-suspend, PipeWire suspends the codecs when idle.

## 5c. Phone calls through a paired phone

PipeWire 1.6's native Bluetooth backend can act as the hands-free unit (HFP HF) for a phone and
publish it over D-Bus (`bluez5.telephony-dbus-service`). GNOME Calls only has an oFono provider:

- The real oFono package conflicts with ModemManager in Ubuntu; installing it removes GNOME Calls.
- PipeWire's oFono emulation (`bluez5.telephony.provide-ofono`) returns the modem without the
  `Interfaces` property (Calls only accepts modems with `org.ofono.VoiceCallManager` there) and
  has a one-argument `Dial` (oFono: number + caller-ID mode).
- `bluez5.telephony.use-system-bus = false` is ignored in 1.6.2; the service is always on the
  system bus, so the desktop user needs a policy to own the names.
- Calls are announced on each phone object's own ObjectManager (`.../ag1`), not on the root.

`user/bin/proart-phone-bridge` owns `org.ofono`, presents every PipeWire phone as a modem (name
from BlueZ) and forwards Dial/Answer/Hangup. GNOME Calls' mute and speaker buttons go through
callaudiod, which looks for a phone sound card with a voice-call profile and fails here; the
bridge also provides `org.mobian_project.CallAudio` and mutes the microphone stream PipeWire
sends to the phone. A Xiaomi 15T negotiated LC3-SWB first and fell back to CVSD (narrowband);
WirePlumber links the call streams to the default output (the 2-way speakers) and microphone.

## 5d. Package updates

Some parts of the setup sit next to package files. `install/11-protect.sh` keeps them:

- The UCM profile is in alsa-ucm-conf's directory, but no package ships it yet (alsa-ucm-conf PR #862).
  Once one does, dpkg would overwrite the local changes, and the woofers would stay silent because their
  port is hidden (4.1). Local `dpkg-divert`s make dpkg put the package's copies next to ours as
  `*.distrib`; `tools/check.sh` reports when that happens.
- The packages the setup needs (e.g. `lsp-plugins-lv2` for the crossover's limiters) are marked as
  manually installed, so `apt autoremove` keeps them.
- An apt hook (`/etc/apt/apt.conf.d/80-proart-p16` → `config/apt/proart-after-apt`) runs after every
  package change. It rebuilds each user's WirePlumber mute fix (user/install-user.sh) from the new
  `state-stream.lua`, or removes it once the fix no longer applies, so a WirePlumber update never runs
  next to a stale copy. It also builds missing ProArt DKMS modules for every installed kernel. The
  `linux-nvidia-hwe` meta package pulls in newer kernel flavours that the install scripts did not build
  for; GRUB stays on the saved entry from install/01-kernel.sh.

## 6. Touchpad

The touchpad delivered ~120 reports/s with positions, pressure and even `BTN_LEFT` on firm presses,
but the pointer did not move: pressure ~80-120 on a declared range of 0-65535 is below libinput's
touch threshold. The libinput quirk removes the pressure axes. The pad is a haptic pressure pad:
the actuator responds to HID output report `0x45` (waveform ordinal 3-7, intensity 0-4), but the
descriptor has no auto-trigger, so no vibration happens on click unless the host triggers it.
The kernel's hid-haptic (built in, `CONFIG_HID_HAPTIC=y`) only takes over pads with both an auto
and a manual trigger, so it ignores this one. `proart-haptic.service` reads `BTN_LEFT` from the
touchpad's event device and writes report `0x45` to its hidraw node: waveform 5 on press,
3 on release, intensity 3. Feature report `0x35` lists the five waveforms (ordinals 3-7) with
durations of 13, 21, 24, 26 and 28 ms.

## 7. Keyboard

`hid-asus` already knows `0B05:4B42` and has an OOBE-disable sequence for "ProArt P16", but sends it
from `asus_kbd_register_leds()`, which never runs for this keyboard on arm64 (the backlight normally
goes through asus-wmi, x86-only). Result: the backlight keeps fading in and out (OOBE demo mode), no
backlight control, `Fn+Esc` does nothing. Omarchy's patches address all three (`drivers/hid-asus-proart`).

Two more problems showed up on the P16 and are fixed by patches 0005/0006 of this repository:

- **Backlight key (F4).** The keyboard sends vendor report `5a c7` (usage `0xc7`), which hid-asus maps
  to `KEY_KBDILLUMTOGGLE` and only forwards to asus-wmi. Without asus-wmi the key reached GNOME,
  which treats it as on/off - no intermediate levels and no level in the OSD. Patch 0005 handles the
  backlight keys in the driver when it owns the LED (cycle off/1/2/3, up/down clamp), keeps them from
  userspace and reports `brightness_hw_changed`, so UPower emits a hardware change and GNOME shows the
  level bar.
- **Fn-lock state.** The state lived only in the driver. Patch 0006 adds `fn_lock` to the HID device
  (1 = F1-F12 first, 0 = media keys first) with `sysfs_notify()` on `Fn+Esc`; `user/bin/proart-fnlock`
  polls it (POLLPRI) and shows an AppIndicator label (`F1–F12` / `Media`) plus a transient notification.
  GNOME's own OSD (`org.gnome.Shell.ShowOSD`) is not allowed for third-party callers.
- **Installing into a running session.** UPower and gsd-power look for keyboard backlights only at
  startup; gsd-power then keeps a 0..0 range (`gsd_power_backlight_abs_to_percentage: assertion
  'max > min' failed` on every F4 press). gsd-power refuses `systemctl --user restart`
  (`RefuseManualStart/Stop`) but is `Restart=on-failure`, so `install/05-keyboard.sh` restarts UPower
  and SIGKILLs gsd-power. After a reboot both find the LED on their own.

## 8. Face login (Howdy) and polkit

The IR camera works (alternating lit/dark frames from the strobing emitter, hence
`dark_threshold = 90`). Howdy 3 builds from source. Two pitfalls:

- `polkit-agent-helper@.service` runs in a strict sandbox (`PrivateDevices=yes`,
  `DevicePolicy=strict`, `MemoryDenyWriteExecute=yes`): Howdy cannot open the camera, prints an
  error line that GNOME's agent does not understand, and every admin dialog / `pkexec` hangs.
  Default here: skip Howdy for `polkit-1`. `optional/howdy-polkit.sh` opens the sandbox for cameras
  instead (security trade-off, revertible).
- A face login cannot unlock the GNOME login keyring (it is encrypted with the password).
- With one face model and the defaults (timeout 4 s, certainty 3.5) Howdy timed out often (the lit IR
  frames were usable: ~63 % dark pixels, below `dark_threshold`). `optional/howdy.sh` sets 8 s and 4.0;
  enrolling 3-4 models (head angle, light, glasses) helps most. Howdy runs once per authentication,
  starting when the lock screen wakes: after a timeout the lock screen only waits for the password.
  Pressing Enter on the empty password field fails that attempt and starts a new one with Howdy.

## 9. Not solved

- Battery through ACPI (kernel FFH/AML response path) - worked around by `proart_battery`.
- Dolby Atmos (Windows-only); EasyEffects presets are an approximation.
- Ambient light sensor: behind the HID-over-SPI sensor hub `SENH` (`MSFW1111`, SPI3). Linux 7.0
  has no generic HID-over-SPI driver (the spi-hid series is still under review), so no automatic
  brightness. The webcam's presence sensor (iio `prox`) works.
- ASUS fan/performance profiles: solved in `proart_battery` 1.2 (see section 3).
- Audio after s2idle sleeps of more than a few minutes: the cs42l43 (mic, jack, tweeters) stops
  delivering data until a reboot. Reloading the audio drivers does not help; keeping the audio
  power domain on during sleep is being tested.
- The internal mic as PipeWire graph driver derails after minutes (section 4.6).
- GPU power on battery: under Linux the GPU stays at about 20 W on battery (nvidia-smi clocks
  event reason "Reliability", SM ~1.0 GHz; measured in Performance mode); on AC it reaches 37 W+. Windows
  keeps nearly full GPU performance on battery (Notebookcheck: Cyberpunk 2077 QHD 56.2 fps on battery
  vs 56.8 fps on AC). The ASUS side is not the limit: WMI `0x00120075` (fan mode) is the only
  mode switch, `0x001200A0`/`0x001200A3` set PL2/PL1 (EC mailbox `0x28`/`0x29`) with no DC
  variant, and the CPU reaches ~80 W on battery. The GPU limit comes from NVIDIA: the NVPCF `_DSM`
  (`NPCF`, `NVDA0820`, version 3.0) returns an encrypted 128-byte table, the firmware has no GPS
  `_DSM` (the interface an x86 SBIOS uses to steer TGP on AC/DC transitions), `nvidia-powerd`
  (Dynamic Boost) is not shipped for arm64, and `nvidia-smi` reports every power limit as N/A.
  So there is no Linux-side setting; it needs an NVIDIA driver change.
