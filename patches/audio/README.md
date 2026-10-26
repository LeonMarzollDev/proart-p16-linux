# Audio after long s2idle sleeps: kernel patches and tools

Background, evidence and the test procedure: `research/audio-suspend.md` (in the parent
`laptop-linux-support` folder) and `docs/technical-notes.md` section 4.9.

| file | what it does |
|---|---|
| `kernel/0001-…interrupt-gate…` | Ryan Hughes' fix (omarchy-pkgs 1034, archlinuxarm-proart-p16): close the SoundWire IRQ gate before quiescing a link (interrupt storm / hang in `mtk_sdw_enable_irq(false)`, which runs on every suspend and attach check) |
| `kernel/0002-…pin-bias…` | re-apply the `_CRS` pin bias of the SoundWire pads on system resume (only done at probe so far) |
| `kernel/0003-…restart-the-links…` | on resume, restart each link with the probe sequence (soft reset + quiesce + re-init) and arm the attach check; `restart_on_resume=0` = old behaviour |
| `kernel/0004-…clock-parents…` | **main fix**: select the APLL2 parents of the SoundWire bus/PHY clock muxes whenever a link clock is enabled (levels from the Windows controller driver); `sdw_set_clk_parents=0` = old behaviour, `sdw_lp_clk_parents=1` = also park on osc_d20 when released (Windows behaviour) |
| `kernel/0005-…cs35l56…` | backport of linux-next 6cc7db9fdd (CS35L56 firmware < 3.13.7 must not see a bus reset within 250 ms of a firmware timer start). Only for a full kernel rebuild (snd-soc-cs35l56*), not part of the DKMS |
| `install-sdw-dkms.sh` | builds `soundwire-mtk` (NV-Kernels 4646b8565e0e source, sha256-pinned download + 0001-0004) as DKMS `proart-sdw-mtk/1.0` for linux-nvidia 7.0.0-1021…1024 |
| `proart-audio-diag.sh` | before/after snapshot (attach state, pins, regmaps, DSP state, real PCM rates, mic RMS), compare, and a recovery ladder (`recover --try-clk`) |

The patches apply with `git am` to NV-Kernels `26.04_linux-nvidia` (4646b8565e0e) and to
linux-nvidia 7.0.0-1024 (identical `drivers/soundwire/mediatek`). Compile-tested (arm64, WSL)
against an O= build of that tree; not yet run on the laptop.

Fallback without a kernel module: `optional/sleep-audio.sh` (keeps the audio power domain on during
sleep, and after waking selects the SoundWire clock parents through power_wrap and restarts link 1).
