// SPDX-License-Identifier: GPL-2.0-only
// Vulkan layer: hides VK_KHR_video_decode_h264 from Firefox, so it decodes H.264 in software.
// The NVIDIA 615.71.09 driver's Vulkan H.264 decoding returns wrong pictures on the N1X for some streams (blocky
// frames until the next IDR; FFmpeg 8.0.1 -hwaccel vulkan and GStreamer vulkanh264dec both show it, NVDEC through
// CUDA is bit-exact). Its Vulkan VP9/AV1/HEVC decoding is fine and stays available.
// Implicit layer, loaded into every native Vulkan process but only active in Firefox (program name firefox,
// firefox-bin, or Firefox's decoder probe gfxtest). PROART_HIDE_H264_DECODE=1 activates it in any process
// (testing), =0 turns it off.
// Built and installed by install/07-video-firefox.sh.
#define _GNU_SOURCE
#include <errno.h>
#include <stdlib.h>

typedef unsigned int u32;
typedef int VkResult;
typedef void *VkInstance, *VkPhysicalDevice, *VkDevice;
typedef void (*PFN_vkVoidFunction)(void);
typedef PFN_vkVoidFunction (*PFN_gipa)(VkInstance, const char *);
typedef PFN_vkVoidFunction (*PFN_gdpa)(VkDevice, const char *);
typedef VkResult (*PFN_createInstance)(const void *, const void *, VkInstance *);
typedef VkResult (*PFN_createDevice)(VkPhysicalDevice, const void *, const void *, VkDevice *);
typedef VkResult (*PFN_enumDevExt)(VkPhysicalDevice, const char *, u32 *, void *);
typedef struct { char name[256]; u32 spec; } ExtProps;
typedef struct { int sType; const void *pNext; u32 flags, queueCount; const void *queues; u32 layerCount;
	const char *const *layers; u32 extCount; const char *const *exts; const void *features; } DeviceCreateInfo;

typedef struct { int sType; const void *pNext; } Base;
typedef struct InstLink { struct InstLink *pNext; PFN_gipa nextGipa; void *nextGpdpa; } InstLink;
typedef struct { int sType; const void *pNext; int function; InstLink *pLayerInfo; } InstChainInfo;
typedef struct DevLink { struct DevLink *pNext; PFN_gipa nextGipa; PFN_gdpa nextGdpa; } DevLink;
typedef struct { int sType; const void *pNext; int function; DevLink *pLayerInfo; } DevChainInfo;
typedef struct { int sType; void *pNext; u32 version; PFN_gipa gipa; PFN_gdpa gdpa; void *gpdpa; } Negotiate;

enum { LOADER_INSTANCE_CREATE_INFO = 47, LOADER_DEVICE_CREATE_INFO = 48, LAYER_LINK_INFO = 0 };

static PFN_gipa next_gipa;
static PFN_gdpa next_gdpa;
static PFN_enumDevExt next_enum_dev_ext;

static int eq(const char *a, const char *b) { while (*a && *a == *b) { a++; b++; } return *a == *b; }
static int active = -1;

// argv[0] needs no syscall: Firefox's sandboxed processes may not be allowed to read /proc/self/exe
static int is_active(void) {
	if (active >= 0) return active;
	const char *env = getenv("PROART_HIDE_H264_DECODE");
	if (env && (env[0] == '0' || env[0] == '1')) return active = env[0] == '1';
	const char *name = program_invocation_short_name;
	// gfxtest is the helper that probes the decoders for Firefox (its result decides software vs. hardware)
	return active = eq(name, "firefox") || eq(name, "firefox-bin") || eq(name, "gfxtest");
}

static int hidden(const char *ext) { return is_active() && eq(ext, "VK_KHR_video_decode_h264"); }

