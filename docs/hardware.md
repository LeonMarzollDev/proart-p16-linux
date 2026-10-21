# ASUS ProArt P16 H7607BA - hardware map

Tested unit: BIOS `H7607BA.300` (2026-08-11), DMI product family `ProArt P16`, board `H7607BA`.

## Platform

| Part | Details | Linux driver |
|---|---|---|
| SoC | NVIDIA N1X (GB10): 10x Cortex-X925 + 10x Cortex-A725, ACPI boot (EDK2/Insyde) | linux-nvidia kernel |
| GPU | NVIDIA "RTX Spark N1X" (Blackwell), PCI `10de:2e03`, drives the internal panel | `nvidia` 615 open (`nvidia-drm`) |
| Panel | Samsung `ATNA60HC05` OLED, 3840x2400, 60/120 Hz, eDP | `nvidia-drm` (before: `simple-framebuffer` only) |
| Storage | M.2 slot 1 on `\_SB.PCI2`; **M.2 slot 2** on `\_SB.PCI4` (2280, PCIe x4; ASUS: single-sided SSDs only). `PCI4._STA` returns 0 while `P4EN` = 0 (empty slot) | `nvme` |
| Wi-Fi / BT | MediaTek MT7925 (PCIe `14c3:7925`), BT over USB `13d3:3602` | `mt7925e`, `btusb`/`btmtk` |
| Webcam | USB `636e:0bdb` "ASUS FHD webcam": FHD camera, IR camera (strobing emitter), HID sensor hub (presence) | `uvcvideo`, `hid-sensor-hub` |
| SD reader | Genesys GL9767 | `sdhci-pci` |

## Low-speed buses (MT8901 IP blocks)

| ACPI | Function | Driver (linux-nvidia >= 1023) |
|---|---|---|
| `NVDA0200` (I2C0-6) | I2C controllers | `i2c-mt65xx` |
| `NVDA9221` (GIO0) | GPIO / interrupts | `pinctrl_mt8901` (built-in) |
| `NVDA0210` | SPI | `spi-mt65xx` |
| `NVDA0240` (COM1-3) | UARTs (hidden from "Windows 2022") | `8250_mtk` |
| `NVDA6210` (PEPD) | device power control (SCMI) | `power_wrap_drv` |
| `NVDA8400` (SSPM) | SCMI transport; `_STA` = 0 when `_OSI("Windows 2022")` | `sspm_ci` |

## Input

| ACPI / bus | Device | Notes |
|---|---|---|
| `MKB0001` on I2C2 | keyboard `0B05:4B42` | `hid-asus`; backlight + Fn-lock need `drivers/hid-asus-proart` |
| `3030443150435341` on I2C4 | touchpad PixArt `093A:4F01` (haptic, buttonless) | `hid-multitouch`; pressure ~80-120 on 0-65535 -> libinput quirk |
| `ASTH0001` on I2C1 | ASUS haptic controller `0B05:4543` (vendor reports 0x07, 0x5A) | `hid-generic`, no Linux user |
| `313030304B544C49` on I2C2 | touchscreen ILITEK `222A:5554` with stylus | `hid-multitouch` (stylus battery shows up as a 0 % battery) |

## Audio

| ACPI / address | Part | Role |
|---|---|---|
| `NVDA9100` (CNT0) | MT8901 SoundWire controller, links 0/1 | `soundwire-mtk` |
| `NVDA9022` (ASD0) | MT8901 audio front end (DL0-5, DL_24CH, UL0-5 memifs) | `snd-soc-mt8901-afe` |
| `NVDA8301`-`NVDA8303` | audio DSP cores | `snd-sof-mt8901` |
| `sdw:0:1:01fa:3556:01:0` | Cirrus CS35L56, unique ID 0 | **left woofer** amp (tuning `lw_l1u0`) |
| `sdw:0:1:01fa:3556:01:1` | Cirrus CS35L56, unique ID 1 | **right woofer** amp (tuning `rw_l1u1`) |
| `sdw:0:1:01fa:4243:01` | Cirrus CS42L43 | headphone jack, headset mic, 2 DMICs, **tweeter amp** |
| `NVDA2014` | NVIDIA HDA | HDMI/DisplayPort audio |

Card subsystem ID (ACPI `_SUB` of CNT0): `14841043` -> SSID `1043:1484`.

MT8901 routing used by the UCM profile (`HiFi-cs42l43-cs35l56x2.conf`):

- `DL0` (hw:,0) -> `O152/O153` -> `PDI3` -> `DP3` -> CS35L56 woofers
- `DL1` (hw:,1) -> `O156/O157` -> `PDI5` -> `DP5` -> CS42L43 `DP5RX1/2` -> headphone amp, and
  (this project) the CS42L43 speaker amp (`cs42l43 Speaker L/R Input 1 = DP5RX1/2`) -> tweeters
- `UL1` (hw:,8) <- `O020/O021` <- `PDI13` <- `DP7` <- CS42L43 `DP1TX1/2` <- decimators 3/4 (DMICs)

## Power / EC

| ACPI | Function | Notes |
|---|---|---|
| `ARML0002` (FFA0) | Arm FF-A, FFH operation region (offset 2) | bound by `nvidia-ffa`; `_DEP` of BAT0 |
| `ACPI0004` (EC0) | ASUS EC methods (`RRA9`, `RWEC`, `GBST`) over FF-A | UUID `884a63a0-3285-4120-83aa-eec008a0a546`, partition `0x8003` |
| `PNP0C0A` (BAT0) | battery | static data from shared memory `\_SB.B0DC/B0FC/B0DV`; live data broken -> `proart_battery` |
| `ACPI0003` (AC0) | AC adapter | `_PSR` broken -> `proart_battery` (`ADP1`) |
| `USBC000` | UCSI (3 USB-C ports) | `ucsi_acpi` |

FF-A partitions seen: `0x8001` (TPM CRB), `0x8002`, `0x8003` (EC services: management `330c1273`,
power `7157addf`, battery `25cb5207`, thermal `31f56da7`, fan `7697530c`, UCSI `65467f50`,
input `e3168a99`, time/alarm `23ea63ed`, ASUS OEM `884a63a0`, ...), `0x8004` (physical presence).
