# Capture, history, and provider follow-up

This change implements the next set of improvements after the reliability work. It preserves explicit settings. Temporary audio and preceding LLM context remain off by default. No model or backend is promoted.

## Changes

- **Capture recovery:** Optional audio checkpoints start with capture, before a speech model is ready. A separate serial writer accepts at most 32,000 pending samples. Live speech workers accept at most two operations each. PTT audio waiting for recognition is bounded to 60 seconds; meeting buffers retain their existing five-minute limit. Capture-write overflow or a full waiting-audio buffer stops recording, persists an incomplete flag, and prevents automatic paste of a partial result. A full speech-work queue leaves audio in its bounded buffer until a worker is available. Recording does not wait for model loading.
- **Capture lifecycle:** Active captures cannot be recovered or discarded. Stopping capture drains accepted checkpoint writes before it releases the capture registration. Failed meeting startup releases that registration too. Meeting tails use at most 30-second slices with the normal overlap. Audio recovery uses the same history ID and bounded reads; existing recognized text is saved before a replay changes chunk boundaries.
- **History:** Load 100 recordings per page, with a lookahead to show Load more recordings. Stable ordering resolves equal timestamps. The detail cache holds at most eight entries and 500,000 bytes of transcript text; an oversized selected transcript stays outside the cache. Edits and deletion invalidate the cache. Query failures are visible and have a retry action.
- **Overlay:** Meter changes update a dedicated view instead of replacing and measuring the complete overlay. Wheel or trackpad scrolling pauses automatic following. Follow live resumes it. Instructions follow the configured hold or toggle shortcut.
- **Transcript search:** Search processed text or recognized segments, highlight matches, and use Cmd+G / Cmd+Shift+G to navigate. Cmd+Shift+F focuses this search; Cmd+F retains history search. Search handles Unicode and bounds results to 2,000 matches.
- **LLM context:** The opt-in setting supplies up to 120 words from at most two previous recognized chunks of the same source and session. The payload separates context from the rewrite target. Its system instruction forbids repeating the context and requires preserving meaning, names, numbers, and language unless the mode requires translation. This instruction is not proof of model compliance.
- **Provider diagnostics:** Test selected model checks reachability and authentication, then sends a synthetic request through the production streaming decoder. Model acceptance and a non-empty terminal completion are required. Authentication rejection and incomplete streams have separate results. The connection probe has a 15-second limit and completion has a 60-second limit. No recording is sent.

## Recovery limits

Audio is still opt-in. A crash can lose pending checkpoint writes: up to two seconds of mono audio, or one second across two equally active meeting sources. Recovery covers the last durable checkpoint; it does not promise to recover uncommitted samples. Raw meeting sources retain sample order; capture checkpoints do not add wall-clock synchronization for a source that fails to deliver callbacks.

The combined retained-audio budget remains 512 MiB with 24-hour expiry. Successful completion, explicit discard, and disabling retention remove the associated audio. Backups exclude checkpoint audio as well as older speech-chunk audio. The budget covers retained audio bytes, not all database metadata or SQLite file overhead. Enabling retention during a recording takes effect for capture checkpoints on the next recording.

## Verification

- `cargo test --locked`: 191 tests passed. The separate explicit release-mode real-model test passed for English and Swedish. Two documentation examples remain ignored.
- `cargo fmt --all` and `cargo clippy --locked --all-targets --all-features -- -D warnings`: passed.
- Plain `make`, `make release`, and the regenerated Swift binding build: passed.
- Swift tests: 39 passed, one opt-in performance test skipped, no failures. A separate Release app workload was run under Instruments. New tests cover bounded work capacity, checkpoint drain before recovery, pagination through 605 records, query errors, cache eviction, and Unicode search.
- Rust tests cover recovery before model submission, active-capture exclusion, incomplete state after loss, checkpoint expiry, backup exclusion, preservation of recognized text before replay, context bounds and isolation, and rejection of incomplete provider streams.
- Compact dark history was visually inspected. Existing layout tests also generated standard dark, wide light, and timeline images. Manual scrolling and keyboard shortcuts still need a user interaction check; the tests verify layout and search logic.
- Packaged startup passed with the recorded stable launcher, six compatible Mach-O deployment targets, the installed final model, and the validated WebGPU backend. The microphone permission query returned authorized. This does not establish live microphone capture or permission persistence across an installed update. See [startup evidence](evolution-packaged-startup.json).

## Measurements

Instruments Time Profiler attached to the exact copied Release executable on Apple M3 Max, macOS 27 build `26A428`. No task builds or model benchmarks ran during the workload. The report records the framework hash and source revision with an uncommitted-tree marker. See [full results](evolution-app-profile.json).

The workload contains 1,000 history records, 20 background searches, 100 simulated overlay updates at 20 Hz, and scrolling through 5,000 recognized segments. The query timing uses the existing background-query adapter; pagination is verified separately. Overlay updates change both text and meter level, so this run does not isolate the benefit of meter-only updates.

| Observation | Previous run | This run |
| --- | ---: | ---: |
| Median history query | 0.506 ms | 0.812 ms |
| Maximum history query | 1.061 ms | 1.558 ms |
| Main-loop gaps above 50 ms | 34 | 31 |
| Longest main-loop gap | 175.5 ms | 137.0 ms |
| Resident memory at history start | 93.0 MiB | 93.0 MiB |
| Resident memory after history | 123.5 MiB | 124.4 MiB |
| Resident memory after overlay | 126.1 MiB | 127.2 MiB |
| Resident memory after scrolling | 287.3 MiB | 288.3 MiB |

These are single-run observations. They do not establish a general speed improvement or a regression. Run-loop gaps are not compositor frame times, and memory snapshots are not peak-memory measurements. The previous Animation Hitches trace had no compositor frame-lifetime rows; this change does not close that measurement gap.

## Live providers and remaining checks

Synthetic completion checks against LM Studio (`openai/gpt-oss-20b`) and Ollama (`llama3.2`) both failed without a valid completed stream. See [LM Studio](evolution-lmstudio-live.json) and [Ollama](evolution-ollama-live.json). The EN/SV context comparison was not run because those prerequisite checks failed. OpenAI and Anthropic remain unconfigured and were not exercised live. Mock server tests establish parser behavior, not live compatibility or rewrite accuracy.

The evaluation command is ready for a configured provider:

```sh
cargo run --locked --release --example polishing_eval -- lmstudio http://localhost:1234 openai/gpt-oss-20b
```

It compares context off/on for five synthetic English, Swedish, and mixed-language cases, recording completion and protected names, numbers, technical terms, and negation. Term presence is only a screening check. Read the outputs to assess meaning and language before changing the default. Remote credentials are accepted through `PARAKATT_PROVIDER_KEY` and are not printed.

An actual macOS 14 runtime, installed-app permission persistence, remote CI with its pinned Xcode version, live capture latency, and compositor frame stalls remain external release checks. This follow-up ran the EN/SV model smoke test and existing overlap tests, but did not repeat the full FLEURS or mixed-source chunk-boundary accuracy campaign. The earlier maintenance accuracy evidence remains in [the maintenance report](README.md); it must not be presented as validation of every new capture/recovery path.
