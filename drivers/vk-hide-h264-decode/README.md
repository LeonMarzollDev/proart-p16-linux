# vk-hide-h264-decode

Vulkan layer that hides `VK_KHR_video_decode_h264` from Firefox, so Firefox decodes H.264 in software
while AV1, VP9 and HEVC stay on NVDEC.

With NVIDIA 615.71.09 on the N1X, Vulkan H.264 decoding returns wrong pictures for some streams: blocks and
smears that last until the next keyframe, PSNR down to ~20 dB against a software decode. Whether a stream is
hit depends on the encoder settings (x264 `-preset fast` is, `-preset medium` is not). FFmpeg 8.0.1
(`-hwaccel vulkan`) and GStreamer (`vulkanh264dec`) both show it, while NVDEC through CUDA is bit-exact,
so the fault is in the driver's Vulkan video path. Firefox decodes H.264 through the system FFmpeg with
Vulkan (VP9/AV1 go through its bundled ffvpx), so H.264 sites such as VOE looked pixelated now and then.
Details: [docs/technical-notes.md](../../docs/technical-notes.md), section 5.

The layer is implicit: the Vulkan loader puts it into every native (arm64) Vulkan process, but it only
changes anything when the program name (`argv[0]`) is `firefox`, `firefox-bin` or `gfxtest` (the helper
that probes the decoders for Firefox). x86 programs under FEX-Emu cannot load it and skip it.

- `PROART_HIDE_H264_DECODE=1` activates it in any process, e.g. to test with FFmpeg.
- `PROART_HIDE_H264_DECODE=0` turns it off in Firefox; `PROART_HIDE_H264_DECODE_DISABLE=1` keeps the
  loader from loading it at all.

Install with `sudo bash install/07-video-firefox.sh`, then restart Firefox. Check: with
`PROART_HIDE_H264_DECODE=1 vulkaninfo` the extension list has no `VK_KHR_video_decode_h264`; Firefox's
`MOZ_LOG=PlatformDecoderModule:4` reports "Hw codec disabled by gfxVars for AV_CODEC_ID_H264".

Remove: `rm /usr/lib/aarch64-linux-gnu/libVkLayer_PROART_hide_h264_decode.so
/usr/share/vulkan/implicit_layer.d/VkLayer_PROART_hide_h264_decode.json`, when a driver fixes the bug.
