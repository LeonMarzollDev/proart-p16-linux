# ASUS ProArt P16 H7607BA - devices outside the main setup

Status of the parts that [hardware.md](hardware.md) and the numbered install steps 01-11 do not
cover, worked out from Windows 11 (BIOS H7607BA.303, 2026-09-22) and the ACPI tables. **Nothing in
this file has been tested under Linux on the laptop yet** unless it says "verified"; the kernel
facts refer to `linux-nvidia` 7.0.0-1018 (resolute, arm64) whose config was read directly.

| Part | Windows binding | Linux status (linux-nvidia 7.0) | What this repo does |
|---|---|---|---|
| Ambient light sensor | `\_SB.SENH` `MSFW1111`/`PNP0C51`, HID over SPI3, "HID Sensor Collection V2" (Windows LightSensor) | no HID-over-SPI transport in mainline or linux-nvidia; series under review | `install/14-sensors.sh` + `drivers/spi-hid` (DKMS of the posted series; builds, not run) |
| Presence sensor | webcam `636E:0BDB` MI_04, HID sensor collection (HumanPresence + Proximity) | `hid-sensor-hub` + `hid-sensor-prox` (technical-notes: works) | check only |
| Accelerometer / gyro / hinge / orientation | none (Windows enumerates none; clamshell) | - | nothing needed; no auto-rotate |
| DialPad | **not present** on H7607BA (ASUS spec lists only a haptic touchpad; no DialPad driver installed in Windows, unlike the H7606) | - | nothing; `asus-dialpad-driver` targets the H7606 |
| NPU | `\_SB.DLA0` `NVDA200A` (`_CID NVDA2042`, rev 0x34): NVDLA, MCDM compute-only adapter of `nvlddmkm` | no driver: the NVDLA HID is NVIDIA's (also used on Jetson T234 ACPI), but no Linux ACPI driver exists and the open GPU driver does not expose it | none possible; use the GPU (CUDA) |
| USB4 / Thunderbolt | `\_SB.UBF0..3` `NVDA8100` (`_CID ACPI0015`), Microsoft inbox USB4 host router driver (software connection manager) | **not bound**: the routers are ACPI platform devices, Linux' thunderbolt driver only knows PCI NHIs. USB-C still works as USB 3 + DisplayPort alt mode (UCSI); PCIe/DP tunnels (docks' Ethernet, eGPUs, Thunderbolt-only displays such as the Apple Studio Display) do not | none (see below: Omarchy kernel patches 1070-1089) |
| HDMI 2.1 FRL | GPU output | `nvidia-drm`; audio via `NVDA2014` (`snd_hda_acpi`) | check only |
| SD Express 7.0 reader | Genesys GL9767 `17A0:9767` SUBSYS `1043:202F` | `sdhci-pci-gli` (mainline since 6.5, incl. the SD Express switch to NVMe) | check only; runtime PM off (technical-notes) |
| Stylus | ILITEK `ILTK0001` (`222A:5554`) pen collection + "Seamless Pairing" (vendor page FFF4) | `hid-multitouch`; pressure/tilt as declared by the descriptor (unverified); pen battery shows as 0 % | upstream note below |
| Panel colour | ASUS factory profiles per panel ID (`H7607BA_10DE_834C4235*.icm`, "Calibrate by ACMP V2.3.0") + sRGB/P3/DCI-P3 gamut profiles | colord / GNOME Color | `install/12-display.sh`, `user/bin/proart-icc` |
| HDR / VRR | Windows Advanced Color, `_HDR.icm` | EDID: BT.2020, ST 2084 metadata, 1600 cd/m2 peak; adaptive sync 30-120 Hz. VRR verified (technical-notes 5b); HDR needs GNOME 48+ and nvidia-drm HDR properties (unverified) | check in `tools/check.sh` |
| Brightness | WMI brightness 0-100 | eDP AUX/DPCD through nvidia-drm (Omarchy reports brightness working on the P14 with nvidia-open 615) | check only |
| OLED PWM / "flicker-free dimming" | ASUS OLED Care (MyASUS) | panel-internal, no Linux interface known | none |
| TPM 2.0 | `NTC0702`/`MSFT0101`, TPM2 table start method 15 (CRB over FF-A, partition 0x8001) | `CONFIG_TCG_CRB=y`, `CONFIG_TCG_ARM_CRB_FFA=y` | check `/dev/tpmrm0` |
| Pluton | `NVDA8601` | no Linux driver (not needed) | - |
| Secure Boot | on (BitLocker on C:) | shim + Canonical kernel; lockdown blocks unsigned DKMS modules | `install/17-secure-boot.sh` (MOK) |
| Firmware updates | ESRT: ASUS UEFI BIOS `97686c57-e102-5ecf-ae23-27647f24f0ca` + 4 device firmware | `CONFIG_EFI_ESRT=y`, `CONFIG_EFI_CAPSULE_LOADER=y`, fwupd uefi-capsule; no ASUS BIOS on LVFS seen | `install/18-firmware.sh` (dbx/KEK, peripherals; BIOS via EZ Flash) |
| Hibernate | Windows hibernate available | `CONFIG_HIBERNATION` is **not set** in linux-nvidia arm64 | none; s2idle only |
| ASUS WMI (`ATKD`, `AMW1`) | ASUS System Control Interface v3 (`ASUS2018`), `ASUH2024` virtual HID for hotkeys | `CONFIG_ACPI_WMI` not built on arm64: WMI events never reach Linux | keys that work go through hid-asus; any hotkey that only arrives as WMI event is lost (check with `tools/key-events.py`) |
| Generic buttons | `ACPI0011` (GPIO 0x8D, usage System Power Down) | `soc_button_array` is x86-only; the ACPI power button `PNP0C0C` (`CONFIG_ACPI_BUTTON=y`) | verify the power button |
| Memory | firmware reserves ~half of the 128 GB for the GPU (Windows shows 64 GB) | Omarchy shrinks the reservation through the EFI variable `EXPOSED_DISP_FRM-4b086294-0740-4f71-a7b5-85a329c7ec5f` (62.5 -> 4 GiB) and earlier used an `efi_reclaim_reserved=` kernel patch; Ubuntu does neither - check `MemTotal` | check in `tools/check.sh`; see research/omarchy-p16.md |

