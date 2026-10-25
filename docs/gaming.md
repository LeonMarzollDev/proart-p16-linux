# Gaming on the ProArt P16 (NVIDIA N1X, arm64)

What works for running x86 Windows and Linux games on this arm64 laptop, how it is set up and what was
measured. Worked out on Ubuntu 26.04 with NVIDIA driver 615.71.09, FEX-Emu 2610 and Hangover 11.16
(2026-10-25).

## The pieces

| Piece | What it does | Here |
|---|---|---|
| **FEX-Emu** | runs x86-64 and 32-bit x86 Linux programs on arm64; AVX, AVX2, FMA3, F16C, BMI2 since FEX 2407 | `ppa:fex-emu/fex`, package `fex-emu-armv8.4` |
| **FEX RootFS** | x86 Ubuntu 24.04 user space (libc, Mesa, X11 ...) the emulated programs see | `~/.local/share/fex-emu/RootFS`, 1.9 GB |
| **FEX thunks** | forward Vulkan/GL/DRM/Wayland calls of x86 programs to the native arm64 libraries, i.e. the arm64 NVIDIA driver | `config/fex-emu/thunks.json` |
| **Wine** (x86 build) | Windows programs, runs inside FEX | per game, e.g. Kron4ek builds |
| **DXVK** | Direct3D 9-11 -> Vulkan | installed into the Wine prefix by winetricks |
| **Hangover** (optional) | arm64 Wine that emulates only the Windows code (FEX arm64ec / Box64 wow64 DLLs) | `--hangover` |
| **Steam** (snap) | brings its own FEX, RootFS and the x86 NVIDIA user-space driver; nothing to set up | `snap install steam` |

Install: `sudo bash optional/gaming/emulators.sh [--hangover]`.

### What the N1X means for emulation

- **AVX works, at half width.** The CPU has SVE2 with a 128-bit vector length
  (`/proc/sys/abi/sve_default_vector_length` = 16), so FEX splits every 256-bit AVX instruction into two.
  Checked by running real AVX2 code under FEX (`vpbroadcastd`/`vpaddd ymm`: 21+21 = 42).
- **20 cores of two kinds:** 10 Cortex-X925 (cpu 5-9, 15-19) and 10 Cortex-A725. The scheduler puts the
  heavy threads on the X925 cores by itself; pinning to them brought nothing that was worth losing the
  other ten.
- **Memory model:** the CPU has LRCPC2, so FEX emulates x86's stronger memory ordering cheaply for normal
  loads/stores; vector and memcpy accesses need half barriers. `config/fex-emu/Config.json.in` turns
  ordering off for vector and memcpy accesses (`VectorTSOEnabled=0`, `MemcpySetTSOEnabled=0`), the same
  choice Valve ships in the Steam snap's FEX config.
- **Unified memory:** CPU and GPU share the 114 GB. A loaded local LLM (Flash-Next takes ~90 GB) and a
  game compete for it - stop the model first.
- **GPU path:** without thunks an x86 program only finds Mesa's llvmpipe (software). With
  `thunks.json` and the thunk paths in `Config.json`, an x86 Vulkan program lists
  `NVIDIA RTX Spark N1X (6144-core Blackwell RTX GPU)`. FEXRootFSFetcher writes no `Config.json`, so
  without ours FEX does not even find the RootFS.

## Steam

The Steam snap (Canonical) runs its x86 client and all games through its own FEX
(`/snap/steam/current/usr/bin/fex_launcher.sh`). At start it downloads the x86-64 NVIDIA `.run` matching
`/sys/module/nvidia/version` and installs its user-space libraries, the Vulkan ICD and the DLSS DLLs
(`nvngx.dll`) into its RootFS (`~/snap/steam/common/x86_rootfs`). Windows games run through Proton on top.
Checked with x86 `vulkaninfo` inside the snap: `driverName = NVIDIA, driverInfo = 615.71.09`.
Pressing *Install* on a Windows-only game just works this way; per-game Proton is under
*Properties -> Compatibility*.

**Games on a second SSD:** Steam's *Add drive* dialog did not offer the SSD mounted at `~/SSD`.
`optional/gaming/steam-library.sh <dir>` (Steam closed) moves the default library's `steamapps` there and
leaves a symlink; the snap can write under `$HOME`. Steam's storage page still shows the drive of its
program folder.

## Star Citizen

`bash optional/gaming/star-citizen.sh [install dir]` - the steps of the Star Citizen Linux Users Group
helper (lug-helper 4.17, `install_game`), with the x86 parts under FEX. Requirements the helper checks
(`vm.max_map_count >= 1048576`, open files >= 524288) are Ubuntu 26.04 defaults. Start: app menu ->
*Star Citizen*. The launcher downloads the game (~100 GB) after logging in with the RSI account.

