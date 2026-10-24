# Local LLMs on the ProArt P16 (NVIDIA RTX Spark N1X): speed and quality

Measurements of Qwen3.8 27B and Qwen3.8 Flash-Next served with vLLM on the ProArt P16 H7607BA, October 2026:
how fast they generate and read prompts, how speculative decoding (MTP, DFlash) changes that, how much memory the
context needs, how far the context goes, and whether quality holds up. One request at a time (a single chat), the
way a local assistant or coding tool uses a model.

## Summary

| Model / preset | Generation | 30k prompt: new / again | Quality (code · tools · math) | Needs |
|---|---|---|---|---|
| **Qwen3.8 Flash-Next** (MoE, MTP×3) | **~60 tok/s** (code 62–65) | **12.3 s / 0.15 s** | **97.5 % · 93 % · 98 %** | ~87 GiB: everything else must pause; ~5 min start |
| Qwen3.8 27B, DFlash2×10 ("fast") | 35.1 tok/s (code 64.3) | 15.7 s / 5.8 s | 95 % · 88 % · 96 % (×12) | ~45–63 GiB |
| Qwen3.8 27B, MTP×4 ("agents") | 32.0 tok/s (code 36.8) | 16.4 s / 1.9 s | 95 % · 88 % · 98 % | ~40–63 GiB |

- **Flash-Next is the fastest in every measurement** (generation ~1.7–1.9×, prompt reading at 30k ~1.3×, a cached
  prompt ~9× faster) because only 10 of its 512 experts run per token, **and at least as good on every quality
  test** (better on tool calls, especially parallel ones: 19 vs 16 of 20). It needs nearly all of the memory
  (anything else that uses the GPU must pause) and a start takes ~5 minutes.
- **For the 27B, speculative decoding is the lever**: 12 → 32–38 tokens/s. DFlash is fastest on output but this vLLM
  build reads every prompt again in full; MTP keeps the prompt cache, which wins for agents and long conversations.
- **Generation is limited by memory bandwidth** (~300 GB/s, shared by CPU and GPU): more CPU cores, the GPU
  battery-cap fix or the Performance profile change it very little.

## What works and what does not (yet)

| Configuration | Status | Generation | Quality (code · tools · math) |
|---|---|---|---|
| 27B without speculation (base) | works | 12.1 tok/s | not measured separately; speculation does not change it (see Quality) |
| 27B MTP×4 ("agents") | works, alongside other GPU users | 32.0 tok/s (2.6× base) | 95 % · 88 % · 98 % |
| 27B MTP×3 / ×5 | works | 29.6 (10-22) / 33.1 tok/s | – |
| 27B DFlash2×7 / ×10 ("fast") / ×12 | works | 38.5 / 35.1 / 34.8 tok/s (code up to 64.6, 5.3× base) | ×12: 95 % · 88 % · 96 % |
| 27B with 35–40 % memory share | works, same speed, less context room | 32–33 tok/s | – |
| **Flash-Next MTP×3 (default) / ×4, 262k, one conversation** | **works, reliably** (share 0.76, `expandable_segments` allocator, file cache dropped while loading, 3 kernel compilers, everything else paused; ~10 min start, ~19 GiB free afterwards) | **59.9 tok/s** (re-check 10-24: code 65.8, prose 46.8) | **97.5 % · 93 % · 98 %** |
| Flash-Next, a 123k-token prompt | works: a fact hidden in the middle found, prompt read in 60 s | – | – |
| Flash-Next MTP×2 / ×3 / ×5 / ×6 | works since the fixes below (first start of each autotunes, ~5–6 min) | median 58.0 / 60.2 / 57.6 / 55.0 tok/s | Spark questions 25–26/26 on all |
| Flash-Next without speculation | not measured (same autotuning issue) | – | – |
| Flash-Next 1M context (YaRN ×4) | **not yet**: this nightly build's config check rejects YaRN on the multimodal config (`'Qwen4ExpConfig' object has no attribute 'max_position_embeddings'`); vLLM's rotary code itself supports YaRN with mRoPE | – | – |
| Thinking (`reasoning_effort` xhigh / medium / low) | not measured yet | – | – |

## Setup