## USB4 / Thunderbolt

The firmware hands USB4 to the OS and has no connection manager; Windows uses its own software
connection manager. Omarchy's aarch64 kernel (omarchy-pkgs `pkgbuilds/linux-omarchy-aarch64`,
patches 1070-1089, validated on the ProArt P14 with a CalDigit TS4 on all three ports, 40 Gb/s,
DP tunnel 4K 240 Hz) adds `thunderbolt_platform` (`CONFIG_USB4_PLATFORM_NHI`) for the `NVDA8100`
host interfaces, and needs `power_wrap_drv.usb4_release=0 pci=hpbussize=0x80,hpmmiosize=32M,hpmmioprefsize=32G`
on the command line plus `boltctl enroll --policy auto` per dock. The patches touch the
thunderbolt core, NVIDIA's power_wrap and the PCI core, so they cannot be shipped as a DKMS module;
on Ubuntu they have to go into `linux-nvidia` (NV-Kernels) - see research/upstream-plan.md. The
P16 has three USB4 ports in the spec but four `UBFx` nodes in ACPI (one probably unused).

## Ambient light sensor

`install/14-sensors.sh` builds the posted spi-hid series (core + ACPI glue). The `_DSM` of `SENH`
(revision 3) returns input header address 0x1000, body 0x1004, output 0x2000, read opcode 0x0B -
the values the series' ACPI glue reads. Order of things that must work: `spi-mt65xx` binds
`\_SB.SPI3` (linux-nvidia >= 1022) -> `spi-MSFW1111:00` appears -> `spi_hid_acpi` binds it ->
`hid-sensor-hub` parses the collection -> `hid-sensor-als` creates an iio device -> iio-sensor-proxy.
Omarchy's kernel already carries the series but builds only `SPI_HID_OF`; `CONFIG_SPI_HID_ACPI=m`
would give N1x laptops the sensor there.

## Colour

The profiles are display matrix/TRC profiles (ICC v2.2) made by ASUS' ACMP tool for the panel
model, not per unit (all files carry the same date and are in the driver package for every panel
ID, `834C<product>` = EDID manufacturer `SDC` + product code). `H7607BA_10DE_834C4235.icm` describes
the native gamut; `_CMDEF` is the one Windows assigns by default; `_HDR` is the Windows HDR
calibration. On Linux, colour-managed apps (GIMP, darktable, Krita, Firefox with
`gfx.color_management.mode=1`) use the colord profile; GNOME applies only the VCGT, which these
profiles do not carry, so the desktop itself stays unmanaged unless the compositor does colour
management (GNOME 48+ with HDR: BT.2100 mode).

## Stylus battery

The touchscreen's pen collection declares a battery strength usage, so `hid-input` creates a
`hid-<id>-battery` power supply that reads 0 % until the pen reports. Upstream fix: add the
ILITEK `222A:5554` (I2C) to `hid_battery_quirks[]` in `drivers/hid/hid-input.c` with
`HID_BATTERY_QUIRK_AVOID_QUERY` (or `_IGNORE`), after checking what the pen reports in use.
