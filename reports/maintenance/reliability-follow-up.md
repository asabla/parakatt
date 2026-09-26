# Recording reliability and history follow-up

This change follows the maintenance work and the history layout fix. It adds recovery records, history correction and retry controls, capture diagnostics, and a workload that runs inside the Release app. It does not promote a new model or execution backend.

## Behavior

- Submitted speech chunks are recorded before recognition. Failed speech sections keep the recording incomplete. Completion reports an error and prevents automatic paste of a partial transcript.
- Recognized text is saved per chunk before LLM processing. After interruption, History can save this text or retry retained audio. Recovery reuses the history ID and does not paste into another app.
- Temporary audio is opt-in and is off by default. Retention is limited to 24 hours and 512 MiB. Expiration runs when the app opens or accesses recovery data. Successful completion and explicit discard remove the recovery record. Disabling audio retention clears the retained audio. Backups exclude audio.
- Recovery begins at submission to the speech worker. It does not protect audio still buffered by Swift, including audio waiting for initial model loading. Audio that has expired or was not retained cannot be reconstructed. Text-only recovery is marked interrupted.
- History can retry failed LLM sections, cancel a retry, edit processed text, and undo the last text change. Original speech and timestamps remain separate. Copy follows the selected transcript view.
- Adjacent chunks from the same source use a space instead of a forced paragraph break. Explicit paragraphs and source changes remain. Known non-overlapping chunks preserve repeated phrases. PTT passes its actual incoming overlap, and retained audio alone does not trigger another chunk.
- Timeline offsets and duration exclude already-counted overlap. Recovery stores absolute timestamps for the surviving recognized segments.
- The recording overlay reports input device, model readiness, and missing or silent input. A missing selected application does not expand capture to all system audio. Transcript contents were removed from normal application logs.

## Verification

- Rust: 184 tests passed; the separate, explicit real-model smoke test passed for English and Swedish. Two documentation examples remain ignored. Rustfmt and Clippy with all features passed.
- Plain `make` and `make release` passed with regenerated bindings. Swift: 34 passed, one opt-in profiling test skipped, no failures. The dedicated app profiling command was run separately. Compact dark, standard dark, wide light, and narrow timeline renders were inspected.
- Packaged startup passed with the recorded stable launcher, six Mach-O deployment targets at macOS 14 or earlier, the installed final model, and the validated WebGPU backend. The microphone permission query returned authorized; this is not a live capture or app-upgrade permission test. See [startup evidence](reliability-packaged-startup.json).
- Tests cover interrupted storage across restart, failed recognition, recovery without duplicate history, retention off and expiry, backup exclusion of audio, timestamp recovery, delete cleanup, correction and undo, retry beyond the live queue capacity, and cancellation rejecting late LLM output.
- Live LM Studio (`openai/gpt-oss-20b`) and Ollama (`llama3.2`) completion checks failed. Their reports contain no valid completion. OpenAI and Anthropic have no selected model in this configuration and were not exercised live. See [LM Studio](reliability-lmstudio-live.json) and [Ollama](reliability-ollama-live.json). Mocks do not prove live compatibility.

All recovery and UI tests use synthetic data and isolated storage.

## App performance observations

The final Time Profiler run used the exact copied Release executable on Apple M3 Max, macOS 27 build `26A428`, with no competing task builds or benchmarks. The recorded framework hash identifies the tested binary; the source tree was not yet committed. [The full report](reliability-app-profile.json) retains observations and provenance.

- Twenty background history queries: median 0.506 ms, maximum 1.061 ms.
- Main-run-loop gaps above 50 ms: 34; maximum 175.5 ms.
- Sampled resident memory: history start 93.0 MiB, history end 123.5 MiB, overlay end 126.1 MiB, scroll end 287.3 MiB. These are snapshots, not a continuous peak-memory measurement.

A separate attached Animation Hitches run recorded 25 potential main-thread hangs above its 33 ms threshold; the longest was 564 ms. It produced no compositor frame-lifetime rows. Zero hitch rows therefore do not establish zero frame stalls. See [the frame summary](reliability-frame-summary.json). No before/after rendering speed claim is made. An earlier valid Time Profiler run attributed most main-thread samples to Swift runtime, SwiftUI, AttributeGraph, and layout-related system work; see [attribution](reliability-app-attribution.json).

Two failed `--launch` traces opened the installed app despite the supplied bundle path. They are excluded. The command now launches the exact executable itself and attaches by PID. No microphone capture was started in these attempts. The temporary task-owned processes were stopped.

## Remaining release checks

An actual macOS 14 runtime, permission persistence across an installed app update, live capture-to-preview timing, and configured live remote providers still require the corresponding environment. Local builds use Xcode 26.4. They do not prove that the Xcode 16.4 GitHub workflows pass. No additional backend combination is enabled by these changes.

The full FLEURS accuracy acceptance from the earlier maintenance remains recorded in [the maintenance report](README.md). Speech model artifacts and inference code are unchanged here. Chunk assembly tests cover English and Swedish, but do not establish end-to-end word error rates for every chunk boundary.

## Reproduce the app workload

Build with `make` and `make release`, then run:

```sh
scripts/profile-app.sh "$PWD/target/maintenance/app-profile"
```

The command copies the Release app into a disposable bundle, starts that exact executable, and attaches Instruments by PID. A start gate keeps the workload idle until the profiler attaches. The workload uses 1,000 synthetic history rows, 20 searches, 100 overlay updates at 20 Hz, and 5,000 timeline segments. JSON records query latency, run-loop intervals, and sampled resident memory. Run-loop intervals are not compositor frame times. No microphone, model inference, or LLM is used.

To test a configured local provider without changing app settings:

```sh
cargo run --locked --release --example provider_smoke -- lmstudio http://localhost:1234 openai/gpt-oss-20b
cargo run --locked --release --example provider_smoke -- ollama http://localhost:11434 llama3.2
```

The command sends synthetic text through the production streaming interface. It succeeds only after a valid, non-empty completion. Provider credentials, when needed, are read from `PARAKATT_PROVIDER_KEY`; they are not printed. Remote providers require an explicit selected model and credential.
