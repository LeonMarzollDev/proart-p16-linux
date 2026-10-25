# A "DGX OS" layer for the ProArt P16 (N1X) on Ubuntu 26.04

The DGX Spark (GB10) runs **DGX OS 7**, which is Ubuntu 24.04 plus NVIDIA repositories and a set of
small configuration packages. The N1X in this laptop is the same chip family (Blackwell GPU in a
20-core Arm SoC, shared LPDDR5X memory). [`install/13-dgx-stack.sh`](../install/13-dgx-stack.sh) gives
Ubuntu 26.04 the parts of DGX OS that matter for CUDA and AI work: CUDA, cuDNN, NCCL, TensorRT, the
Container Toolkit with CDI, Docker and AI Workbench. The display driver from `install/02-nvidia.sh`
stays as it is.

> Status: the repositories, package names, versions and DGX package contents below were checked on
> 2026-10-25 by downloading the indexes and unpacking the packages. **The script has not yet been
> run on the laptop** (`bash -n` only). Treat the first run as a test and read its warnings.

```
sudo bash install/13-dgx-stack.sh                    # cuda cudnn nccl container docker
sudo DGX_COMPONENTS="cuda cudnn nccl tensorrt container docker workbench limits" bash install/13-dgx-stack.sh
sudo DGX_TEST=1 bash install/13-dgx-stack.sh         # also runs nvidia-smi in a container through CDI
```

Components: `cuda` `cudnn` `nccl` `tensorrt` `cusparselt` `container` `docker` `workbench` `limits`
`persistenced` `cmdline` `dcgm`. Use `CUDA_VERSION=13-4` to choose a toolkit instead of the newest one.
The script can be run again: files are only rewritten when their content changes, and apt only
installs what is missing.

## Design rules

1. **The archive driver stays.** The CUDA repository has its own driver packages (`nvidia-open`,
   `nvidia-driver-open`, `cuda-drivers`, `libnvidia-compute`, ... 595.x through 615.x, unversioned
   names). They would replace the archive's `nvidia-*-615-open` packages, which are prebuilt for
   linux-nvidia and carry this project's settings. `/etc/apt/preferences.d/proart-cuda` gives every
   driver package from the CUDA repository (label `NVIDIA CUDA`) the priority -1. Before each install
   the script also runs `apt-get -s` and stops if a driver package from a source other than Ubuntu
   would be installed.
2. **No `cuda-keyring` package.** NVIDIA's `cuda-keyring_1.1-1_all.deb` writes
   `/etc/apt/preferences.d/cuda-repository-pin-600`, which pins **the whole CUDA repository at 600**,
   above the Ubuntu archive. With that pin the next `apt upgrade` installs NVIDIA's driver. The script
   downloads the repository key from the repository folder (`60DF8A40.pub`) instead, checks its
   fingerprint and writes a deb822 `.sources` file. DGX OS does something similar: its
   `cuda-compute-repo` package pins the repository at 580 and `cuda-drivers*` at -1.
3. **`sbsa`, not `arm64`.** Under `compute/cuda/repos/ubuntuXXXX/` the `arm64` folder is for Jetson
   (L4T, Tegra iGPU driver model). The DGX Spark uses `sbsa` (its `cuda-compute-repo` points to
   `ubuntu2404/sbsa`). The N1X GPU shows up as a PCI device (`10de:2e03`) on the open GPU kernel driver
   like GB10, so it uses `sbsa` too. For 26.04 the folder is `ubuntu2604/sbsa` (there is no
   `ubuntu2604/arm64`).
4. **If a repository is missing, fall back.** Every repository is checked with `curl -fsIL` for the
   running release first. If it is missing, the script uses the newest older one (CUDA:
   `ubuntu2404`, Docker: `noble`) and warns. If none is reachable, that component is skipped.
5. **Containers use CDI.** `nvidia-ctk runtime configure --runtime=docker --cdi.enabled` and
   `nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`; `nvidia-cdi-refresh.path` is enabled when
   the toolkit ships it, so the spec is rebuilt after driver updates. Start GPU containers with
   `--device nvidia.com/gpu=all`, not `--gpus all`. With `--gpus` a systemd reload (snap refresh, daily
   apt run) takes the GPU away from running containers (see
   [local-llm-benchmarks.md](local-llm-benchmarks.md)).

## Repository availability (checked 2026-10-25)

