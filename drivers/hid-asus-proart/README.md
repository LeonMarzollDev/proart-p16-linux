# hid-asus-proart

`hid-asus` from NVIDIA's `NV-Kernels` tree (branch `26.04_linux-nvidia`, which already contains the
upstream Zenbook A16 / `0B05:4B42` support) with three patches from the Omarchy project and two of our own
(`patches/`, originally written for the ASUS ProArt P14 H7407BA, same keyboard):

- `0002` register the `0B05:4B42` keyboard backlight without asus-wmi (x86-only) and zero-pad short
  feature reports. Registering the backlight also sends the OOBE-disable sequence that hid-asus
  already has for DMI product family "ProArt P16": the keyboard stops fading its backlight in and out.
- `0003` host-controlled Fn-lock (`Fn+Esc`), module parameter `fnlock_default`.
- `0004` send the OOBE-disable sequence on the ProArt P14 as well (no effect on the P16).
- `0005` (this repository) cycle the standalone keyboard backlight on the hotkey: without asus-wmi
  the backlight keys reached userspace, where `KEY_KBDILLUMTOGGLE` only switched the light on/off.
  The driver now steps the level itself (off -> 1 -> 2 -> 3 -> off; up/down keys step and clamp), keeps
  the keys from userspace and reports `led_classdev_notify_brightness_hw_changed()` with
  `LED_BRIGHT_HW_CHANGED`, so UPower and GNOME show the level OSD.
- `0006` (this repository) expose the Fn-lock state as `fn_lock` on the HID device
  (`/sys/bus/hid/devices/*0B05:4B42*/fn_lock`, 1 = F1-F12 first, 0 = media keys first), announce
  Fn+Esc changes with `sysfs_notify()` and allow root to set it. Used by `user/bin/proart-fnlock`.

`hid-asus.c` and `hid-ids.h` are the patched files; the patches are kept for reference.
Install: `install/05-keyboard.sh` (DKMS, `fnlock_default=0` = media keys first).
License: GPL-2.0-or-later (as upstream hid-asus).
