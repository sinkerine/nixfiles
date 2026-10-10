# Current Qwen3.8 Flash-Next IQ2_XS performance diagnosis

Measured 2026-10-09 UTC on kazuki, Strata 0.1.39, RTX 5070 Ti 16 GB,
Ryzen 9 9950X, 60 GiB usable RAM. Model:
`Qwen3.8-Flash-Next-abliterated-GSQ-RCO-IQ2_XS`.
The service retains vision, refusal projection, 131072 context, int8 KV,
32768 resident KV cells and MTP speculation.

The main bottleneck was file-backed expert access under RAM pressure.
The service had `--mmap-experts` without a resident RAM budget. The GPU
held about 3.8 GiB of experts; misses used the mapped GGUFs. The logged
file MB counts include accesses served from the OS cache, so physical disk
reads were measured separately using the service cgroup's `io.stat`.

Identical 77-token prompt, temperature zero, 256 output tokens including
reasoning. Both requests began with the API idle and no queued requests.
These are single-request measurements with desktop applications running,
not a controlled hardware comparison with upstream. Native CPU/GPU rounding
and expert placement can change generated tokens across configurations.

| Setting | Decode tokens/s | Prompt tokens/s | Request seconds | Physical disk reads | Major page faults |
| --- | ---: | ---: | ---: | ---: | ---: |
| Mapped experts, no resident budget | 12.6 | 20.0 | 24.22 | 13.98 GiB | 3,228,979 |
| Resident budget, 11.20 GiB pinned | 25.8 | 22.0 | 13.44 | 7.38 GiB | 2,037,432 |

Fix deployed in `hosts/kazuki/default.nix`: restore
`--resident-budget-gib 30`. Strata automatically capped this to 11.20 GiB
at startup: 15.45 GiB available minus 4 GiB headroom and a 0.25 GiB margin.
The limit is a ceiling, not a mandatory 30 GiB allocation. It may differ on
future starts as available RAM changes. PCIe expert offload increased from
zero to 10.9% of routed experts. The hardware link itself measured 57.9 GB/s,
PCIe 5 x16, so link bandwidth was not the primary problem.

About 29.16 GiB of experts were outside the GPU cache. After pinning
11.20 GiB, roughly 18 GiB remain file-backed. The ZFS ARC was about 12 GiB
before the change; the VM, browsers and other applications also consume RAM.
Mapped file pages and the filesystem cache consume memory alongside those
applications. No applications were stopped and no global ZFS settings changed.
To approach the upstream resident benchmark, enough RAM must be available
for the remaining experts plus service/OS headroom, or GPU expert capacity
must increase. Merely raising the configured RAM budget cannot create room.