| | |
|---|---|
| Laptop | ASUS ProArt P16 H7607BA, NVIDIA RTX Spark N1X, 20 Arm cores (10× Cortex-X925, 10× Cortex-A725) |
| Memory | 128 GB LPDDR5X shared by CPU and GPU; 113.9 GiB usable by Linux (2.1 GiB crash kernel + ~11.7 GiB firmware reserved) |
| System | Ubuntu 26.04.1, kernel 7.0.0-1023-nvidia, NVIDIA driver 615.71.09, on AC power |
| Power | the GPU battery-cap fix of this repo (`NVreg_RMSkipACPIBattCap=1`) active; profile Balanced or Performance as noted |
| Server | vLLM in Docker: `ghcr.io/timothystewart6/vllm-gb10:v0.30.0-gb10.3` (27B), `eugr/spark-vllm-b12x:nightly-20261015` (Flash-Next) |
| 27B model | NVIDIA's Qwen3.8-27B NVFP4 checkpoint (ModelOpt: MLP + lm_head NVFP4, attention FP8; 21 GB) |
| DFlash drafter | Qwen3.8-27B-DFlash2 (3.6 GB) |
| Flash-Next | NVIDIA's Qwen3.8-Flash-Next-FP4-Local (MoE: 48 layers, 512 experts, 10 active; 96 GiB on disk, ~72 GB in memory) |

**Method.** Generation ("decode"): three prompts (code, prose, structured output) × 512 tokens, temperature 0;
the median is the middle one of the three. Prompt reading ("prefill"): unique prompts of 1.8k / 7.5k / 30k tokens,
then the same prompt again (prefix cache). Quality: 40 HumanEval tasks (the generated code runs against the tests
in a container without network), 60 BFCL v3 function-calling tasks (20 simple, 20 multiple, 20 parallel; function
name and every argument must be right), 50 GSM8K math problems; temperature 0, thinking off. Tasks are spread
evenly over each test set. "Spark questions": 26 everyday assistant requests (answer and tool choice).

## Generation speed (tokens/s, one request)

| Variant | 2026-10-22 (before the GPU fix) | 2026-10-23 Balanced | 2026-10-23 Performance | code / prose / structured (newest) |
|---|---|---|---|---|
| 27B, no speculation | 12.3 | 12.1 | – | 12.1 / 12.2 / 10.6 |
| 27B, MTP×3 | 29.6 | – | – | – |
| 27B, MTP×4 | 31.5 | 32.4 | 32.0 | 36.8 / 25.0 / 32.0 |
| 27B, MTP×5 | – | 33.1 | – | 39.9 / 22.8 / 33.1 |
| 27B, DFlash2×7 | 38.0 | 36.2 | **38.5** | 52.7 / 27.7 / 38.5 |
| 27B, DFlash2×10 | – | – | 35.1 | **64.3** / 27.0 / 35.1 |
| 27B, DFlash2×12 | – | – | 34.8 | 64.6 / 24.1 / 34.8 |
| **Flash-Next, MTP×4** | – | – | **59.9** | **64.5 / 46.0 / 59.9** |
| Flash-Next, MTP×2 (10-24) | – | – | 58.0 | 60.8 / **48.1** / 58.0 |
| **Flash-Next, MTP×3 (10-24, default)** | – | – | **60.2** | **65.5** / 45.7 / **60.2** |
| Flash-Next, MTP×5 (10-24) | – | – | 57.6 | 64.2 / 41.1 / 57.6 |
| Flash-Next, MTP×6 (10-24) | – | – | 55.0 | 61.9 / 35.9 / 55.0 |

- **Every token reads the weights once**: ~19–21 GB at ~300 GB/s puts the 27B near 15 tokens/s without speculation
  (12.1 measured, ~80 % of it). The GPU draws only ~20 W while generating. CPU cores would read the same memory, so
  splitting a model between CPU and GPU brings nothing on this chip.
- **Speculative decoding** gives 2.6–3× with MTP and up to 5.3× on code with DFlash. More DFlash draft tokens help
  code (×10: 64 tokens/s) and hurt plain text (prose ×12: 24.1 vs 27.7 at ×7).
- **Flash-Next** (MoE) reads only its active experts per token, a fraction of its size: nearly 2× the 27B on prose.
- **Flash-Next's MTP draft count**: more drafted tokens help code a little up to ×3–×4 and hurt prose (the drafts
  are rejected more often: 48.1 at ×2, 35.9 at ×6). Four runs each of ×3 and ×4 with the desktop in normal use:
  ×3 62.6 / 45.0 / 56.5, ×4 61.1 / 41.9 / 57.8 (code / prose / structured), so ×3 is the default. Single runs
  scatter by ±5 % while other programs are busy: the decode loop is one CPU thread.

