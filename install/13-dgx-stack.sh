#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - step 13 (optional): "DGX OS"-like compute stack for the N1X
#
# DGX OS 7 (Ubuntu 24.04) on the DGX Spark (GB10, the same chip family as the N1X) is Ubuntu plus
# NVIDIA's CUDA repository, Docker + NVIDIA Container Toolkit and a handful of small config packages
# (docs/dgx-stack.md lists all of them and what they set). This script reproduces the parts that make
# sense on a laptop, without touching the display driver:
#
#  - The NVIDIA driver stays the one from the Ubuntu archive (install/02-nvidia.sh, nvidia-*-615-open,
#    prebuilt for linux-nvidia). The CUDA repository also carries driver packages (nvidia-open,
#    cuda-drivers, libnvidia-compute, ...); an APT pin blocks all of them (Pin-Priority -1), and every
#    install is simulated first and aborted if it would still pull a driver package.
#  - The CUDA repository is added for the running release (ubuntu2604/sbsa on 26.04). If NVIDIA has no
#    repository for it, the newest older one that exists is used, with a warning. The N1X uses the
#    "sbsa" repositories like the DGX Spark, NOT "arm64" (that one is for Jetson / L4T).
#  - NVIDIA's cuda-keyring package is deliberately NOT used: it adds a pin of 600 for the whole CUDA
#    repository, which would replace the archive driver on the next upgrade.
#
# Components (DGX_COMPONENTS, space separated; default "cuda cudnn nccl container docker"):
#   cuda         CUDA toolkit (cuda-toolkit-X-Y, newest; override CUDA_VERSION=13-4) + PATH in profile.d
#   cudnn        cuDNN 9 for that CUDA major
#   nccl         NCCL (libnccl2, libnccl-dev)
#   tensorrt     TensorRT (large; the "tensorrt" meta package)
#   cusparselt   cuSPARSELt
#   container    NVIDIA Container Toolkit (NVIDIA's libnvidia-container repository), CDI spec
#   docker       Docker CE (download.docker.com) configured for the NVIDIA runtime + CDI; user -> docker group
#   workbench    NVIDIA AI Workbench desktop app (workbench.download.nvidia.com)
#   limits       DGX Spark limits: memlock unlimited, nofile 500000 (nvidia-spark-limits, nv-limits)
#   persistenced nvidia-persistenced in persistence mode (nv-persistence-mode); costs some idle power
#   cmdline      DGX core kernel options init_on_alloc=0 numa_balancing=disable (GRUB drop-in)
#   dcgm         DCGM 4 (experimental: not documented as supported on GB10/N1X iGPUs)
# Example: sudo DGX_COMPONENTS="cuda cudnn nccl tensorrt container docker limits" bash install/13-dgx-stack.sh
# DGX_TEST=1 also runs a CUDA container (pulls ubuntu image) to prove GPU access through CDI.
#
# Remove: apt remove 'cuda-toolkit-*' 'cudnn9-*' 'libcudnn9-*' libnccl2 libnccl-dev tensorrt 'libnvinfer*' \
#         nvidia-container-toolkit docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
#         nvidia-ai-workbench 'datacenter-gpu-manager-4-*';
#         rm /etc/apt/sources.list.d/proart-{cuda,nvidia-container,docker,ai-workbench}.sources \
#            /etc/apt/preferences.d/proart-cuda /usr/share/keyrings/proart-{cuda,nvidia-container,docker,ai-workbench}.gpg \
#            /etc/profile.d/proart-cuda.sh /etc/security/limits.d/90-proart-dgx.conf \
#            /etc/systemd/system/nvidia-persistenced.service.d/50-proart-dgx.conf \
#            /etc/default/grub.d/90-proart-dgx.cfg /etc/cdi/nvidia.yaml; update-grub
# Run with: sudo bash install/13-dgx-stack.sh
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_root

COMPONENTS=" ${DGX_COMPONENTS:-cuda cudnn nccl container docker} "
want() { [[ "$COMPONENTS" == *" $1 "* ]]; }
warn() { printf '\e[33mWarning:\e[0m %s\n' "$*" >&2; }
url_ok() { curl -fsIL --max-time 20 "$1" >/dev/null 2>&1; }

