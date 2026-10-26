# proart_s2idle (experimental)

Calls the Microsoft Modern Standby `_DSM` (`11e00d56-ce64-47ce-837b-1f898f9aa461`) of the
`PNP0D80` device around suspend-to-idle, as Linux does on x86 (`drivers/acpi/x86/s2idle.c`) and
Windows does on every Modern Standby machine. On ACPI arm64 Linux installs no
`platform_s2idle_ops`, so this `_DSM` is never evaluated and firmware never learns that the system
sleeps.

On the ProArt P16 the `_DSM` is in `\_SB.PEPD` (`NVDA6210`, `_CID PNP0D80`, DSDT). Function 0
returns `0x3f9` (functions 3-9):

| function | when (x86 order) | AML |
|---|---|---|
| 3 display off | entry, 1st | `RWEC(2, 0xB7)`, `Notify(PEPD, 0xC3)` |
| 7 Modern Standby entry | entry, 2nd | `Notify(PEPD, 0xC7)`, `RWEC(2, 0x9A)` |
| 5 LPS0 entry | entry, 3rd | `RWEC(2, 0xAE)`, `Notify(PEPD, 0xC5)` |
| 6 LPS0 exit | exit, 1st | `FFA0.ERST()`, `WSCI = 0`, `Notify(PEPD, 0xC6)`, `RWEC(2, 0xAF)` |
| 9 turn on display | exit, 2nd | `Notify(PEPD, 0xC9)` |
| 8 Modern Standby exit | exit, 3rd | `FFA0.ERST()`, `GIO0.WEIT = 0`, `WSCI = 0`, `Notify(PEPD, 0xC8)`, `RWEC(2, 0x9B)` |
| 4 display on | exit, 4th | `RWEC(2, 0xB8)`, `Notify(PEPD, 0xC4)` |

`RWEC(2, cmd)` is a data-less command to the ASUS EC over FF-A (it is a write, so it reaches the
EC on every BIOS, even where reading answers back is broken). Without these calls the EC stays
in its "awake" policy: the fans keep running in s2idle.

A module cannot install `platform_s2idle_ops` (`s2idle_set_ops()` is not exported), so the entry
functions run in the driver's `suspend_noirq` callback (all devices have finished `suspend` and
`suspend_late` by then) and the exit functions in `resume_noirq` (before any `resume_early` /
`resume`). Only for suspend-to-idle (`pm_suspend_target_state == PM_SUSPEND_TO_IDLE`); if a later
device aborts the suspend, the exit functions still run.

## Parameters

- `funcs` (bit mask, default `0x3f8`): which functions to call (only those the firmware reports).
- `enable` (default 1), `debug` (log each call with its duration), `force` (other machines).

All three runtime ones are writable in `/sys/module/proart_s2idle/parameters/`.

## Known risk, and how to narrow it down

Earlier proart_battery versions sent the three EC commands of the entry sequence directly
(`standby_notify=1`); the EC then cut power to the audio codecs (speakers crackle, cs42l43 mic and
jack dead until reboot). This driver calls the full `_DSM` instead (also the `Notify` and the FF-A
wake-state reset of the exit functions), which is what Windows does, but whether that avoids the
audio problem is **untested**. Bisect with `test-s2idle.sh`:

```
sudo bash test-s2idle.sh 300 0x3f8   # everything
sudo bash test-s2idle.sh 300 0x018   # display off/on only
sudo bash test-s2idle.sh 300 0x180   # Modern Standby entry/exit only
sudo bash test-s2idle.sh 300 0x060   # LPS0 entry/exit only
sudo bash test-s2idle.sh 300 0       # nothing (baseline)
```

Each run reports the average battery power while asleep; listen for the fan during the sleep and
check speakers/microphone/headphones afterwards. The power figure also depends on whether the SoC
reaches its deepest platform state (DRIPS), which is a separate, kernel-side question (see
`research/battery-ec-fans.md`).

Install: `install/15-s2idle.sh` (DKMS). License: GPL-2.0.
