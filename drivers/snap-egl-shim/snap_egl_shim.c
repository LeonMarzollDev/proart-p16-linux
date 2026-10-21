// SPDX-License-Identifier: GPL-2.0-only
/*
 * NVIDIA EGL for snaps on NVIDIA N1X / GB10 (aarch64).
 *
 * On these SoCs libnvidia-eglcore, -glcore and -glsi need libnvidia-rmapi-tegra.so, but
 * snap-confine only exposes the NVIDIA libraries on its fixed list to snaps
 * (/var/lib/snapd/lib/gl), and that list has no rmapi-tegra. libEGL_nvidia therefore fails to
 * load inside every snap and glvnd falls back to Mesa's software renderer (llvmpipe).
 *
 * This is a glvnd EGL vendor library that loads rmapi-tegra by its absolute host path first
 * (the dynamic linker then satisfies the DT_NEEDED entries by soname) and then hands over to
 * the real libEGL_nvidia. Its vendor JSON points to the /var/lib/snapd/hostfs path, which only
 * exists inside snaps, so on the host glvnd cannot load it and silently skips it.
 */
#include <dlfcn.h>
#include <glob.h>
#include <stdint.h>
#include <stdio.h>

#define HOSTFS_LIBS "/var/lib/snapd/hostfs/usr/lib/*-linux-gnu/"

typedef unsigned int (*egl_main_t)(uint32_t version, const void *exports, void *vendor,
				   void *imports);

static egl_main_t real_main;

__attribute__((constructor)) static void shim_init(void)
{
	glob_t g;
	void *nv;

	if (glob(HOSTFS_LIBS "libnvidia-rmapi-tegra.so.*", 0, NULL, &g) == 0) {
		/* glob() sorts, so with several driver versions the newest comes last */
		dlopen(g.gl_pathv[g.gl_pathc - 1], RTLD_NOW | RTLD_GLOBAL);
		globfree(&g);
	}
	nv = dlopen("libEGL_nvidia.so.0", RTLD_NOW | RTLD_LOCAL);
	/* for snaps whose LD_LIBRARY_PATH lacks snapd's NVIDIA directory */
	if (!nv)
		nv = dlopen("/var/lib/snapd/lib/gl/libEGL_nvidia.so.0", RTLD_NOW | RTLD_LOCAL);
	if (!nv) {
		fprintf(stderr, "snap-egl-shim: %s\n", dlerror());
		return;
	}
	real_main = (egl_main_t)dlsym(nv, "__egl_Main");
}

/* glvnd's vendor entry point; returning 0 makes glvnd skip this vendor */
__attribute__((visibility("default")))
unsigned int __egl_Main(uint32_t version, const void *exports, void *vendor, void *imports)
{
	return real_main ? real_main(version, exports, vendor, imports) : 0;
}