What had to change on the N1X:

1. **Wine runner with a classic 32-bit part.** The LUG runner (lug-wine 11.18) is a pure WoW64 build: 32-bit
   code runs inside 64-bit processes. Under FEX that crashed (Wine Mono's `installinf-x86.exe` SIGSEGV,
   `syswow64` stayed empty, winetricks' font registration failed with "failed to open
   syswow64\regedit.exe"). Kron4ek's `wine-11.20-staging-tkg-amd64` has `i386-unix`, so 32-bit programs
   are separate 32-bit processes, which FEX handles. Launcher and game are 64-bit only.
2. **`cabextract`** for winetricks' fonts (installed by `emulators.sh`).
3. **192 dpi in Wine.** All four screens are HiDPI (eDP 3840x2400 on 34 cm, externals up to 6880x2880);
   at Wine's default 96 dpi every Wine window was tiny and the launcher sat at a fixed 900x620 px. With
   `LogPixels = 192` it is 1800x1240. Its size cannot be changed by the user - RSI sets minimum = maximum.
4. **Starter:** the LUG launch script runs in an x86 shell (`FEXBash sc-launch.sh`); no binfmt needed. Also in
   Lutris (if installed) as a "Linux" game that runs the starter - Lutris' own Wine handling knows nothing
   about FEX, and this way the launcher, the app menu and Lutris share one set of settings.

Tried and dropped: Wine's native Wayland driver (`HKCU\Software\Wine\Drivers\Graphics=wayland`) - the
launcher aborted with `FATAL:ui\gfx\win\hwnd_util.cc:65] 1400`.

### Launcher responsiveness: what made it lag, and the fixes

The RSI Launcher is an Electron (Chromium) app. Hovers and clicks reacted after up to a second, its videos
stuttered. Several real bottlenecks were stacked; each fix below was measured.

| Bottleneck | How it showed | Fix |
|---|---|---|
| **Presents waited for vsync** | `DXVK_HUD=fps,gpuload` in the launcher window: **0.9 frames/s, GPU 0 %** - the GPU idled while every present waited for a vsync signal that came late on the path DXVK -> Vulkan (FEX thunk) -> XWayland -> NVIDIA | `dxgi.syncInterval = 0` in the prefix's `dxvk.conf`: **60 frames/s, GPU 14 %** |
| **wineserver round trips** | `strace -c` on the renderer: 17,230 `read` calls with 59 s of waiting in 8 s, the browser process 1.6 s - every Wine wait/event went through the single-threaded, here emulated wineserver | load the kernel's **ntsync** module (`/etc/modules-load.d/ntsync.conf`); the Kron4ek build supports it. Afterwards 2,948 open `/dev/ntsync` handles, wineserver 22 % -> 0 %, waits 0.43 s / 4.8 s |
| **Efficiency cores** | the user saw only the Cortex-A725 cores busy: energy-aware scheduling parks bursty threads there at a few hundred MHz (same cause as GNOME Shell's stutter) | `uclampset -m 768` around the starter (inherited by all Wine processes and the game) |
| **FEX memory ordering** | JavaScript workload 124 ms with full x86 ordering | `VectorTSOEnabled=0`, `MemcpySetTSOEnabled=0` (Valve's choice): 90 ms |
| **FEX re-translating everything** | each start and each new code path translated again | FEX disk code cache (`DiskCache=1`, ~0.8 GB in `~/.cache/fex-emu`): window after 14 s instead of 39-45 s |
| IBus XIM | known Wine typing lag | `XMODIFIERS=@im=none` for the launcher |

Not a fix, and dropped: the launcher's videos (AV1 3440x1440 and VP9 2560x1072 at 60 frames/s, plus two
animations embedded in its JavaScript) are decoded on the CPU - Wine/DXVK have no D3D11 video decoding on any
platform - but with 17 of 20 cores free that was never what blocked input. Replacing them with stills,
Chromium switches (`--jitless` breaks the launcher, `--js-flags=--max-opt=1`, reduced motion, autoplay
policy), hiding AVX from FEX and full TSO off brought nothing measurable. Wine's Wayland driver crashes the
launcher; under Hangover the launcher hangs at start (all threads waiting in `ntsync_schedule`, also without
ntsync; Hangover's x64/ARM64EC path is the youngest part).

Lesson for measuring: Chromium-internal numbers (DevTools: 18-40 ms from event to frame) looked fine the whole
time. Only measuring what reaches the screen (DXVK's HUD) showed the real problem.