## Reading prompts (prefill) and the prompt cache

| Variant (Performance) | 1.8k tokens | 7.5k tokens | 30k tokens | same 30k prompt again |
|---|---|---|---|---|
| 27B MTP×4 | 0.81 s (2,296 tok/s) | 3.24 s (2,334 tok/s) | 16.4 s (1,836 tok/s) | 1.9 s |
| 27B DFlash2×7 | 0.93 s (2,000 tok/s) | 3.24 s (2,329 tok/s) | 15.9 s (1,892 tok/s) | 15.9 s |
| 27B DFlash2×10 | 0.88 s (2,106 tok/s) | 3.25 s (2,325 tok/s) | 15.7 s (1,919 tok/s) | 5.8 s |
| **Flash-Next** | 0.94 s (1,988 tok/s) | 3.24 s (2,331 tok/s) | **12.6 s (2,394 tok/s)** | **0.21 s** |

DFlash in this vLLM build gets (almost) no prefix-cache hits: a long conversation or an agent that sends the same
large context again pays the full prompt reading every turn. Prompt reading is the power-limited phase (the driver
reports "SW Power Cap" at ~50 W in Balanced).

**Two presets for the 27B follow from this:**

- **Fast — DFlash2×10**: chat, one-off code, short prompts. E.g. a 2k prompt + 500 tokens: ~9 s (MTP×4: ~14 s).
- **Agents — MTP×4**: agent loops, long conversations, big repositories. E.g. one agent step with 30k context +
  300 tokens: ~10 s (DFlash2×10: ~21 s, because the context is read again in full).

## Memory, context and the 1M question

| Setup | memory share | context room (KV cache) | decode |
|---|---|---|---|
| 27B MTP×4, default | 0.55 (62.6 GiB) | 824k tokens (262k × 3.1) | 32.0 |
| 27B MTP×4, mid | 0.40 (45.6 GiB) | 320k tokens (131k × 2.4) | 33.3 |
| 27B MTP×4, small | 0.35 (39.9 GiB) | 151k tokens (65k × 2.3) | 32.2 |
| Flash-Next, first working start | 0.80 (91 GiB) | **1,054,607 tokens** (262k × 4.0) | 59.9 |
| Flash-Next, now (`expandable_segments`) | 0.76 (86.6 GiB) | 390,444 tokens (262k × 1.5; 7.34 GiB) | 59.9 |

- The 27B itself (weights, MTP head, working memory) needs ~35 GiB; 0.30 (34.2 GiB) does not start. A smaller share
  costs no speed, only context room. Its limit is the model's 262,144 tokens, not memory.
- **Context per token is small on both** because only every fourth layer has full attention (the others are linear
  attention): 27B ~32 KiB, Flash-Next ~12 KiB per token in FP8. Flash-Next's full 262k context needs ~3 GiB.
- **Flash-Next goes to 1M tokens**: 262k native, "extensible up to 1,000,000" with YaRN rope scaling (factor 4); its
  n-gram embedding table stays on disk (`VLLM_PLE_TABLE_MEMORY=disk`). The context room is there (1.05M tokens at
  share 0.80, ~12 GiB for 1M), but the YaRN config does not get past this nightly build's config check yet (see the
  status table). 262k (native) works; a fact hidden in a 123k-token prompt was found, reading took 60 s.
- **Why Flash-Next first failed (`NV_ERR_NO_MEMORY`)**: CPU and GPU share one memory, and the NVIDIA driver takes
  GPU memory straight from RAM. While loading, Linux keeps the 72 GB of model files it just read in its file cache;
  the driver does not wait for Linux to drop it and fails. NVIDIA's DGX Spark recipe (262k × 4 sequences, share
  ~0.9) therefore did not start on the laptop. Fixes: share 0.80 and dropping the model files from the file cache
  while it loads (`posix_fadvise(POSIX_FADV_DONTNEED)`, no root needed). That start was lucky, though: see the
  repacking peak below.