[Upstream 0.1.39 documentation](https://github.com/Niko1221/Strata/blob/v0.1.39/docs/DETAILS.md#speed-measured)
reports IQ2_XS at 79.6 TPS with a 1K prompt, 78.6 at 4K, and 62.7 at 128K
(engine 0.1.26, RTX 5070 12 GB, Ryzen 7600, 64 GB RAM, Windows).
It explicitly warns that mmap mode on a small GPU is much slower when the
OS cannot retain experts in memory. Different prompts, model variants,
context settings, background workloads and platforms prevent exact parity
claims. The model publisher separately reports 84.2 TPS at 4K using an
RTX 3090 and 125 GB RAM.

Raw responses, counter deltas and the diagnostic script are saved locally:
`~/.cache/Strata-data/benchmarks/tps-debug-2026-10-09/`.
The script uses the local API, reads the service cgroup counters, and records
both engine and HTTP timing. The older benchmark below requires llama.cpp
`/apply-template` and `/tokenize`; it cannot run unchanged on native Strata.

---

# Previous 128K Qwen3.5-9B configuration

Updated 2026-10-08. `strata.service` is active and enabled at boot, serving
Huihui Qwen3.5-9B-abliterated Q5_K_M through CUDA llama.cpp 0.5.0.
The model has native 262,144-token support; the service allocates 131,072 tokens
for combined input and output. No context extrapolation is needed.

Endpoint: `https://kazuki.m.mado.moe/v1`.
Model ID: `huihui-qwen3.5-9b-abliterated-q5_k_m`.
Live `strata-low`, `strata-medium` and `strata-high` Codex profiles and their Nix
definitions now advertise 131,072 tokens and the new model ID.

All weights and KV remain on GPU, with Flash Attention and Q8_0 K/V. Other
settings match the previous configuration below. Total VRAM usage is about
11.7 GiB including desktop applications, leaving about 4 GiB free.

| Prompt tokens | Generated tokens | Decode tokens/sec | Prefill tokens/sec | Full HTTP tokens/sec | Retrieved both codes |
| ---: | ---: | ---: | ---: | ---: | --- |
| 45 | 512 | 114.8 | 1427 | 113.7 | N/A |
| 39 | 512 | 114.7 | 1294 | 113.6 | N/A |
| 41 | 512 | 114.5 | 1362 | 113.5 | N/A |
| 4096 | 512 | 112.7 | 5140 | 95.6 | Yes |
| 27996 | 512 | 101.5 | 4662 | 46.1 | Yes |
| 129996 | 512 | 71.7 | 2912 | 9.8 | Yes |

The 129,996-token input plus 512-token output was accepted without truncation.
The response recovered both six-digit checkpoint codes, one near the beginning
and one near the middle of the input. The reference text between them repeats,
so this is a basic context and retrieval check rather than a broad quality test.
Generation at this context reached 71.7 tokens/sec. Initial ingestion took about
44.6 seconds; the full request took about 52 seconds, or 9.8 output tokens/sec
including ingestion. Decode timing is the quantity comparable to official
Strata output benchmarks. Official 125B IQ3_S at 128K was 45.5 tokens/sec;
different model sizes and engines make this a practical speed comparison.

Reproduce:

```sh
python3 hosts/kazuki/strata-benchmark.py --long-context \
  --output /home/sinkerine/Strata-data/qwen35-9b-128k-benchmark.json
```

Model provenance:

- Repository: `mradermacher/Huihui-Qwen3.5-9B-abliterated-GGUF`
- Revision: `9f646d7eda193ddf2348134f3bff3d49eed7a2c6`
- Filename: `Huihui-Qwen3.5-9B-abliterated.Q5_K_M.gguf`
- Size: 6,522,004,864 bytes
- Verified SHA256: `946072b16f5d672e60357410f900888f6522b3ae49f241b5bf2142cb89637fb6`

---
# Previous 32K Qwen3-8B configuration

Measured 2026-10-08. `strata.service` previously served
`bartowski/mlabonne_Qwen3-8B-abliterated-GGUF`, Q6_K, through CUDA llama.cpp
0.5.0 (build 11146, commit 7fe450e). The Strata inference engine supports
Qwen3.8-Flash-Next, not this smaller Qwen3 architecture; the service name and
HTTPS endpoint are retained for clients.

Endpoint: `https://kazuki.m.mado.moe/v1`.
Model ID: `qwen3-8b-abliterated-q6_k`.
OpenAI Chat Completions, Responses, and function calls were checked successfully.
Requests using the previous RVN model ID also return the new model, which the
response identifies correctly. Updated Nix Codex profiles use the new ID.

## Current measurements

RTX 5070 Ti 16 GB, Ryzen 9 9950X, 60 GiB usable RAM, NixOS. Other desktop
applications remained running. Total GPU memory usage was about 11.7 GiB,
including about 3 GiB from other applications. PCIe negotiated Gen 5 x16.

All model layers are offloaded to CUDA. Configuration: 32,768 context tokens,
one slot, Flash Attention, Q8_0 K/V cache, batch 2048, microbatch 512, eight
decode CPU threads and sixteen prefill CPU threads. Thinking is disabled by
default. Each measured request produced 512 tokens at temperature zero after
a small warmup; prompt caching was disabled. Long prompts use repeated reference
text, so these measurements are throughput checks, not quality evaluations.

| Prompt | Decode tokens/sec | Prefill tokens/sec | Tokens/sec including full HTTP request |
| --- | ---: | ---: | ---: |
| Short Linux explanation, 45 tokens | 107.9 | 2658 | 107.6 |
| Short Python task, 39 tokens | 107.4 | 2350 | 107.1 |
| Short solar power explanation, 41 tokens | 107.9 | 2283 | 107.6 |
| 4096 tokens | 97.4 | 5218 | 84.7 |
| 28,000 tokens | 65.5 | 3729 | 33.4 |

Decode exceeds 50 tokens/sec in every measured case. The full request rate at
28K includes about 7.5 seconds spent reading the prompt and does not exceed 50.
No guarantee is made for every prompt length, concurrent workload, or GPU load.
The smaller 8B model sacrifices capability relative to 125B Flash-Next; Q6_K
preserves more weight precision than typical Q4 quantization. Abliteration is
the model publisher's designation, not a guarantee of behavior for every prompt.

Reproduce:

```sh
python3 hosts/kazuki/strata-benchmark.py \
  --output /home/sinkerine/Strata-data/qwen3-8b-q6_k-benchmark.json
```

## Comparison with official Strata results

Source: [Strata measured speed](https://github.com/Niko1221/Strata/blob/main/docs/DETAILS.md#speed-measured),
read 2026-10-08. Official IQ3_S tests used RTX 5070 12 GB, Ryzen 5 7600,
64 GB DDR5-5200, Windows, Strata 0.1.26, one code-agent prompt per length,
256 generated tokens, MTP speculation, automatic prefill and context-dependent
KV settings.

| Official Flash-Next IQ3_S prompt length | Decode tokens/sec |
| --- | ---: |
| 1K | 52.4 |
| 4K | 53.3 |
| 32K | 48.3 |
| 128K | 45.5 |

The previous local RVN uncensored IQ3_S setup's October 4 logs reported
10.8–15.1 tokens/sec for 256-token generations from a short 74-token prompt.
That is approximately 3.5–4.9 times slower than the official 4K result, although
the prompts, model weights, quantization mix, operating systems and engine
versions differ. These are historical logs, not a fresh controlled A/B test.

The clearest gap is memory residency:

- The local RVN pack contains 53.32 GiB of expert weights, with IQ3_S gate/up
  matrices and IQ4_NL down matrices. Official IQ3_S uses a different quantization
  mix and expert footprint.
- The local configuration set a 30 GiB resident budget. Logs show only 26.61 GiB
  of resident experts and 2484 GPU expert slots, leaving a substantial fraction
  of experts on disk. After repeated requests the logs still show file reads,
  including about 305,946 MB cumulative reads, and cache hit rates around 51–72%.
- Official fast configurations keep experts resident in RAM. Upstream explicitly
  warns that mapped experts on a small GPU become much slower when the OS cannot
  keep the remaining weights in RAM. Available RAM before this change was only
  about 26 GiB because other applications were using the rest.
- The local service reserved 128K context and 32K resident KV cells, plus a
  1800 MiB VRAM reserve. Its short-prompt timing is therefore not equivalent to
  an official run configured for a shorter context.

The new 8B result at 4K is about 1.8 times the official 125B IQ3_S decode rate,
but this compares different model capacities and inference engines. It shows
the requested speed target is met, not that the Strata engine itself was made
1.8 times faster. No original model files were removed or requantized.

## Model provenance

- Repository: `bartowski/mlabonne_Qwen3-8B-abliterated-GGUF`
- Revision: `0e66e6f836c802246b69941780ec8ef32670dc09`
- Filename: `mlabonne_Qwen3-8B-abliterated-Q6_K.gguf`
- Size: 6,725,899,872 bytes
- SHA256: `1e1b047d8cf005dc57985727ce2cbd5d59c4e23cbda0cb8fca4448250add25c7`
- Downloaded file size and SHA256 match the publisher's LFS metadata.