. /etc/os-release
CODENAME=$VERSION_CODENAME
ARCH=$(dpkg --print-architecture)
[ "$ARCH" = arm64 ] || { echo "This script is for the arm64 N1X (dpkg architecture: $ARCH)"; exit 1; }
KEYS=/usr/share/keyrings
SRC=/etc/apt/sources.list.d

# Known signing keys (checked 2026-10-25). A key that does not match is rejected.
CUDA_FPRS="14BAFBC7562AD710CA04E69905FBB6DA60DF8A40 EB693B3035CD5710E231E123A4B469963BF863CC"
NVCTK_FPRS="C95B321B61E88C1809C4F759DDCAE044F796ECB0 2041629BF5352FAC178A9B1F6ED91CA3AC1160CD"
DOCKER_FPRS="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
WORKBENCH_FPRS="52ECDF6597CFBD86D5BF4DB3CD63F8B21266DE3C"

apt-get install -y ca-certificates curl gnupg >/dev/null

# install_key <url> <keyring> <allowed fingerprints...>: download, dearmor, check fingerprint
install_key() {
	local url=$1 out=$2; shift 2
	local tmp fprs f ok=0
	tmp=$(mktemp -d)
	curl -fsSL --max-time 30 "$url" -o "$tmp/key" || { rm -rf "$tmp"; return 1; }
	if grep -q 'BEGIN PGP' "$tmp/key"; then
		gpg --batch --yes --dearmor -o "$tmp/key.gpg" "$tmp/key"
	else
		cp "$tmp/key" "$tmp/key.gpg"
	fi
	fprs=$(gpg --batch --show-keys --with-colons "$tmp/key.gpg" 2>/dev/null | awk -F: '$1=="fpr"{print $10}')
	for f in $fprs; do [[ " $* " == *" $f "* ]] && ok=1; done
	if [ $ok -ne 1 ]; then
		warn "unexpected signing key from $url ($fprs) - not installed"
		rm -rf "$tmp"; return 1
	fi
	install -m 644 "$tmp/key.gpg" "$out"
	rm -rf "$tmp"
}

# write_if_changed <file> (content on stdin): keeps the script idempotent and quiet
write_if_changed() {
	local tmp; tmp=$(mktemp)
	cat > "$tmp"
	if [ -f "$1" ] && cmp -s "$tmp" "$1"; then rm -f "$tmp"; return 1; fi
	install -D -m 644 "$tmp" "$1"; rm -f "$tmp"
}

# Driver packages that must never come from the CUDA repository (the archive's 615 branch stays).
DRIVER_RE='^(nvidia-(driver|open|dkms|headless|kernel|utils|compute-utils|settings|modprobe|persistenced|firmware|xconfig|fabricmanager|imex|fs|gds|driver-pinning|driver-assistant)|libnvidia-(cfg|common|compute|decode|encode|extra|fbc|gl|gpucomp|nscq|egl|ml|ngx|nvvm|ptxjitcompiler|rtcore|tls|glcore|glvkspirv|allocator|opticalflow|sandboxutils|pkcs11|vksc)|libxnvctrl|xserver-xorg-video-nvidia|cuda-drivers|cuda-compat|nvlink)'

# apt_install <packages...>: simulate first; refuse anything that would replace the display driver
apt_install() {
	local sim bad
	sim=$(apt-get -s install -y --no-install-recommends "$@" 2>&1) || { echo "$sim" | tail -5 >&2; return 1; }
	# archive (Ubuntu:...) upgrades of the 615 driver are fine; anything else matching is not
	bad=$(echo "$sim" | grep "^Inst " | grep -v " Ubuntu:" | awk '{print $2}' | grep -E "$DRIVER_RE" || true)
	if [ -n "$bad" ]; then
		warn "installing '$*' would replace NVIDIA driver packages ($(echo $bad)); skipped"
		return 1
	fi
	apt-get install -y --no-install-recommends "$@"
}

newest_pkg() { apt-cache pkgnames "$1" 2>/dev/null | grep -E "$2" | sort -V | tail -1; }

echo "== 1/6 Driver check"
DRV=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)
if [ -z "$DRV" ]; then
	warn "nvidia-smi does not work: run install/01-kernel.sh and install/02-nvidia.sh first (CUDA needs the driver)"
else
	echo "NVIDIA driver $DRV (from: $(dpkg-query -W -f='${Package} ' 'nvidia-utils-*' 2>/dev/null | sed 's/ $//'))"
	[ "${DRV%%.*}" -ge 580 ] || warn "driver $DRV is older than R580; CUDA 13 needs >= 580"