static VkResult enum_dev_ext(VkPhysicalDevice pd, const char *layer, u32 *count, void *out) {
	if (layer) return next_enum_dev_ext(pd, layer, count, out);
	// heap, not stack: the 260 KiB would overflow small thread stacks (Firefox's decoder threads crashed)
	u32 n = 0;
	VkResult r = next_enum_dev_ext(pd, 0, &n, 0);
	if (r < 0) return r;
	ExtProps *buf = malloc(sizeof(ExtProps) * (n ? n : 1));
	if (!buf) return -1;   // VK_ERROR_OUT_OF_HOST_MEMORY
	r = next_enum_dev_ext(pd, 0, &n, buf);
	if (r < 0) { free(buf); return r; }
	u32 kept = 0;
	for (u32 i = 0; i < n; i++) {
		if (hidden(buf[i].name)) continue;
		if (out) {
			if (kept >= *count) { free(buf); return 5; }   // VK_INCOMPLETE
			((ExtProps *)out)[kept] = buf[i];
		}
		kept++;
	}
	free(buf);
	*count = kept;
	return 0;
}

static VkResult create_instance(const void *info, const void *alloc, VkInstance *inst) {
	InstChainInfo *chain = (InstChainInfo *)((const Base *)info)->pNext;
	while (chain && !(chain->sType == LOADER_INSTANCE_CREATE_INFO && chain->function == LAYER_LINK_INFO))
		chain = (InstChainInfo *)chain->pNext;
	if (!chain) return -3;   // VK_ERROR_INITIALIZATION_FAILED
	PFN_gipa gipa = chain->pLayerInfo->nextGipa;
	chain->pLayerInfo = chain->pLayerInfo->pNext;
	PFN_createInstance create = (PFN_createInstance)gipa(0, "vkCreateInstance");
	VkResult r = create(info, alloc, inst);
	if (r == 0) {
		next_gipa = gipa;
		next_enum_dev_ext = (PFN_enumDevExt)gipa(*inst, "vkEnumerateDeviceExtensionProperties");
	}
	return r;
}

static VkResult create_device(VkPhysicalDevice pd, const void *info, const void *alloc, VkDevice *dev) {
	DevChainInfo *chain = (DevChainInfo *)((const Base *)info)->pNext;
	while (chain && !(chain->sType == LOADER_DEVICE_CREATE_INFO && chain->function == LAYER_LINK_INFO))
		chain = (DevChainInfo *)chain->pNext;
	if (!chain) return -3;
	PFN_gipa gipa = chain->pLayerInfo->nextGipa;
	PFN_gdpa gdpa = chain->pLayerInfo->nextGdpa;
	chain->pLayerInfo = chain->pLayerInfo->pNext;
	PFN_createDevice create = (PFN_createDevice)gipa(0, "vkCreateDevice");
	DeviceCreateInfo copy = *(const DeviceCreateInfo *)info;
	const char **names = malloc(sizeof(char *) * (copy.extCount ? copy.extCount : 1));
	if (!names) return -1;
	u32 n = 0;
	for (u32 i = 0; i < copy.extCount; i++)
		if (!hidden(copy.exts[i])) names[n++] = copy.exts[i];
	copy.extCount = n;
	copy.exts = names;
	VkResult r = create(pd, &copy, alloc, dev);
	free(names);
	if (r == 0) next_gdpa = gdpa;
	return r;
}

static PFN_vkVoidFunction layer_gdpa(VkDevice dev, const char *name) {
	if (eq(name, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunction)layer_gdpa;
	return next_gdpa ? next_gdpa(dev, name) : 0;
}

static PFN_vkVoidFunction layer_gipa(VkInstance inst, const char *name) {
	if (eq(name, "vkGetInstanceProcAddr")) return (PFN_vkVoidFunction)layer_gipa;
	if (eq(name, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunction)layer_gdpa;
	if (eq(name, "vkCreateInstance")) return (PFN_vkVoidFunction)create_instance;
	if (eq(name, "vkCreateDevice")) return (PFN_vkVoidFunction)create_device;
	if (eq(name, "vkEnumerateDeviceExtensionProperties") && next_enum_dev_ext) return (PFN_vkVoidFunction)enum_dev_ext;
	return next_gipa ? next_gipa(inst, name) : 0;
}

__attribute__((visibility("default"))) VkResult vkNegotiateLoaderLayerInterfaceVersion(Negotiate *n) {
	if (n->version > 2) n->version = 2;
	n->gipa = layer_gipa;
	n->gdpa = layer_gdpa;
	n->gpdpa = 0;
	return 0;
}
