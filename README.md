# Linux on the ASUS ProArt P16 H7607BA (NVIDIA N1X / RTX Spark)

Scripts, small kernel drivers and configuration that make Ubuntu 26.04 usable on the ASUS ProArt
P16 H7607BA, an arm64 laptop with the NVIDIA N1X SoC. Everything here was worked out on one unit;
see [docs/technical-notes.md](docs/technical-notes.md) for the why and
[docs/hardware.md](docs/hardware.md) for the hardware map.

> Status: community bring-up, not supported by ASUS or NVIDIA. Several steps use kernel packages from
> Ubuntu's `-proposed` pocket and out-of-tree drivers. Keep a fallback kernel in the GRUB menu.


> **Disclaimer.** This is an unofficial community project. It installs a kernel from Ubuntu's
> `-proposed` pocket, changes the operating system the firmware sees (`acpi_osi`), loads out-of-tree
> kernel modules, installs speaker firmware and changes the login (PAM) configuration. It was tested
> on **one** ASUS ProArt P16 H7607BA with BIOS H7607BA.300 and Ubuntu 26.04 only. Use it at your own
> risk; there is **no warranty** of any kind (see [`LICENSE`](LICENSE)). Keep a fallback kernel in
> GRUB and a backup of your data.
>
> Not affiliated with or endorsed by ASUS, NVIDIA, MediaTek, Cirrus Logic, Dolby, Canonical or
> Mozilla. ASUS, ProArt, NVIDIA, RTX, Dolby and all other trademarks belong to their respective owners
> and are used only to describe the hardware this project supports.

### Before you start

- **Kernel and boot:** `install/01-kernel.sh` installs `linux-nvidia` from `-proposed` and adds
  `acpi_osi="!Windows 2022"`. If the system does not boot, choose the previous kernel under
  *Advanced options* in GRUB.
- **Speaker firmware:** `install/03-audio.sh` downloads ASUS' Windows audio driver, checks its
  SHA-256 and extracts the Cirrus tuning files. Wrong tuning files could stress the speakers; the
  script only accepts the exact file it was tested with.
- **Face login:** `optional/howdy-polkit.sh` lets admin dialogs accept your face by opening the
  polkit helper's sandbox for cameras. Read its header before using it.

## Hardware status

| Component | Stock Ubuntu 26.04 | With this project |
|---|---|---|
| Keyboard, touchpad, touchscreen + stylus | not detected | works (linux-nvidia kernel; touchpad needs the libinput quirk) |
| Keyboard backlight | blinks constantly (OOBE demo mode), no control | steady (OOBE off); F4 cycles off/1/2/3 with the GNOME level OSD; slider in the status menu (patched hid-asus, verified) |
| Fn keys / Fn-lock | Fn-lock (Fn+Esc) does nothing | media keys first, Fn+Esc switches; state shown in the top bar and as a notification (`proart-fnlock`) |
| Display (3840x2400 OLED) | framebuffer only, 60 Hz, no acceleration | NVIDIA 615, 120 Hz |
| GPU video decoding | - | NVDEC via VA-API works (vainfo: AV1/VP9/HEVC/H.264); Firefox playback with all prefs not yet verified |
| Speakers | no sound card | 2-way speakers: ASUS woofer tuning, tweeters enabled, time-aligned crossover, tone control |
| Headphone jack, internal mic, headset mic | no sound card | works (NVIDIA UCM profile); tweeters mute when headphones are plugged in |
| Battery / AC adapter | 0 % / not detected | works (`proart_battery`): level, charging/discharging, power draw and time remaining (verified) |
| Power modes (GNOME) | Balanced / Power Saver do nothing | Performance / Balanced / Power Saver switch the ASUS fan modes (performance / standard / silent): 3.2 / 3.0 / 2.1 GHz all-core |
| Battery charge limit | - | GNOME "Preserve battery health" stops charging at 80 % (ASUS battery care) |
| Sensors | fan 164613644 rpm, "temperatures" of 1000-6000 C | fan rpm, EC temperatures, system and SoC power (`proart_ec` hwmon); misleading ACPI zones hidden |
| GPU in snap apps | CPU rendering (llvmpipe): snapd does not expose `libnvidia-rmapi-tegra` | NVIDIA EGL through a small glvnd shim (`install/09-snap-gpu.sh`) |
| Wi-Fi, Bluetooth | works | works |
| Webcam, IR camera | works | works; 50 Hz anti-flicker; optional face login (Howdy: login, lock screen, sudo, optionally admin dialogs) |
| USB-C, second M.2 slot | works / slot empty | unchanged (second slot: 2280, single-sided SSDs only per ASUS) |
| Haptic touchpad feedback | no vibration on click | click felt on press and release (`proart-haptic.service`, strength adjustable) |
| Battery through ACPI | - | **not working**: the EC echoes the ACPI requests; `proart_battery` is the workaround |
| Dolby Atmos | - | **not available** on Linux; EasyEffects presets as an approximation |