fi

echo "== 2/6 Package repositories"
NEED_CUDA=0
for c in cuda cudnn nccl tensorrt cusparselt dcgm; do want $c && NEED_CUDA=1; done
CUDA_OK=0
if [ $NEED_CUDA -eq 1 ]; then
	CUDA_BASE=https://developer.download.nvidia.com/compute/cuda/repos
	CUDA_DIST=""
	for d in "ubuntu${VERSION_ID//./}" ubuntu2604 ubuntu2404 ubuntu2204; do
		url_ok "$CUDA_BASE/$d/sbsa/InRelease" && { CUDA_DIST=$d; break; }
	done
	if [ -z "$CUDA_DIST" ]; then
		warn "no CUDA sbsa repository reachable - skipping CUDA components"
	else
		[ "$CUDA_DIST" = "ubuntu${VERSION_ID//./}" ] ||
			warn "NVIDIA has no CUDA repository for Ubuntu $VERSION_ID yet; using $CUDA_DIST (built for an older Ubuntu, may not install cleanly)"
		CUDA_URL="$CUDA_BASE/$CUDA_DIST/sbsa/"
		# the signing key file is listed in the repository directory (e.g. 60DF8A40.pub)
		pub=$(curl -fsSL --max-time 30 "$CUDA_URL" | grep -oE '[0-9A-F]{8}\.pub' | sort -u | tail -1 || true)
		if [ -n "$pub" ] && install_key "$CUDA_URL$pub" $KEYS/proart-cuda.gpg $CUDA_FPRS; then
			write_if_changed $SRC/proart-cuda.sources <<EOF || true
# Added by proart-p16-linux install/13-dgx-stack.sh
Types: deb
URIs: $CUDA_URL
Suites: /
Signed-By: $KEYS/proart-cuda.gpg
EOF
			# DGX OS (cuda-compute-repo) uses 580 for the repo and -1 for cuda-drivers; here every
			# driver package from the CUDA repo is blocked, because the archive driver drives the display.
			write_if_changed /etc/apt/preferences.d/proart-cuda <<EOF || true
# Added by proart-p16-linux install/13-dgx-stack.sh: CUDA libraries yes, NVIDIA driver no.
Package: /$DRIVER_RE/
Pin: release l=NVIDIA CUDA
Pin-Priority: -1

Package: *
Pin: release l=NVIDIA CUDA
Pin-Priority: 500
EOF
			CUDA_OK=1
			echo "CUDA repository: $CUDA_URL"
		else
			warn "could not install the CUDA repository key - skipping CUDA components"
		fi
	fi
fi

if want container || want docker; then
	NVCTK_URL=https://nvidia.github.io/libnvidia-container/stable/deb/$ARCH
	if url_ok "$NVCTK_URL/InRelease" && install_key https://nvidia.github.io/libnvidia-container/gpgkey $KEYS/proart-nvidia-container.gpg $NVCTK_FPRS; then
		write_if_changed $SRC/proart-nvidia-container.sources <<EOF || true
# Added by proart-p16-linux install/13-dgx-stack.sh
Types: deb
URIs: $NVCTK_URL
Suites: /
Signed-By: $KEYS/proart-nvidia-container.gpg
EOF
	else
		warn "NVIDIA Container Toolkit repository not reachable (the CUDA repository also carries it)"
	fi
fi

DOCKER_OK=0
if want docker; then
	if dpkg -s docker.io >/dev/null 2>&1; then
		echo "Ubuntu's docker.io is installed - using it instead of Docker CE"
		DOCKER_OK=2
	else
		DOCKER_SUITE=""
		for s in "$CODENAME" noble; do
			url_ok "https://download.docker.com/linux/ubuntu/dists/$s/InRelease" && { DOCKER_SUITE=$s; break; }
		done
		if [ -z "$DOCKER_SUITE" ]; then
			warn "Docker CE repository not reachable - falling back to Ubuntu's docker.io"
			DOCKER_OK=3
		elif install_key https://download.docker.com/linux/ubuntu/gpg $KEYS/proart-docker.gpg $DOCKER_FPRS; then
			[ "$DOCKER_SUITE" = "$CODENAME" ] || warn "Docker CE has no $CODENAME repository yet; using $DOCKER_SUITE"
			write_if_changed $SRC/proart-docker.sources <<EOF || true
