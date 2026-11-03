# Parakeet performance checks, 3 November 2026

The existing FP32 Parakeet v3 path passes WebGPU acceptance on Apple M3 Max,
macOS 27.0.1, build `26A434`, with four CPU threads and ORT API 28. The previous
validation record covered build `26A428`, so this OS update selected CPU.
The new record enables automatic WebGPU on the tested combination. Explicit CPU
selection and fallback remain available. Other hardware, OS builds, models, and
thread counts still require their own validation.

## Accepted CPU/WebGPU comparison

Both runs used the same saved worker, verified production model revision
`8f23f0c03c8761650bdb5b40aaf3e40d2c15f1ce`, and the same pinned FLEURS files
and references: 100 English and 100 Swedish utterances, three fresh-process
starts and ten warm passes. Inference excludes WAV loading, capture, UI, and
LLM processing. A fresh process does not clear the OS file or GPU shader cache.
WER is word error rate.

| Language | CPU median / p95 | WebGPU median / p95 | Median time reduction | WER, both backends |
|---|---:|---:|---:|---:|
| English | 463.7 / 805.3 ms | 99.2 / 147.3 ms | 78.60% | 5.0044% |
| Swedish | 490.7 / 879.0 ms | 107.5 / 157.4 ms | 78.10% | 13.2429% |

The [acceptance gate](webgpu-gates.json) passed. All 2,003 CPU/GPU observations
matched exactly in text and sentence timestamps. CPU output was identical
across the ten warm passes. All observations reported their requested backend;
no CPU retry counted as GPU evidence. The [CPU](cpu-current.json) and
[WebGPU](webgpu-current.json) reports retain every observation.

Nine attributed edge fixtures also produced identical text and sentence
timestamps on CPU and WebGPU: silence, short speech, pauses, chunk boundaries,
alternating sources, and overlapping sources. Silence produced no text.
Mixed-source WER is diagnostic, not single-speaker accuracy acceptance. See
[CPU edges](cpu-edges.json) and [GPU edges](webgpu-edges.json).

## Application checks

The Release app was rebuilt from clean source commit `7810147`, using Rust
1.99.1 and Xcode 27.1. After the normal package launcher replacement, bundle
verification passed for version/build fields, the stable launcher identity,
11 Mach-O binaries and their deployment targets, media helpers, playback
engine, and notices. The [startup check](packaged-startup.json) loaded the
verified model through the packaged launcher and reported `webgpu` on
`26A434`. No microphone input was captured.

The rebuilt app also transcribed a 65-second video made by repeating an
attributed English fixture. It completed three chunks, retained ten segments,
and produced 1,023 bytes of SRT. The largest submitted audio block was
480,000 samples. This checks the packaged media/transcription/subtitle path;
it is not another accuracy benchmark. See [media results](packaged-media.json)
and [build, model, fixture, launcher, and framework provenance](packaged-provenance.json).

Rust formatting and all-target/all-feature Clippy passed. The Rust suite
passed 196 tests, with one opt-in real-model test and two documentation
examples skipped; the separate real-model acceptance above used all 200
fixtures. Swift ran 52 tests, with one existing opt-in test skipped and no
failures. The six benchmark gate tests, two worker protocol tests, and twelve
release-tool tests passed. CI runs the new benchmark tests.

## Measured costs and thread screens

Stage profiling used a 20-utterance subset, three passes, and the same
production frontend. These are diagnostic medians across 60 observations:

| Stage | CPU, four threads | WebGPU encoder, four CPU decoder threads |
|---|---:|---:|
| Feature extraction | 1.68 ms | 1.65 ms |
| Encoder, including input/output transfer | 418.71 ms | 70.38 ms |
| Decoder | 22.32 ms | 22.44 ms |
| Timestamp conversion | 0.016 ms | 0.014 ms |

The original CPU worker and profiled worker produced identical text for all
60 observations. Stage medians do not add up to the median total. The provider
lock had no contention in these isolated inference runs; this does not measure
the engine's outer lock or the app's scheduling queues.

One decoder thread increased GPU-path median time to 108.7/108.1 ms
(English/Swedish); two threads measured 101.0/99.8 ms, versus 94.3/94.0 ms
with four in that screen. Four remains the qualified configuration.
Eight CPU threads improved the CPU-only screen to 269.4/290.4 ms, but this
was only a subset screen and is still slower than qualified GPU inference.
It does not change automatic thread defaults. See the `profile-*` reports.

The newer upstream opset-23 FP32 export also ran under the current ORT worker
with the compatibility frontend. It matched the subset WER but measured
134.0/131.4 ms, slower than the current export. It was not promoted. See
[the export screen](opset23-webgpu.json).

## Synthetic preview contention

Two public speech fixtures each ran ten trials. The same provider handled a
final request alone, then a final request after a 30-second repeated-audio
preview request. The preview thread had a 10 ms head start. Actual provider
lock wait was recorded, and final text stayed unchanged.