## Tested versions

| | |
|---|---|
| Laptop | ASUS ProArt P16 H7607BA, BIOS H7607BA.300 (2026-08-11) |
| OS | Ubuntu 26.04 LTS (resolute), GNOME 50 on Wayland |
| Kernel | `linux-nvidia` 7.0.0-1023.24 (resolute-proposed) with `acpi_osi="!Windows 2022"` |
| NVIDIA | 615.71.09 open kernel modules (prebuilt), nvidia-vaapi-driver 0.0.14 |
| Audio | PipeWire 1.6.2, WirePlumber 0.5.13, alsa-ucm-conf 1.2.15.3 + NVIDIA's mt8901 profiles |
| Other | libinput 1.31.1, Firefox 158 (Mozilla arm64 .deb), EasyEffects 8.1.2 |

## Install

Run the root steps with `sudo` (or `pkexec`) from the repository folder, in this order:

```
sudo bash install/01-kernel.sh        # linux-nvidia + NVIDIA kernel modules, acpi_osi, GRUB default
sudo bash install/02-nvidia.sh        # NVIDIA user space
sudo reboot
sudo bash install/03-audio.sh         # UCM profile, ASUS speaker tuning, proart_audio
sudo bash install/04-battery.sh       # proart_battery: battery, fan modes, charge limit
sudo bash install/05-keyboard.sh      # patched hid-asus (backlight levels + OSD, Fn-lock, no blinking)
sudo bash install/06-touchpad.sh      # libinput quirk
sudo bash install/07-video-firefox.sh # nvidia-vaapi-driver, Firefox from Mozilla's APT repo
sudo bash install/08-camera.sh        # webcam anti-flicker 50 Hz (skip on 60 Hz mains)
sudo bash install/09-snap-gpu.sh      # NVIDIA EGL for snap apps (otherwise they render on the CPU)
sudo bash install/10-power.sh         # PCIe ASPM for SSD, Wi-Fi, SD reader (firmware leaves it off)
sudo reboot
user/install-user.sh                  # as your user: speaker crossover, tweeter service, names, VA-API env,
                                      #   Fn-lock top-bar indicator
user/firefox-vaapi.sh ~/.mozilla/firefox/<profile>   # as your user, Firefox closed
```

Then log out and back in once. Tone control for the speakers:

```
proart-eq                    # show: bass, mid, presence, treble (dB)
proart-eq bass=3 treble=0    # change live; saved in the PipeWire config
proart-eq 2 3 3 1            # all four at once
```

### Optional

```
sudo bash optional/perf-mode.sh            # perf-mode performance|balanced|quiet (cpufreq governor)
sudo bash optional/howdy.sh                # face login with the IR camera: build + configure
sudo /usr/local/bin/howdy -U $USER -y add  # enroll your face - repeat 3-4 times (straight on, head
                                           #   slightly lowered, other light, with/without glasses)
sudo bash optional/howdy-enable.sh         # login, lock screen, sudo (not admin dialogs)
sudo bash optional/howdy-polkit.sh         # ALSO admin dialogs - weakens a sandbox, read the header first
sudo bash optional/easyeffects.sh          # EasyEffects + presets (not needed with the crossover;
                                           #   add --autostart for login start)
sudo bash optional/nvbroadcast.sh          # NV Broadcast (community app, CPU modes on arm64) + v4l2loopback
sudo bash optional/ui-control.sh           # ydotool for scripted desktop control
```

### Diagnostics (`tools/`)