- **Autotuning on a first start**: the b12x kernels are generated for the exact shapes the model uses (prompt chunk
  sizes, 1 + MTP draft tokens per step, …); for each shape up to 256 variants (tile sizes, threads, pipeline
  stages) are compiled on the CPU and timed on the GPU, and the fastest is cached on disk. The compilers run as
  separate processes of ~1.5 GB each, outside vLLM's share: with 8 of them (default) a first start peaked at
  ~110–120 GB of 122 GB and the driver failed. `B12X_COMPILE_WORKERS=3` keeps it to ~4.5 GB. A different MTP count
  means new shapes and a new autotuning run; the cached MTP×4 configuration starts without it.
- **Why the desktop lags near the limit**: the model's ~92 GB are GPU memory that Linux can neither move nor swap
  out, so desktop, browser, Docker and the file cache share the remaining ~20 GB. When that gets tight, Linux drops
  the cached code of running programs and swaps parts of them out; switching windows then waits for the SSD. The
  kernel's pressure figure showed all processes stalled on memory ~10 % of the time. A watchdog (stop the start below
  3 GB free RAM) prevents the last step, the out-of-memory killer.

## Starting Flash-Next reliably on the laptop

Each step fixed one failure seen on the way:

| Step | Why |
|---|---|
| Pause everything else that holds GPU memory (here: a voice assistant with three models), and refuse to start it again while the model runs | Flash-Next needs ~87 GiB of the 113.9 GiB |
| **GPU access via CDI**: `--device nvidia.com/gpu=all` instead of `--gpus all` | with `--gpus all` the NVIDIA hook adds the GPU devices behind Docker's back: the container's systemd unit lists none of them, and every systemd reload (a snap refresh, the daily apt upgrade) or `docker update` takes the GPU away from running containers (`NVMLError_Unknown`, CUDA `operation not permitted`). With CDI (the spec is generated at boot by `nvidia-cdi-refresh`) the devices are part of the unit. Never `docker update` a running GPU container |
| **Pin the container to the fast CPU cores** (`--cpuset-cpus`, here the 10 Cortex-X925; the 10 A725 run at 2.8 GHz) | reading the weights is one Python thread that routes 375,487 tensors (368,640 expert pieces), and Linux kept moving it to the slow cores: 33 s per 5 GB shard, pinned 10–15 s. Weights 445 → 146 s, engine setup 133 → 52 s |
| `--gpu-memory-utilization 0.76 --max-model-len 262144 --max-num-seqs 1` | at 0.88–0.91 (and 262k × 4 sequences) the driver ran out (`NV_ERR_NO_MEMORY`); 0.76 leaves room for 390k tokens (one full 262k conversation) and ~19 GiB of RAM for the desktop |
| **`PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True`** | **the main one**: right after the weights are read, vLLM repacks the MoE expert weights into the b12x kernel layout. With PyTorch's default allocator the freed pieces pile up: +21 GiB at once, then +0.15 GiB/s, past 100 GiB, and the start failed even from a clean memory state. With expandable segments, freed GPU memory is reused: the same phase peaks at ~83 GiB, same speed afterwards |
| Drop the model files from the file cache while it loads (`posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED)` every few seconds, no root needed) | otherwise ~72 GB of just-read files sit in the cache, and the driver does not wait for Linux to free them |
| `B12X_COMPILE_WORKERS=3` | a first start autotunes kernels with 8 compiler processes of ~1.5 GB each, outside vLLM's share |
| **Drop the kernel's reclaimable caches before loading** (`echo 3 > /proc/sys/vm/drop_caches`) | the NVIDIA driver keeps the GPU memory of a stopped model in its system memory pool (`NVreg_EnableSystemMemoryPools`, on by default) and reports it as reclaimable. Linux counts it as available, but the driver does not hand it back fast enough when the next model loads |
| Empty the swap before loading, if RAM has room for its content | after earlier tight loads the swap stays full of parked desktop pages; the next loading peak then has no buffer left |
| A RAM watchdog while it loads: stop the container below 3 GB free | the last line of defence before the out-of-memory killer would hit the desktop |
| A memory log while it loads (every 5 s: available, free, `KReclaimable`, swap, the container's cgroup memory, last log line) | how the repacking peak above was found |
| **Unloading frees it too**: run the same script after stopping a model (or the voice assistant) | otherwise the driver pool keeps the stopped model's memory (71 GB of Flash-Next, 15 GB of the assistant); the assistant's small model then failed to start (`No available memory for the cache blocks`) and the desktop showed ~30 GB used with everything off |

**The driver pool explained why every further start went worse** while the first one after a boot worked: after a
few stopped attempts `/proc/meminfo` showed `KReclaimable: 81 GB` (with `SReclaimable`, the normal kernel caches,
at 0.3 GB) and `MemFree: 10.8 GB`, while `MemAvailable` still said 101 GB. One `drop_caches` brought `MemFree` back
to 113.6 GB and `KReclaimable` to 0.6 GB: as clean as right after a boot. It only drops clean pages; nothing is lost.

Both steps need root. A narrow way: a root-owned script that does only this, and a sudo rule for exactly that file
(`youruser` = your login).

```sh
#!/bin/sh
# /usr/local/sbin/llm-swap-reset: memory as clean as after a boot, before a big model loads
sync
echo 3 > /proc/sys/vm/drop_caches                      # file cache + the NVIDIA driver's memory pool
used=$(awk '/^SwapTotal/ {t = $2} /^SwapFree/ {f = $2} END {print t - f}' /proc/meminfo)
avail=$(awk '/^MemAvailable/ {print $2}' /proc/meminfo)
[ "$used" -lt 524288 ] && exit 0                       # under 0.5 GB of swap in use: done
[ "$avail" -gt $((used + 4194304)) ] || exit 1         # room for the swap content + 4 GB needed
swapoff -a && swapon -a
```

```
# /etc/sudoers.d/llm-swap-reset (root, 0440; check with visudo -cf before installing)
youruser ALL=(root) NOPASSWD: /usr/local/sbin/llm-swap-reset
```

The start script runs `sudo -n /usr/local/sbin/llm-swap-reset` before `docker run`, and again after stopping a
model (also when a start fails) and after switching the voice assistant off. `swapoff -a` moves the parked
pages back into RAM (no program is closed, nothing is lost), `swapon -a` turns the swap on again, empty: the swap is
never left off.

With all of this, the cached MTP×3/×4 configuration starts in ~5 minutes (before the CPU pinning ~10): 2.5 min
reading the weights, ~40 s repacking, ~1 min kernels, profiling and CUDA graphs.
The memory log of two starts (GiB; voice assistant off, desktop with four displays):

| Phase | available RAM | model container (cgroup) |
|---|---|---|
| before loading | 105 | – |
| weights being read (their GPU memory is reserved in the first minute) | 34 → 29 | 70 → 73 |
| repacking, default allocator (failed) | 25 → 2.6, 8 GiB swap full | 78 → 101.5, still rising |
| repacking, `expandable_segments` | 31 → 24, swap unused | 73 → 83 |
| ready (KV cache allocated) | 18.5 | 86 |

A first start of a different configuration (another MTP count, no speculation) autotunes again and needs more
memory meanwhile; best with large programs closed.

## Quality (temperature 0, thinking off)

| Model | HumanEval (40) | BFCL tools (60): simple / multiple / parallel | GSM8K (50) | Spark questions (26) | time for all 150 |
|---|---|---|---|---|---|
| 27B MTP×4 | 38 (95 %) | 53 (88 %): 18 / 19 / 16 | 49 (98 %) | 24–25 | 11.4 min |
| 27B DFlash2×12 | 38 (95 %) | 53 (88 %): 18 / 19 / 16 | 48 (96 %) | 25 | **6.4 min** |
| Flash-Next | **39 (97.5 %)** | **56 (93 %): 18 / 19 / 19** | 49 (98 %) | **26** | 7.1 min |

Speculative decoding keeps the quality: between MTP×4 and DFlash2×12 the verdicts agree on 40/40 code tasks, 58/60
tool calls and 49/50 math problems. The wording is not byte-identical (only 3/50 math answers match character for
character): different batch shapes during verification give tiny floating-point differences that flip near-ties
in greedy decoding.

**Thinking**: both models think by default, with `reasoning_effort` `xhigh` (default), `medium` or `low` in the chat
template. All numbers here are without thinking (as assistants and quick coding use them); with thinking, quality
on hard tasks rises and every answer takes far longer.

## On battery

On battery the platform still limits the GPU to ~20 W (~1.0 GHz): prompt reading drops to ~800–930 tokens/s,
generation stays at ~33 tokens/s with the 27B MTP×4 (bandwidth-bound). See [technical-notes.md](technical-notes.md).
