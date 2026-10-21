# snap-egl-shim

glvnd EGL vendor shim that lets snap apps use the NVIDIA GPU on the N1X.

NVIDIA's EGL core libraries on this SoC need `libnvidia-rmapi-tegra.so`, which snapd does not
expose to snaps, so every snap falls back to Mesa's software renderer (llvmpipe). The shim loads
that library by its `/var/lib/snapd/hostfs` path and then hands over to `libEGL_nvidia.so.0`.
Details: [docs/technical-notes.md](../../docs/technical-notes.md), section 5.

Install with `sudo bash install/09-snap-gpu.sh`, then restart the snap apps.

Check from inside a snap, e.g. with `snap run --shell <snap>`: an EGL client should report vendor
"NVIDIA" instead of "Mesa Project".
