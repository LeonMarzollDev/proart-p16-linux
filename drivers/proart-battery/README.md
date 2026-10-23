# proart_battery

Battery (`BAT1`), AC adapter (`ADP1`), ASUS fan/performance modes, battery charge limit and EC
sensors (fan, temperatures, system/SoC power) for the ASUS ProArt P16 H7607BA (NVIDIA N1X).

The BIOS talks to the ASUS EC service (FF-A partition 0x8003, UUID
`884a63a0-3285-4120-83aa-eec008a0a546`) through an FFH operation region. On Linux the EC answers
these requests correctly when they are sent directly, but the response never reaches the AML, so
ACPI `_BST`/`_PSR` report zeros (0 %, AC offline), `_FST` reports garbage and the ASUS WMI methods
do nothing. This driver sends the same commands itself (`FFA_MSG_SEND_DIRECT_REQ2`):

| EC command | x4 layout | result |
|---|---|---|
| `0x15` battery status | `0x15` | `status \| current<<16 \| remaining<<32 \| voltage<<48` (mA s16, mAh, mV) |
| `0x0c` read register | `0x0c \| (0xfe000900 + reg)<<8 \| len<<40` | `0x90` bit 0 = AC present, `0xc6`/`0xc7` = fan rpm, `0x98`/`0x99` = EC temperature/critical (C) |
| `0x0b` write register | as `0x0c`, value in x5 bits 8..39 | |
| `0x13` EC command | `0x13 \| flag<<8 \| n<<16 \| cmd<<24 \| data<<32` | `0xc4` reads an EC register (`0x2e`/`0x2f` = cycle count), `0xc5` writes one; `0xcc`/`0xcd` read/write EC RAM (`0x0700` = second temperature) |

The ASUS WMI functions go through a mailbox in the registers (data `0x40`, command `0x6e`,
control `0x6f`):

| mailbox command | data | WMI function |
|---|---|---|
| `0x11` write | `[mode, 0]`: 1 standard, 4 performance, 2 silent | `0x00120075` fan mode |
| `0x06` write | `[percent, 0]` | `0x00120057` charge limit |
| `0x05` read | byte 0 = limit (bit 7 set if never set) | charge limit status |

What the driver registers:

- `BAT1`/`ADP1` power supplies, polled every `poll_interval` seconds. Design capacity, full-charge
  capacity and design voltage come from the EC shared memory (`\_SB.B0DC`, `\_SB.B0FC`,
  `\_SB.B0DV`); energies are mAh x design mV, as the BIOS reports them.
- `BAT1/charge_control_end_threshold` (20-100). With `config/udev/61-proart-battery.rules`, UPower
  and GNOME offer "Preserve battery health" (80 %).
- A platform profile `quiet`/`balanced`/`performance` = ASUS silent/standard/performance. Through
  power-profiles-daemon this is GNOME's power mode. The mode and the charge limit are applied
  again after resume.
- hwmon `proart_ec`: `fan1_input` (rpm), `temp1` "EC" (with `temp1_crit`), `temp2` "EC sensor 2",
  `power1` "System" and `power2` "SoC". The power values come from the AML of the ACPI "thermal
  zones" `\_TZ.PSYS`/`\_TZ.PSOC`, which return mW (the platform's power monitor), not
  temperatures.

While loaded, the non-working ACPI `PNP0C0A:00` (BAT0), `ACPI0003:00` (AC0), `PNP0C0B:00` (fan) and
the misleading thermal zones `\_TZ.PSYS`, `\_TZ.PSOC` (power shown as 1000-6000 C), `\_TZ.THRM`
and `\_TZ.THZ0` (fixed fallback values from the broken EC path) are unbound (`hide_acpi=1`), so
desktops and sensor tools only show working devices; unloading re-attaches them.

Power off: arm64 Linux reboots through UEFI `ResetSystem()` but powers off with PSCI `SYSTEM_OFF`.
After a `SYSTEM_OFF` the EC cut the battery (RTC reset to 2000-01-01, power button dead until the
charger was plugged in); after reboots and forced power-offs it did not. The driver registers a
power-off handler that calls `ResetSystem(EfiResetShutdown)` first (`efi_poweroff=1`); if that
returns, PSCI powers off as before.

Sleep: the Modern Standby notifications Windows sends the EC (display off `0xb7`, standby entry
`0x9a`, sleep entry `0xae` and the reverse on wake) are implemented but off: the EC then cuts the
audio codecs' power (speakers crackle, cs42l43 microphone/jack stays dead until a reboot).
Without them s2idle works but draws ~11 W and the fans keep running.

Module parameters: `poll_interval` (s, default 2; the EC raises no ACPI event on (un)plugging, so this is how fast a charger change shows up), `hide_acpi` (default 1), `efi_poweroff` (default 1),
`standby_notify` (default 0, experimental).
The module only loads on DMI vendor `ASUS` / board `H7607BA`.

Install: `install/04-battery.sh` (DKMS). License: GPL-2.0.