# Added by proart-p16-linux install/13-dgx-stack.sh
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $DOCKER_SUITE
Components: stable
Architectures: $ARCH
Signed-By: $KEYS/proart-docker.gpg
EOF
			DOCKER_OK=1
		fi
	fi
fi

if want workbench; then
	WB_URL=https://workbench.download.nvidia.com/stable/linux/debian
	if url_ok "$WB_URL/dists/default/InRelease" && install_key https://workbench.download.nvidia.com/stable/linux/gpgkey $KEYS/proart-ai-workbench.gpg $WORKBENCH_FPRS; then
		write_if_changed $SRC/proart-ai-workbench.sources <<EOF || true
# Added by proart-p16-linux install/13-dgx-stack.sh (same repository as DGX OS ai-workbench-desktop-repo)
Types: deb
URIs: $WB_URL
Suites: default
Components: proprietary
Signed-By: $KEYS/proart-ai-workbench.gpg
EOF
	else
		warn "AI Workbench repository not reachable - skipping"
	fi
fi
apt_update

echo "== 3/6 CUDA libraries"
CUDA_MAJOR=""
if [ $CUDA_OK -eq 1 ]; then
	if want cuda; then
		CT=${CUDA_VERSION:+cuda-toolkit-$CUDA_VERSION}
		[ -n "$CT" ] || CT=$(newest_pkg cuda-toolkit- '^cuda-toolkit-[0-9]+-[0-9]+$')
		if [ -n "$CT" ] && apt_install "$CT"; then
			CV=${CT#cuda-toolkit-}
			write_if_changed /etc/profile.d/proart-cuda.sh <<EOF || true
# Added by proart-p16-linux install/13-dgx-stack.sh (as DGX OS nv-cuda-paths)
[ -d /usr/local/cuda/bin ] && case ":\$PATH:" in *:/usr/local/cuda/bin:*) ;; *) PATH=/usr/local/cuda/bin:\$PATH ;; esac
EOF
			echo "Installed $CT (/usr/local/cuda-${CV//-/.})"
		else
			warn "CUDA toolkit not installed"
		fi
	fi
	# CUDA major of the installed (or newest available) toolkit, for the library flavours
	CUDA_MAJOR=$(ls -d /usr/local/cuda-[0-9]* 2>/dev/null | sed 's#.*/cuda-##' | sort -V | tail -1 | cut -d. -f1)
	[ -n "$CUDA_MAJOR" ] || CUDA_MAJOR=$(newest_pkg cuda-toolkit- '^cuda-toolkit-[0-9]+-[0-9]+$' | cut -d- -f3)
	if want cudnn; then
		if apt-cache show "cudnn9-cuda-$CUDA_MAJOR" >/dev/null 2>&1; then
			apt_install "cudnn9-cuda-$CUDA_MAJOR" || warn "cuDNN not installed"
		else
			apt_install "libcudnn9-cuda-$CUDA_MAJOR" "libcudnn9-dev-cuda-$CUDA_MAJOR" || warn "cuDNN not installed"
		fi
	fi
	want nccl && { apt_install libnccl2 libnccl-dev || warn "NCCL not installed"; }
	want tensorrt && { apt_install tensorrt || warn "TensorRT not installed"; }
	want cusparselt && { apt_install "libcusparselt0-cuda-$CUDA_MAJOR" "libcusparselt0-dev-cuda-$CUDA_MAJOR" || warn "cuSPARSELt not installed"; }
	if want dcgm; then
		warn "DCGM is experimental here: NVIDIA does not list GB10/N1X iGPUs as supported; many fields read 'Not Supported'"
		apt_install "datacenter-gpu-manager-4-cuda$CUDA_MAJOR" && systemctl enable --now nvidia-dcgm 2>/dev/null ||
			warn "DCGM not installed or its service did not start"
	fi
else
	[ $NEED_CUDA -eq 0 ] || warn "CUDA repository missing - CUDA components skipped"
fi

echo "== 4/6 Containers"
if want container || want docker; then
	apt_install nvidia-container-toolkit || warn "NVIDIA Container Toolkit not installed"