| Tool | Purpose |
|---|---|
| `measure-speakers.py response\|latency` | sweep response and woofer/tweeter time alignment with the built-in mic (as user) |
| `ffa-probe.sh` | raw answers of the EC services behind FF-A (root) |
| `touchpad-diag.py`, `haptic-features.py`, `haptic-probe.py` | touchpad reports, haptic controller, pressure/vibration (root) |
| `dump-acpi.sh` | copy and decompile the ACPI tables (root) |
| `key-events.py [seconds]` | key events and raw HID reports of the internal keyboard next to the backlight level (root) |

### Notes

- **Howdy** makes one attempt per authentication. After a timeout the lock screen waits for the
  password; press `Esc` and any key to start a new attempt with face recognition.
- **Fn-lock indicator**: `F1–F12` = function keys first, `Media` = media keys first.
- **Keyboard backlight** after installing the driver into a running session: `install/05-keyboard.sh`
  restarts UPower and gsd-power so F4 and the slider work immediately; after a reboot this is automatic.

## Uninstall

Every script lists its own removal steps in a `Remove:` comment at the top. The user part:
`user/install-user.sh --remove`. To go back to the stock kernel, pick it in GRUB, then remove the
linux-nvidia packages and the `acpi_osi` parameter from `/etc/default/grub` (`update-grub`).

## Repository layout

```
install/    numbered root steps (lib.sh: shared helpers)
optional/   face login, EasyEffects, NV Broadcast, desktop automation, CPU modes
drivers/    proart-battery, proart-audio, hid-asus-proart (DKMS), proart-ffa-probe (diagnostic)
config/     pipewire (2-way crossover), wireplumber (device names), ucm2, libinput, udev, environment.d
user/       user tools (proart-eq, proart-tweeter, ...), systemd user unit, install-user.sh
tools/      diagnostics and measurements
docs/       hardware map and technical notes
```

## Proprietary files

No firmware is included. `install/03-audio.sh` downloads ASUS' Windows audio driver for the ProArt
P14 (`Audio_Driver_ARM_Cirrus_Z_V1.0.678.52824`, which also carries the P16 tuning), checks its
SHA-256, unpacks it without running it and installs the Cirrus Logic CS35L56 firmware and ASUS
speaker tuning for SSID `1043:1484`. Those files are licensed by Cirrus Logic / ASUS.

## Credits

- NVIDIA: N1X kernel support, MT8901 SoundWire/ASoC/SOF audio stack
  ([NV-Kernels #566](https://github.com/NVIDIA/NV-Kernels/pull/566),
  [#567](https://github.com/NVIDIA/NV-Kernels/pull/567)) and the mt8901 UCM profiles
  ([alsa-ucm-conf #862](https://github.com/alsa-project/alsa-ucm-conf/pull/862))
- Omarchy ([omarchy-pkgs](https://github.com/omacom/omarchy-pkgs)): hid-asus patches for the
  `0B05:4B42` keyboard and the approach of taking the speaker tuning from ASUS' Windows driver
- [JackHack96/EasyEffects-Presets](https://github.com/JackHack96/EasyEffects-Presets),
  [Digitalone1/EasyEffects-Presets](https://github.com/Digitalone1/EasyEffects-Presets)
- [Howdy](https://github.com/boltgolt/howdy), [nvidia-vaapi-driver](https://github.com/elFarto/nvidia-vaapi-driver),
  [NV Broadcast](https://github.com/Hkshoonya/nvidia-broadcast-linux), LSP plugins (limiter)

## License

This project is licensed under the **GNU General Public License v2.0** (see [`LICENSE`](LICENSE)).

- Scripts, configuration and documentation: GPL-2.0-only
- `drivers/proart-battery`, `drivers/proart-audio`, `drivers/proart-ffa-probe`, `drivers/proart-haptic`,
  `drivers/snap-egl-shim`: GPL-2.0-only
- `drivers/hid-asus-proart`: GPL-2.0-or-later (derived from the Linux kernel's hid-asus)
- `config/ucm2`: BSD-3-Clause (NVIDIA, from alsa-ucm-conf PR #862)

Files downloaded at install time (ASUS/Cirrus speaker firmware, EasyEffects presets, Howdy, Firefox)
keep their own licenses and are not part of this repository.
