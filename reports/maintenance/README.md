# Maintenance validation record

The eight implementation changes are committed separately on `chore/maintainance_work`. This record describes the checks run on an Apple M3 Max with macOS 27.0, build `26A428`. It is not a general release qualification for all supported Macs.

## Results and default selection

The final model remains Parakeet TDT 0.6B v3, revision `8f23f0c03c8761650bdb5b40aaf3e40d2c15f1ce`. The table uses the pinned 100 English and 100 Swedish FLEURS utterances, three fresh-process cold runs, and ten warm passes. WER is word error rate; a lower value is better. Inference time excludes capture, model load, UI work, and LLM processing.

| Runtime and backend | English WER | Swedish WER | English median / p95 | Swedish median / p95 | Decision |
|---|---:|---:|---:|---:|---|
| Original parakeet-rs 0.3.4, CPU | 5.0044% | 13.2429% | 458 / 885 ms | 482 / 861 ms | Baseline |
| Unmodified 0.3.8, CPU | 5.0914% | 13.7108% | See JSON | See JSON | Rejected: accuracy regression |
| 0.3.8 with compatible v3 frontend, CPU | 5.0044% | 13.2429% | 468 / 851 ms | 505 / 886 ms | Accuracy passes; no speed improvement claimed |
| 0.3.8 with compatible v3 frontend, WebGPU encoder (final rerun) | 5.0044% | 13.2429% | 100 / 149 ms | 107 / 157 ms | Accuracy and acceleration gates pass on this hardware and OS |

The upstream 0.3.8 audio frontend changed the FFT window alignment and frame count. The small, opt-in [vendor patch](../../vendor/parakeet-rs/PARAKATT-PATCH.md) retains the prior frontend for final Parakeet v3 transcription. Nemotron uses the upstream frontend. Do not remove this patch without repeating both language accuracy gates.

The final WebGPU rerun measured a median improvement of 78.06% for English and 77.79% for Swedish against the original CPU baseline. Both p95 values improved. The decoder stays on CPU. Cold model load was 1.46–1.52 seconds; peak process RSS was about 2.75 GB. See [final gate results](webgpu-final-gates.json) and [the benchmark report](webgpu-final.md). This run used clean source commit `6b287adfb7357a6323652147846d55b330ba7f9c` after the other task workloads ended. The original matrix promotion remains recorded in `webgpu-gates.json` (78.85% / 78.90% improvement); the final rerun confirms the same combination. CPU cold load was about 1.08 seconds and peak RSS about 2.94 GB. Cold runs do not clear the OS file cache.

[The validation matrix](../../crates/parakatt-core/backend-validation.json) enables automatic WebGPU only for the tested model revision, Apple M3 Max, OS build `26A428`, four CPU threads, and ORT API 28. Unknown combinations use CPU. Explicit CPU settings remain CPU. Backend initialization or inference failure retries on CPU without publishing a duplicate result. Preview acceleration is unvalidated and remains unavailable.

The INT8 candidate failed the accuracy screen (English 7.66%, Swedish 19.47% WER). It is not available in the production model registry. INT4 and Core ML are outside this change.

Nemotron 3.5 is an explicit multilingual preview option. It does not replace the existing English preview automatically. Its full three-cold/ten-warm run measured 10.75% English and 23.87% Swedish WER, identical in each pass; the existing English preview measured 8.79% English WER. These are preview results, separate from final Parakeet transcription. The existing English preview comparison is a one-pass screen. The full Nemotron run overlapped other checks during some passes, so its latency measurements are diagnostic and do not promote defaults. See [all preview observations](nemotron-acceptance.json). New model downloads require an explicit Settings action.

The CPU thread screen tested 1, 2, 4, and 8 threads on a 20-utterance subset. Builds and another preview benchmark ran during parts of this screen. It is diagnostic only; the default remains four threads. Five German and five French utterances passed through final v3 as additional language smoke tests, not full language acceptance. Nine edge fixtures compared CPU and WebGPU output: silence, short speech, pauses, a chunk boundary, and synthetic mixed sources. Outputs matched. The same nine fixtures also completed with Nemotron 3.5, including its padded final chunks and automatic language detection for mixed sources. Silence produced no text. Swedish preview errors remain visible in [nemotron-edges.json](nemotron-edges.json). Simultaneous-source WER is diagnostic.

Preview measurements from that full run:

| Measurement | English median / p95 | Swedish median / p95 |
|---|---:|---:|
| First text, compute time | 269 / 419 ms | 274 / 454 ms |
| Audio available at first text | 1.68 / 2.24 s | 1.68 / 2.80 s |
| Stable text, compute time | 363 / 542 ms | 437 / 617 ms |
| Audio available at stable text | 2.24 / 2.80 s | 2.52 / 3.36 s |
| Complete utterance inference | 1.70 / 3.23 s | 1.82 / 3.19 s |

Shared-model session creation had a median of about 42 microseconds in both languages. Model load was 1.35–1.45 seconds and peak RSS about 2.75 GB. The model supplied the 8,960-sample chunk size through its metadata. [Timing aggregates](preview-timing-summary.json) retain the counts. Audio position and compute time are separate worker measurements; neither is a live capture-to-display measurement.

## Correctness and compatibility checks

