// ASUS ProArt P16 H7607BA (NVIDIA N1X): hardware video decoding for every Firefox profile.
// Default values, read before the profile, so a profile can still change them. Installed to
// /usr/lib/firefox/defaults/pref/ by install/07-video-firefox.sh.
//
// VA-API (nvidia-vaapi-driver 0.0.14) decodes on this GPU but cannot export the decoded surfaces
// ("direct_realiseSurface: Unable to realise surface", vaExportSurfaceHandle fails with both
// backends), and Firefox has no VA-API path without export, so it falls back to dav1d/libvpx.
// Firefox's Vulkan video decoding works: NVDEC decodes AV1/VP9/H.264/HEVC, the decoder process
// uses 0-10 % CPU instead of several cores. Release builds block it for every GPU
// (FEATURE_VIDEO_DECODING_VULKAN_DISABLED); force-enabled ranks above the blocklist.
// H.264 is the exception: the driver's Vulkan H.264 decoder returns blocky frames, so a Vulkan layer
// (drivers/vk-hide-h264-decode) hides it from Firefox and H.264 decodes in software.
pref("media.hardware-video-decoding-vulkan.enabled", true);
pref("media.hardware-video-decoding-vulkan.force-enabled", true);
// The generic hardware decoding feature is blocklisted for NVIDIA on Linux
// (FEATURE_HARDWARE_VIDEO_DECODING_NO_LINUX_NVIDIA); force-enabled lifts that as well.
pref("media.hardware-video-decoding.force-enabled", true);
pref("widget.dmabuf.force-enabled", true);
// VA-API stays on as a fallback in case a later nvidia-vaapi-driver can export surfaces here.
pref("media.ffmpeg.vaapi.enabled", true);