| Repository | URL | resolute (26.04) | Fallback | Notes |
|---|---|---|---|---|
| CUDA (sbsa) | `https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2604/sbsa/` | **yes** (InRelease 2026-10-22, label `NVIDIA CUDA`, key `14BAFBC7…60DF8A40`) | `ubuntu2404/sbsa` | CUDA 13.3, 13.4 (newest `cuda-toolkit-13-4` 13.4.3). Only CUDA 13 for 26.04; CUDA 12.x toolkits only in `ubuntu2404` |
| cuDNN | in the CUDA repo | yes | - | `cudnn9-cuda-13` (meta), `libcudnn9-cuda-13` 9.27.0.42 |
| NCCL | in the CUDA repo | yes | - | `libnccl2` / `libnccl-dev` 2.32.3+cuda13.4 |
| TensorRT | in the CUDA repo | yes | - | `tensorrt` 11.4.0.106+cuda13.4 (`libnvinfer11`) |
| cuSPARSELt, cuDSS | in the CUDA repo | yes | - | `libcusparselt0-cuda-13`, `cudss-cuda-13` |
| DCGM | in the CUDA repo | packages exist | - | `datacenter-gpu-manager-4-*` 4.7.0. **Not documented as supported on GB10/N1X**, see below |
| NVIDIA Container Toolkit | `https://nvidia.github.io/libnvidia-container/stable/deb/arm64/` | release independent | the CUDA repo carries it too | `nvidia-container-toolkit` 1.20.1; key `C95B321B…F796ECB0` |
| Docker CE | `https://download.docker.com/linux/ubuntu` suite `resolute` | **yes** (`docker-ce` 29.x, `containerd.io` 2.2.x, compose 5.x) | `noble`, then Ubuntu's `docker.io` | key `9DC85822…0EBFCD88` |
| AI Workbench | `https://workbench.download.nvidia.com/stable/linux/debian` suite `default`, component `proprietary` | release independent, arm64 | - | `nvidia-ai-workbench` 0.170.x; key `https://workbench.download.nvidia.com/stable/linux/gpgkey` (`52ECDF65…1266DE3C`). Depends on `libgtk-3-0` (provided by `libgtk-3-0t64`: not tested) |
| DGX BaseOS | `https://repo.download.nvidia.com/baseos/ubuntu/noble/arm64/` suites `noble`, `noble-updates`, components `common dgx` | **no** (`resolute` 404) | - | not added by the script (DGX/server packages; see below) |
| DGX Spark | `https://repo.download.nvidia.com/spark/ubuntu/arm64/` suite `noble-updates`, component `common` | suite `resolute-updates` **exists but is empty** (2026-10-23) | - | not added. Key `2C609607…6FE7EE4D` only ships inside `nvidia-spark-repo_1.1-1_arm64.deb` |

DGX OS 8 (Ubuntu 26.04, kernel 7.0.0-1010-nvidia, driver R595, CUDA 13.3.1 validated) was released on
2026-08-31, but its support table lists the DGX Spark only as "Future release". So there is no
Ubuntu 26.04 version of the Spark packages yet. The empty `resolute-updates` suite suggests one is
being prepared.

## What DGX OS 7 on the DGX Spark installs, and what this project does with it

The Spark gets everything below through `dgx-spark-ota-update-meta` (Spark repo) together with the
BaseOS meta packages `nvidia-system-core`, `nvidia-system-utils` and `nvidia-system-extra`. File
contents come from the unpacked `.deb` files (BaseOS `noble-updates` 2026-09-16, Spark repo
2026-10-23).

| DGX package | What it does | On the P16 |
|---|---|---|
| `cuda-compute-repo` | CUDA `ubuntu2404/sbsa` repo, pin 580, `cuda-drivers*` -1 | `proart-cuda.sources` for `ubuntu2604/sbsa`, all driver packages -1 |
| `nv-cuda-paths`, `nv-env-paths` | `PATH=/usr/local/cuda/bin:$PATH` in profile.d | `/etc/profile.d/proart-cuda.sh` (`cuda`) |
| `nvidia-system-utils` -> `nvidia-container-toolkit` | Container Toolkit | `container` |
| `nvidia-system-extra` -> `docker-ce`, `nv-docker-options` | Docker CE; on 24.04 only `After=/Wants=nvidia-gpu-reset.target` (the dockerd options are only for jammy) | `docker`. The gpu-reset target does not exist on a laptop |
| `ai-workbench-desktop-repo` | AI Workbench repo | `workbench` |
| `nvidia-spark-limits` | `memlock unlimited` (limits.d) "for the GPU driver" | `limits` |
| `nv-limits` | `nofile 500000` | `limits` |
| `nv-persistence-mode` | `nvidia-persistenced --persistence-mode`, enabled | `persistenced` (opt-in: keeps the GPU initialised, costs power on battery) |
| `nvidia-disable-init-on-alloc` | `init_on_alloc=0` (GRUB) | `cmdline` (opt-in; gives up a hardening default Ubuntu enables) |
| `nvidia-disable-numa-balancing` | `numa_balancing=disable` (GRUB) | `cmdline` (opt-in) |
| `nv-hugepage` | `transparent_hugepage=madvise` | not needed: already Ubuntu's default |
| `nvidia-spark-fstab-config` | adds `/swap.img` to fstab if there is no swap | not needed: the Ubuntu installer creates a swap file. CUDA does not count swap as free memory (see below) |
| `nvidia-spark-grub-kho` | `kho=off` (kexec handover) | not applied. Only has an effect if linux-nvidia enables KHO: **unverified** |
| `nvidia-spark-initcall-bl` | `initcall_blacklist=tegra234_cbb_init` | not applied. GB10 blocks the Tegra CBB error driver; whether the N1X/linux-nvidia needs this is **unverified** (check `dmesg` for `cbb` errors) |
| `nvidia-spark-grub-pci` | `pci=pcie_bus_safe` (ConnectX-7 on the Spark) | not applicable |
| `dgx-spark-mlnx-hotplug`, `nvidia-spark-mlnx-firmware-manager` | ConnectX-7 | not applicable (no ConnectX) |
| `nvidia-spark-realtek-mod-options` | binds `10ec:8127` to `r8127` | not applicable (the P16 has no wired Ethernet) |
| `nvidia-cppc-cpufreq-options` | `cppc_cpufreq auto_sel_mode=1` (CPU picks its own frequency) | not applied. It would compete with the ASUS fan/power modes and `optional/perf-mode.sh`; try it by hand |
| `nvidia-kernel-defaults` | sysctl `arp_announce=2`, `arp_ignore=1` (multi-NIC servers) | not applicable |
| `nvidia-spark-avahi-conf` | avahi: no hinfo/workstation, docker interfaces excluded (for NVIDIA Sync discovery) | not applied |
| `nvidia-lvfs-config` | `EspLocation=/boot/efi` in `fwupd.conf` | not applied (fwupd finds the ESP by itself on Ubuntu) |
| `nvidia-enable-bt-profiles`, `nvidia-spark-wifi-fw-ppa`, `nvidia-spark-desktop-edge-ppa`, `nvidia-desktop-default-snaps` | Spark desktop/firmware PPAs and snaps | not applicable |
| `dgx-dashboard`, `nvidia-dgx-telemetry`, `dgx-oobe*`, `nvidia-spark-ota-check`, `dgx-release` | DGX dashboard, telemetry, first-boot setup, OTA updates, DGX OS version | not installed. The dashboard (Python app) might work, but its repository is noble-only and its key is only distributed inside a `.deb` |