- Rust: 177 tests passed. The explicit real-model test also passed with local English and Swedish fixtures. Missing fixtures or models caused a nonzero exit when that test was requested. The normal suite skips that opt-in model test and two documentation examples.
- Formatting and Clippy with all targets and features passed. Locked dependency resolution is used in builds and CI. Generated UniFFI bindings compiled with the app.
- Swift: 25 tests, one opt-in Instruments workload skipped, zero failures. Tests cover preview cancellation and partial chunks, event order and stale revisions, cancellation before and after session creation, and credential migration failure paths.
- Release app build, packaged startup, actual WebGPU model initialization, the stable launcher identity, bundled native runtime, and six Mach-O deployment targets passed. The deployment target remains macOS 14 on Apple Silicon.
- Storage tests cover additive legacy migrations, recognized and processed text, search, export, deletion, and SQLite backup/restore with WAL data. Configuration and profile tests preserve selected model IDs and provider-specific credential references.
- Provider tests use local mock HTTP servers. They cover Responses and Anthropic payloads, headers, UTF-8 streaming, required terminal events, output limits, retries, cancellation, and Ollama thinking capability checks. They are not proof of live provider compatibility.
- Dependency audit: no reported vulnerabilities in the recorded audit. `RUSTSEC-2024-0436` remains: `paste 1.0.15` is unmaintained through `tokenizers -> parakeet-rs`. See [advisories.json](advisories.json).

## Default Make build follow-up

A later check of plain `make` found two gaps in the earlier validation: PATH selected cargo-swift 0.11.0, and Xcode's global build directory retained an old static FFI include directory that shadowed the new framework headers. Earlier validation used the pinned local generator and a separate Xcode build directory, so it did not expose that combination.

Make now prefers `target/tools/bin` and uses `target/xcode` by default. The build-products helper, run targets, and CI tests use the same directory. The setup instructions install the pinned generator locally. Plain `make` and `make release` both passed after this change, without a command-line PATH override. Release product discovery resolved the correct app. Global Xcode caches and global tool installations were left unchanged.

## UI measurements and limits

Views observe their relevant coordinators. History searches run off the main actor, debounce for 250 ms, and discard stale results. Detail segments load on selection and are cached. Timeline rows are lazy. Meter updates are limited to 20 Hz, and automatic scrolling stops when the user leaves the bottom.

The opt-in Instruments workload used 1,000 history rows, 5,000 timeline segments, 100 recording overlay updates, and 20 background history queries. Median history-query time was 0.134 ms, with a maximum of 6.657 ms. Updating recording state took a median of 54 microseconds. This does not measure microphone start/stop latency.

The Time Profiler run recorded 46 main-run-loop gaps above 50 ms, with a maximum of 128 ms. Attribution was mainly SwiftUI layout and related runtime work. The Animation Hitches trace did not contain compositor frame records for XCTest. Its zero hitch rows must not be interpreted as zero frame stalls. The synthetic workload uses nested run-loop waits and Instruments adds overhead. These results do not establish a before/after frame-rate improvement. See [ui-profile-final.json](ui-profile-final.json), [ui-attribution.json](ui-attribution.json), and [ui-hitch-summary.json](ui-hitch-summary.json).

## Remaining release gates

- Run the packaged app on an actual macOS 14 installation and other hardware families. The binary target check does not replace a runtime test.
- Check microphone and system-audio capture, recording-control response, first/stable preview latency with live audio, and compositor frame stalls in the installed app. The speech worker measures inference and audio position, not complete capture-to-display latency.
- Test permission persistence by updating an installed app with existing microphone, screen/audio, and Accessibility permissions. The stable launcher's recorded identity is unchanged, but that is not a completed permission upgrade test.
- Run credential-dependent live checks for OpenAI, Anthropic, LM Studio, and Ollama against the user's selected model IDs. No remote LLM was enabled and no live credentials were used for validation.
- Run the updated GitHub workflows. Local checks used Xcode 26.4; both CI workflows pin Xcode 16.4 on `macos-15`. Local tests do not prove a successful remote CI run.
- Resolve the UI measurement gaps before claiming a rendering latency improvement. Keep unvalidated backend combinations disabled.

Signing/notarization, new diarization, INT4, Core ML, and a full Swift concurrency migration remain outside the agreed scope.

## Reproduce

Install the pinned tools as described in the main README. Model installation is explicit. Retain the [FLEURS attribution and fixture definitions](fixtures.md).

```sh
python3 scripts/prepare-fixtures.py
python3 scripts/prepare-edge-fixtures.py
make swift-package
make xcode
make benchmark ARGS='--model /absolute/path/to/parakeet-tdt-0.6b-v3 --backend cpu --output target/maintenance/cpu'
make benchmark ARGS='--model /absolute/path/to/parakeet-tdt-0.6b-v3 --backend webgpu --output target/maintenance/webgpu'
python3 scripts/compare-benchmarks.py reports/maintenance/baseline.json target/maintenance/webgpu.json --acceleration --output target/maintenance/gates.json
make benchmark-streaming ARGS='--model /absolute/path/to/nemotron-3.5-asr-streaming-0.6b --output target/maintenance/preview'
scripts/profile-ui.sh
```

Do not run competing builds or benchmarks during latency acceptance runs. The benchmark command writes JSON and Markdown with source, worker, runtime-lock, model, hardware, OS, backend, accuracy, load, and memory provenance. The JSON retains observations. Some early reports were collected while the maintenance worktree was dirty; their immutable worker hashes identify the binaries tested. Do not treat the commit field in such a report as a clean source build.

Official implementation references: [shared Nemotron models](https://github.com/altunenes/parakeet-rs/blob/v0.3.8/examples/shared_model.rs), [OpenAI Responses](https://platform.openai.com/docs/api-reference/responses/create), [Anthropic Messages](https://platform.claude.com/docs/en/api/messages/create), and [Ollama chat](https://docs.ollama.com/api/chat), and [Ollama thinking metadata](https://github.com/ollama/ollama/blob/main/docs/capabilities/thinking.mdx).
