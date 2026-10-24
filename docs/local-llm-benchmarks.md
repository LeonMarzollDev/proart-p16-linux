# Local LLMs on the ProArt P16

The local-LLM work on this laptop (vLLM on the RTX Spark N1X: speed, context, quality, coding harnesses, and the
fixes that make a 96 GB model start reliably on 128 GB of shared memory) has its own repository now:
**[local-llm-rtx-spark](https://github.com/LeonMarzollDev/local-llm-rtx-spark)**.

In short, measured on this laptop in October 2026:

| Model / preset | Generation | 30k prompt: new / again | Quality (code · tools · math) |
|---|---|---|---|
| Qwen3.8 Flash-Next (MoE, MTP×3) | ~60 tok/s (code 62–65) | 12.3 s / 0.15 s | 97.5 % · 93 % · 98 % |
| Qwen3.8 27B, DFlash2×10 | 35.1 tok/s (code 64.3) | 15.7 s / 5.8 s | 95 % · 88 % · 96 % |
| Qwen3.8 27B, MTP×4 | 32.0 tok/s (code 36.8) | 16.4 s / 1.9 s | 95 % · 88 % · 98 % |

Things there that touch the laptop setup as well:

- Docker containers that use the GPU should get it via CDI (`--device nvidia.com/gpu=all`) instead of
  `--gpus all`: otherwise every systemd reload (a snap refresh, the daily apt upgrade) takes the GPU away from
  running containers.
- The NVIDIA driver keeps freed GPU memory in its system memory pool (`KReclaimable` in `/proc/meminfo`) and does
  not hand it back quickly: after a big model, `echo 3 > /proc/sys/vm/drop_caches` frees it.
- The N1X has 10 fast (Cortex-X925, 4.0 GHz) and 10 slower (Cortex-A725, 2.8 GHz) cores; single-threaded loading
  work that Linux places on the slow ones runs ~3× slower. Pinning to the fast cores helps.