Not in DGX OS but useful here: NVIDIA Sync is a **client** app (on another PC) that connects to a
Spark over SSH. On the laptop itself there is nothing to install. To reach the laptop from another
machine through Sync, `openssh-server` and avahi are enough (**untested**).

## Unified memory: what is the same as on the Spark

These come from NVIDIA's DGX Spark known issues and this project's own measurements
([local-llm-rtx-spark](https://github.com/LeonMarzollDev/local-llm-rtx-spark)):

- `nvidia-smi` shows `Memory-Usage: Not Supported` on these iGPUs. That is expected; per-process
  memory is still listed. Use `free`, `/proc/meminfo` or `nvtop`.
- `cudaMemGetInfo()` does not count memory that could be reclaimed from swap or the page cache, so it
  reports less than can actually be allocated. NVIDIA suggests estimating from `MemAvailable`,
  `SwapFree` and HugePages in `/proc/meminfo`.
- The driver keeps freed GPU memory in its pool (`KReclaimable`). After a large model,
  `sync; echo 3 | sudo tee /proc/sys/vm/drop_caches` gives it back (NVIDIA lists the same command
  for debugging).
- The P16 has 64 GB (some units 128 GB) shared between CPU and GPU. A model that takes all of it can
  make the system unresponsive instead of raising a CUDA OOM error, as on the Spark. Leave headroom
  for the desktop.
- Kubernetes: the classic NVIDIA device plugin needs >= 0.17.4 on UMA GPUs
  (`nvmlDeviceGetMemoryInfo` returns Not Supported).

## DCGM

The CUDA repository has DCGM 4.7 for 26.04. NVIDIA does not document it as supported on GB10-class
iGPUs, and memory and many profiling fields read "Not Supported" there. `dcgm` is therefore opt-in and
marked experimental. For monitoring use `nvidia-smi`, `nvtop` and the `proart_ec` hwmon (power, fan).
**Unverified** on the N1X.

## Not reproducible

- The DGX OS kernel/driver combination (Spark: its own linux-nvidia kernel plus driver R580/R590 from
  NVIDIA's repo). This project uses linux-nvidia 7.0 with the 615 driver from the Ubuntu archive. The
  user space is the same; the versions are not.
- DGX OTA updates, `dgx-release`, the DGX Dashboard, telemetry and support tooling (`nvsm`,
  `nvidia-dgx-telemetry`), because they are tied to the Spark repository and hardware.
- NGC containers built for the Spark (`nvcr.io/nvidia/...:*-py3` arm64/sbsa) should run unchanged
  through CDI. Containers that expect CUDA 13.x with driver R580 also work on 615. **Untested on the
  P16**, except for the vLLM setup in the local-llm repository.

## Checking

`bash tools/check.sh` (section "DGX stack") checks the repository pin, the driver origin, nvcc, the
CDI spec, the docker group and a GPU container.

Sources: NVIDIA DGX OS 8 release notes (docs.nvidia.com/dgx/dgx-os-8-user-guide/8.0.0/release-notes.html),
DGX Spark known issues (docs.nvidia.com/dgx/dgx-spark/known-issues.html), the package indexes and
`.deb` files of the repositories in the table above.
