# Parakeet runtime experiments

These workers are development tools. They are not app dependencies or release
assets. Keep the production model registry and the compatibility frontend until
the candidate passes the English and Swedish acceptance checks.

`model-manifests.json` pins the experimental ONNX and GGUF files. Download each
file from `https://huggingface.co/REPO/resolve/REVISION/FILE` (the ONNX files are
under `parakeet-tdt-0.6b-v3/`). Verify the listed byte sizes and SHA-256 values.
Keep downloads and external build directories under ignored `target/`.

## Application worker

```sh
cargo build --locked --release --features webgpu --example model_bench
python3 scripts/benchmark.py --model /path/to/production/model --backend webgpu \
  --threads 4 --profile --subset --fixtures target/fixtures/thread-screen.json \
  --cold-runs 0 --warm-runs 3 --output target/performance/profile
```

`--decoder-threads` can vary the decoder session independently. The normal app
continues to use the saved CPU thread count for both sessions. Profiling measures
the frontend, encoder (including host/device transfers), decoder, timestamps,
and model-lock wait. It does not measure capture, queue wait before the provider,
display latency, or LLM work. Use unprofiled workers for acceptance timing.

When copying a WebGPU-enabled executable, put the verified
`target/release/libwebgpu_dawn.dylib` beside it as well. Its loader path is
relative to the executable. Record the library with `--runtime-file`.
Each output prefix also gets an `.observations.jsonl` journal. Completed
observations survive a later worker failure; use a new prefix for each attempt.

`preview_contention_bench` is a separate synthetic worker. Build it with the
same feature flags, then pass a model directory and `cpu` or `webgpu`. Supply
fixture WAV paths on stdin. It compares a final request alone with one arriving
after a 30-second repeated-audio preview request, ten trials per fixture. Its
10 ms head start is a test condition; the recorded provider-lock wait shows
whether contention occurred. It does not run the app's capture, scheduler, UI,
or LLM pipeline and must not be reported as live capture latency.

## Burn/Metal worker

```sh
cargo build --locked --release --manifest-path benchmarks/parakeet-metal/Cargo.toml
python3 scripts/benchmark.py --backend burnmetal --model /path/to/candidate/onnx \
  --model-manifest /path/to/single-candidate-manifest.json \
  --binary benchmarks/parakeet-metal/target/release/parakatt-metal-bench \
  --runtime-lock benchmarks/parakeet-metal/Cargo.lock \
  --subset --fixtures target/fixtures/thread-screen.json --cold-runs 0 \
  --warm-runs 3 --output target/performance/burn-screen
```

The worker uses upstream feature extraction and the new upstream FP32 export.
That pair must be compared with the production pair; identical model names do
not prove equal transcripts. The first inference can compile and tune kernels.

## NVIDIA native worker

Check out the three exact source commits in `native-sources.json`. Initialize
the runtime's `llama.cpp` submodule and verify its commit. Build SentencePiece's
`sentencepiece-static` target with `SPM_BUILD_TEST=OFF`, `SPM_ENABLE_SHARED=OFF`,
and `SPM_ENABLE_TCMALLOC=OFF`. Put its archive and public processor header in
`DEPENDENCY_PREFIX/sentencepiece/{lib,include}`. No global installation is needed.

Configure the NVIDIA source with CMake Release and these options:

```text
GGML_METAL=ON
GGML_CCACHE=OFF
NEMO_SPEECH_GGML_PATCHED=OFF
NEMO_SPEECH_BUILD_ASR=ON
NEMO_SPEECH_BUILD_DIAR=OFF
NEMO_SPEECH_BUILD_TTS=OFF
NEMO_SPEECH_BUILD_NMT=OFF
NEMO_SPEECH_BUILD_CLI=OFF
NEMO_SPEECH_BUILD_MIC_CAPTURE=OFF
NEMO_SPEECH_DEPENDENCY_PREFIX=/absolute/path/to/DEPENDENCY_PREFIX
```

Build the shared ASR library. Compile `nemo-metal/worker.cpp` with C++17, the
runtime's `include` and `examples` directories, and `llama.cpp/vendor` on the
include path. Link `nemo_speech_asr_c` and set an rpath to the build's `bin`.
Use that executable with `scripts/benchmark.py --backend nemometal`, the verified
GGUF directory, its single model manifest, and `--runtime-lock
benchmarks/native-sources.json`. Pass the native ASR and ggml libraries with
`--runtime-file` to retain their hashes. This C ABI uses its default CPU thread
policy, `min(8, hardware threads)`; the worker rejects a nonzero `--threads`.
GPU initialization failure is fatal in the pinned runtime.

## Acceptance

Stop task builds and other task benchmarks before timing. Record other host
workloads. A subset or fewer than three cold starts and ten full warm passes is
a screening run. Preserve failures and first-run compilation costs. Never use
screening results to promote a production backend.

```sh
python3 scripts/compare-benchmarks.py target/performance/cpu.json \
  target/performance/webgpu.json --acceleration --output target/performance/gates.json
```

Both reports must use schema 2, the same hardware, exact OS build, dataset,
fixture/reference manifest, and verified model manifest. Native experiments
with another export require both `--expected-backend burnmetal` (or
`nemometal`) and `--allow-model-change`. Those flags identify a comparison; they
do not enable the backend in the app. The gate recomputes summary statistics,
requires complete samples, and rejects fallback. Check subtitles, edge audio,
packaged startup, and real capture-to-display latency separately. Power is
unmeasured unless a separate energy trace is retained.

For each required language, acceleration acceptance requires no higher word
error rate, at least 10% lower median inference time, and no higher p95 time.
Historical schema-1 reports remain evidence of their original runs; collect a
fresh schema-2 baseline before using the current acceptance command.
