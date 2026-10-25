# proart_battery

Battery charge limit, ASUS fan/performance modes, EC sensors and UEFI power-off for the ASUS ProArt
P16 H7607BA (NVIDIA N1X) - plus its own battery (`BAT1`) and AC adapter (`ADP1`) on BIOS versions
whose ACPI battery does not work.

## Why the ACPI battery did not work (BIOS H7607BA.300)

The BIOS talks to the ASUS EC service (FF-A partition 0x8003, UUID
`884a63a0-3285-4120-83aa-eec008a0a546`) through an FFH operation region with Offset 2
(Arm DEN0048D "FF-A" flavour: X0 status, X1 receiver, X2-X3 service UUID, X4-X17 payload).
linux-nvidia handles that region in `nvidia-ffa-ec` (`ARML0002`), and the EC answers correctly.

In BIOS .300 the EC accessors (`\_SB.EC0.RRA9/RRA8/WRA9/WRA8/RWEC`, `\_SB.BAT0.GBST`) build the
packet in a local variable:

```
Local0 = Buffer (0x29) {}
CreateQWordField (Local0, Zero, BFX0) ... CreateDWordField (Local0, 0x20, STAD)
Local0 = \_SB.FFA0.FFAC = Local0
Return (STAD)
```

ACPICA returns the answer of a bidirectional (BufferAcc) field write in a *new* buffer object
(`acpi_ex_write_serial_bus()`), and storing it to `Local0` rebinds the local to that object. The
buffer fields still point at the old object - the request. So every method returns its own
request: `_BST` 0 % / 0 mV, AC always offline, cycle count `0xC5021413` (two echoed `13 01 01 C4`
requests), fan 164613644 rpm, and the FF-A notifications (EC events) decode to garbage, so no
AC-plug events either.

BIOS **H7607BA.303** uses `Name (RBUF, Buffer (0x29) {})` in all of these methods. A Store to a
named buffer copies into the existing object, so the fields see the answer and the stock ACPI
drivers (`battery`, `ac`, `acpi-fan`, `acpi-thermal`) should work. (Verified from the .303 tables;
not yet verified on running hardware.)

## Modes

`mode=auto` (default) reads EC register 0x90 through the AML (`\_SB.EC0.RRA9`) and directly, and
compares:

- **acpi** (the two agree; BIOS .303): BAT0/AC0/fan/THRM/THZ0 stay with their ACPI drivers. The
  driver adds `charge_control_end_threshold` to `BAT0` (power-supply extension through the ACPI
  battery hook) and unbinds only `\_TZ.PSYS`/`\_TZ.PSOC`, which report power in mW as
  temperatures on every BIOS.
- **ec** (the AML returns its request, e.g. `0x9900c`; BIOS .300): the driver polls the EC itself
  and registers `BAT1`/`ADP1`; the ACPI `PNP0C0A:00` (BAT0), `ACPI0003:00` (AC0), `PNP0C0B:00`
  (fan) and the thermal zones PSYS/PSOC/THRM/THZ0 are unbound while it is loaded (`hide_acpi=1`).

`mode=acpi` / `mode=ec` force one. `sudo bash check-acpi.sh [--raw]` shows the BIOS version, the
decision and what the ACPI devices report.

## EC commands

| EC command | x4 layout | result |
|---|---|---|
| `0x15` battery status | `0x15` | `status \| current<<16 \| remaining<<32 \| voltage<<48` (mA s16, mAh, mV) |
| `0x0c` read register | `0x0c \| (0xfe000900 + reg)<<8 \| len<<40` | `0x90` bit 0 = AC present, `0xc6`/`0xc7` = fan rpm, `0x98`/`0x99` = EC temperature/critical (C) |
| `0x0b` write register | as `0x0c`, value in x5 bits 8..39 | |
| `0x13` EC command | `0x13 \| flag<<8 \| n<<16 \| cmd<<24 \| data<<32` | `0xc4` reads an EC register (`0x2e`/`0x2f` = cycle count), `0xc5` writes one; `0xcc`/`0xcd` read/write EC RAM (`0x0700` = second temperature) |

The ASUS WMI functions go through a mailbox in the registers (data `0x40`, command `0x6e`,
control `0x6f`), which the AML serializes with the mutex `\_SB.EC0.CMUT`. The driver takes the
same mutex (`acpi_acquire_mutex()`) around its EC sequences, so it cannot interleave with `_BST`
(which reads the mailbox) or EC event handling:

| mailbox command | data | WMI function |
|---|---|---|
| `0x11` write | `[mode, 0]`: 1 standard, 4 performance, 2 silent | `0x00120075` fan mode |
| `0x06` write | `[percent, 0]` | `0x00120057` charge limit |
| `0x05` read | byte 0 = limit (bit 7 set if never set) | charge limit status |

## What the driver registers

- ec mode: `BAT1`/`ADP1`, polled every `poll_interval` seconds (default 2) on the freezable
  workqueue, re-read right after resume. Design capacity, full-charge capacity and design voltage
  come from the EC shared memory (`\_SB.B0DC`, `\_SB.B0FC`, `\_SB.B0DV`); energies are mAh x design
  mV, as the BIOS reports them.
- `charge_control_end_threshold` (20-100) on BAT1 (ec) or BAT0 (acpi). With
  `config/udev/61-proart-battery.rules`, UPower and GNOME offer "Preserve battery health" (80 %).
- A platform profile `quiet`/`balanced`/`performance` = ASUS silent/standard/performance. Through
  power-profiles-daemon this is GNOME's power mode. The mode and the charge limit are applied
  again after resume.
- hwmon `proart_ec`: `fan1_input` (rpm), `temp1` "EC" (with `temp1_crit`), `temp2` "EC sensor 2",
  `power1` "System" and `power2` "SoC" (from `\_TZ.PSYS`/`\_TZ.PSOC`, which return mW).
- Power off through UEFI `ResetSystem(EfiResetShutdown)` (`efi_poweroff=1`): after a PSCI
  `SYSTEM_OFF` the EC cut the battery (RTC reset to 2000-01-01, power button dead until the charger
  was plugged in). If ResetSystem returns, PSCI powers off as before.

The Modern Standby notifications (`standby_notify` up to 1.8) moved to `drivers/proart-s2idle`,
which calls the firmware's `_DSM` instead of sending raw EC commands.

Module parameters: `mode` (auto/acpi/ec), `poll_interval` (s, ec mode), `hide_acpi` (default 1),
`efi_poweroff` (default 1). The module only loads on DMI vendor `ASUS` / board `H7607BA`.

Install: `install/04-battery.sh` (DKMS). License: GPL-2.0.
