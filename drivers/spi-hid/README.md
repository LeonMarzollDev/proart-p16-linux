# spi-hid (out-of-tree HID over SPI, for the ambient light sensor)

The ProArt P16's ambient light sensor is the only sensor in a Microsoft "HID Sensor Collection V2"
hub that talks HID over SPI (`\_SB.SENH`, `_HID` `MSFW1111`, `_CID` `PNP0C51`, on `\_SB.SPI3`,
interrupt on GPIO `0xBE`, `_DSM` 6e2ac436-0fcf-41af-a265-b32a220dcfab revision 3: input header
0x1000, body 0x1004, output 0x2000, read opcode 0x0B). Linux has no HID-over-SPI transport yet, so
nothing binds it and GNOME has no light sensor.

`prepare.sh` fetches the posted series "Add spi-hid transport driver" v4 (9 June 2026; Jarrett
Schultz, Dmitry Antipov, Angela Czubak, Jingyuan Liang; linux-input, under review), checks every
patch against `patches.sha256`, and unpacks only `drivers/hid/spi-hid/`. The DKMS package builds
two modules: `spi-hid` (core) and `spi-hid-acpi` (matches `PNP0C51`). The `HID_SPI_DEVICE` macro the
series adds to `include/linux/hid.h` comes from `compat.h`.

The patches come from a pinned commit of [omarchy-pkgs](https://github.com/omacom/omarchy-pkgs)
(`pkgbuilds/linux-omarchy-aarch64/2110-2120`), which carries the series unchanged for the Surface
Pro 11. Omarchy builds `SPI_HID_OF` there but not `SPI_HID_ACPI`, so the N1x laptops do not get
the sensor from that kernel either (one config line would fix that).

Status:
- builds against `linux-headers-7.0.0-1018-nvidia` (arm64, gcc 15.2), modalias `acpi*:PNP0C51:*`
- **not run on the laptop yet**. Requires the SPI3 controller to bind over ACPI (spi-mt65xx ACPI
  support is NVIDIA SAUCE in linux-nvidia >= 1022) and the hub's report descriptor to be accepted
  by `hid-sensor-hub`.
- the series has moved on (v7 posted 2026-10-24 per research/upstream-plan.md); refresh `patches.sha256`
  to the newest version before testing on the laptop
- drop this package once the series is merged (`install/14-sensors.sh` skips the build when the
  running kernel has its own `spi_hid_acpi`).

Install: `sudo bash install/14-sensors.sh`. Remove: `dkms remove spi-hid/0.4.0 --all; rm -rf /usr/src/spi-hid-*`.