| Backend | Median final request alone | Median final request with preview | Median provider-lock wait |
|---|---:|---:|---:|
| CPU | 441.5 ms | 1,819.3 ms | 1,379.6 ms |
| WebGPU | 96.0 ms | 307.9 ms | 207.5 ms |

These [CPU](cpu-contention.json) and [GPU](webgpu-contention.json) runs show the
cost of serial model use. They do not execute the app's capture, outer engine
lock, scheduling, UI, or LLM pipeline. They are not live capture-to-display or
stop-to-final latency measurements. No preview-priority behavior was changed.

## Native candidates: not promoted

Each candidate used verified, separately pinned model files. The full-corpus
screens below each used one warm pass, not full latency acceptance.

| Candidate | English / Swedish WER | English / Swedish median inference | Decision |
|---|---:|---:|---|
| Burn/Metal, parakeet-rs 0.4.4, upstream FP32 export/frontend | 5.0914% / 13.7108% | 98.4 / 101.7 ms | Misses accuracy requirement |
| NVIDIA NeMo-Speech.cpp, official Q8_0 GGUF | 5.0479% / 13.6172% | 82.3 / 86.2 ms | Misses accuracy requirement |

The production path made 115 English and 283 Swedish word errors per corpus
pass. Burn made 117/293; the NVIDIA candidate made 116/291. These small observed
differences are enough to prevent automatic promotion under the current rule.
They do not establish that either runtime is generally less accurate.
Burn changes the export and frontend together; the NVIDIA candidate also
changes precision. The experiment does not isolate those effects.

Cold behavior also matters. In the first small screen, Burn loaded in 0.65 s
but its first inference took 24.60 s. NVIDIA's
first model load took 16.62 s and its first inference 0.58 s. Subsequent process
loads were faster with existing caches. The one-pass Burn corpus p95 includes
first-use costs for additional input shapes, so it is not steady-state latency
acceptance. Neither native screen exceeded the diagnostic timestamp bounds
(nonnegative, ordered endpoints, with a 500 ms end-of-audio tolerance).

The [Burn](burn-corpus.json) and [NVIDIA](nemo-corpus.json) observations, initial
`*-screen.json` results, [model manifests](../../../benchmarks/model-manifests.json),
and [source pins](../../../benchmarks/native-sources.json) are retained. The
workers and their dependencies are isolated in `benchmarks/`; they are not
linked into or bundled with the app. Use [the benchmark instructions](../../../benchmarks/README.md)
to reproduce them.

## Limits and retained failures

The first hosted attempt and its retry at `5b4de50` failed before Swift tests
while Python 3.15.2 bootstrapped pip in a media-tool environment. The captured
logs show the failing command but do not establish its underlying cause. See
[both failures](hosted-build-failures.json). CI now selects Python 3.13 explicitly.
The build helper keys environments by interpreter identity/version and pinned
package versions, verifies installed tools before reuse, clears partial state,
and exposes bootstrap stderr. Four regression tests and a real fresh bootstrap
and verified reuse passed locally. The speech model/runtime pins and inference
code measured above were not changed by this build repair.

After that repair, the app was rebuilt from clean commit `1328617`. Bundle
verification and [automatic GPU startup](packaged-startup-followup.json) passed
again. [Media transcription](packaged-media-followup.json) ran with PATH limited
to macOS system directories and produced the same chunks, segments, text length,
and subtitle size. The corresponding-source set contains the new build helper.
[Follow-up provenance](packaged-followup-provenance.json) records the clean source,
launcher, frameworks, validation matrix, and helper hashes. The original
packaged evidence remains available above.

No task build ran during timed inference, and task benchmarks were sequential.
An existing Virtualization VM and user applications remained active. See
[measurement context](measurement-context.json). These are measurements of this
Mac and OS, not a hardware-family or fleet-wide qualification. Power and full
GPU/unified-memory residency were not measured; peak RSS is a process metric.
Real capture/display latency and installed-update permission persistence are
not established by these checks.

The first copied application workers could not find `libwebgpu_dawn.dylib`
beside their new location and failed before model readiness. The required
library was verified against its manifest and copied beside them, then the
screens were repeated. [Failure logs](setup-failures.json) and
[attempt status](screens.json) are retained. This was benchmark setup failure,
not application inference failure.

Corpus/edge/runtime measurements used committed harness source `f6c7283`.
Synthetic contention used `74f2cfc`; packaged checks used `7810147`. Saved
worker and runtime hashes identify the measured artifacts. Machine-specific
paths and JSON whitespace were changed only when curating the reports.
Audio, model weights, credentials, and private recordings are not committed.
The corpus and derived fixtures retain their existing
[FLEURS attribution](../../maintenance/fixtures.md).