fi
if want docker; then
	case $DOCKER_OK in
		1) apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || warn "Docker CE not installed" ;;
		3) apt_install docker.io docker-compose-v2 || warn "docker.io not installed" ;;
	esac
	if command -v docker >/dev/null && command -v nvidia-ctk >/dev/null; then
		# CDI is preferred (docs/local-llm-benchmarks.md): with --gpus/the legacy hook a systemd reload
		# takes the GPU away from running containers. The runtime is still registered for tools that need it.
		nvidia-ctk runtime configure --runtime=docker --cdi.enabled >/dev/null
		systemctl restart docker
		if u=$(target_user 2>/dev/null); then
			id -nG "$u" | grep -qw docker || { usermod -aG docker "$u"; echo "Added $u to the docker group (log out and in again)"; }
		else
			warn "desktop user unknown (run through sudo): add yourself to the docker group manually"
		fi
	fi
fi
if command -v nvidia-ctk >/dev/null; then
	# the toolkit (>= 1.18) regenerates the spec itself when the driver changes; enable that if present
	if systemctl list-unit-files nvidia-cdi-refresh.path 2>/dev/null | grep -q nvidia-cdi-refresh; then
		systemctl enable --now nvidia-cdi-refresh.path >/dev/null 2>&1 || true
	fi
	if [ -n "$DRV" ]; then
		mkdir -p /etc/cdi
		nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml >/dev/null 2>&1 &&
			echo "CDI devices: $(nvidia-ctk cdi list 2>/dev/null | grep -c nvidia.com/gpu) (use: docker run --device nvidia.com/gpu=all ...)" ||
			warn "nvidia-ctk cdi generate failed"
	fi
fi
if want workbench && [ -f $SRC/proart-ai-workbench.sources ]; then
	apt_install nvidia-ai-workbench || warn "AI Workbench not installed"
fi

echo "== 5/6 DGX system settings"
if want limits; then
	write_if_changed /etc/security/limits.d/90-proart-dgx.conf <<'EOF' && echo "limits: memlock unlimited, nofile 500000 (next login)" || true
# Added by proart-p16-linux install/13-dgx-stack.sh - as DGX OS nvidia-spark-limits + nv-limits
*   soft    memlock   unlimited
*   hard    memlock   unlimited
*   soft    nofile    500000
*   hard    nofile    500000
EOF
fi
if want persistenced; then
	if systemctl cat nvidia-persistenced.service >/dev/null 2>&1; then
		write_if_changed /etc/systemd/system/nvidia-persistenced.service.d/50-proart-dgx.conf <<'EOF' || true
# Added by proart-p16-linux install/13-dgx-stack.sh - as DGX OS nv-persistence-mode
[Service]
ExecStart=
ExecStart=/usr/bin/nvidia-persistenced --persistence-mode --verbose
EOF
		systemctl daemon-reload
		systemctl enable --now nvidia-persistenced >/dev/null 2>&1 || warn "nvidia-persistenced did not start"
	else
		warn "nvidia-persistenced.service not found (it comes with nvidia-compute-utils-615)"
	fi
fi
if want cmdline; then
	if write_if_changed /etc/default/grub.d/90-proart-dgx.cfg <<'EOF'; then
# Added by proart-p16-linux install/13-dgx-stack.sh - DGX OS nvidia-disable-init-on-alloc and
# nvidia-disable-numa-balancing. init_on_alloc=0 trades a hardening default for faster large allocations.
GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX init_on_alloc=0 numa_balancing=disable"
EOF
		update-grub
		echo "Kernel options added (active after reboot)"
	fi
fi

echo "== 6/6 Verify"
nvidia-smi -L 2>/dev/null || warn "nvidia-smi -L failed"
NVCC=$(ls /usr/local/cuda/bin/nvcc /usr/local/cuda-*/bin/nvcc 2>/dev/null | head -1 || true)
[ -n "$NVCC" ] && "$NVCC" --version | tail -2
command -v docker >/dev/null && docker info --format 'docker {{.ServerVersion}}, runtimes: {{range $k,$v := .Runtimes}}{{$k}} {{end}}, CDI: {{.CDISpecDirs}}' 2>/dev/null || true
if [ "${DGX_TEST:-0}" = 1 ] && command -v docker >/dev/null; then
	docker run --rm --device nvidia.com/gpu=all ubuntu:26.04 nvidia-smi -L || warn "container GPU test failed"
fi
echo
echo "Done. Log out and back in (docker group, PATH). Check with: bash tools/check.sh"
