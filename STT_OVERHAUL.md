# STT Pipeline Overhaul — Tracking

Branch: `stt-pipeline-overhaul`. Working doc — delete on merge.

## Critical (blocks accuracy/timestamps) — ALL FIXED ✅

- [x] **C1** Verify mel feature dimensions for Parakeet TDT v2 (128, not 80).
      Confirmed via `parakeet-rs` 0.3.4 source: it uses `feature_size: 128`
      with `hop=160`, `n_fft=512`, `win=400`, preemph 0.97, per-feature
      mean/var normalization. No code change needed.
- [x] **C2** Remove peak normalization in `audio.rs`. Also discovered
      `parakeet-rs` already applies pre-emphasis and per-feature
      mean/var normalization, so our extra `pre_emphasis()` and the
      noise gate were both *additionally* wrong. All three removed —
      `preprocess()` now only validates the sample rate and trims
      leading/trailing silence.
- [x] **C3** Fix duration mismatch. `audio::preprocess()` now returns
      `PreprocessedAudio { samples, leading_trim_secs }`, and
      `engine.rs` adds `leading_trim_secs` to every STT segment so
      timestamps refer to the original chunk's time base, not the
      trimmed waveform's.
- [x] **C4** Rewrite session segment dedup. Replaced the off-by-one
      word-counting heuristic with segment-level matching: cache
      normalized text of the last 8 segments, find the longest suffix
      that matches a prefix of the new chunk's segments, skip exactly
      that many. The chunk's emitted text is rebuilt from surviving
      segments so it stays in sync with `accumulated_text`. Includes
      regression tests for misaligned boundaries and punctuation.
- [x] **C5** Fix unsafe AX casts in `ContextService.swift`. Replaced
      `as! AXUIElement?` (force cast to optional type — crashes on
      non-AXUIElement) with `CFGetTypeID == AXUIElementGetTypeID()`
      guards.

## Major — 13/13 fixed ✅

- [x] **M5** −6 dB per-source mixing headroom in `MeetingSessionService`
      so mic + system audio doesn't clip when both speakers are loud.
- [x] **M6** AVAudioConverter creation moved off the AVAudioEngine tap
      thread (real-time hardware thread, allocations unsafe) onto a
      dedicated serial queue. The racing buffer at format-change time
      is dropped instead.
- [x] **M7** Device-change listener now uses `passRetained()` and
      releases the pointer in `removeDeviceChangeListener()`. Previously
      `passUnretained` would let the C callback fire after dealloc → UAF.
- [x] **M8** Force unwraps replaced with guards: `AVAudioFormat(...)!`
      in both AudioCaptureService and SystemAudioCaptureService,
      `FileManager.urls(...).first!` in AppState (with fallback to
      `~/Library/Application Support`), and TextInsertionService's
      AX cast guarded by `CFGetTypeID`.
- [x] **M9** LLM failures no longer silently swallowed. `apply_llm`
      now returns `Option<String>`; `TranscriptionResult` and
      `ChunkResult` carry an `llm_error` field through to Swift, which
      logs degraded chunks.
- [x] **M10** `accumulated_text` removed from `ChunkResult` to drop
      the per-chunk full-string clone. Swift callers now pull the
      running transcript on demand via `bridge.getSessionText(sessionId:)`.
- [x] **M11** Hardcoded `16000` sample rate in `stt/parakeet.rs`
      replaced with the parameter.
- [x] **M12** CoreML EP confirmed not compiled in — `Cargo.toml` only
      enables `parakeet-rs` `cpu` feature, defaults are CPU-only on
      macOS. CoreML EP is broken for Parakeet (ort#26355).
- [x] **M3** PTT pre-roll ring buffer. New `prewarm()` API on
      AudioCaptureService keeps the engine running with delivery
      suppressed and a 500 ms ring; the next `startCapture()` drains
      the ring as pre-roll. AppState calls `prewarm()` after every
      `finishStopRecording()` so subsequent presses are warm.
- [x] **M4** `@MainActor` enforcement on `AppState`, `AppDelegate`,
      `MenuBarManager`, and `RecordingOverlayController`. The
      `@Published` updates were already being main-dispatched manually
      in every code path; this just lets the compiler enforce it.
      Two `HotkeyService` callbacks that were calling
      `appState.startRecording()` directly from a Carbon hotkey thread
      now main-dispatch like the stop path already did. Build clean,
      no behavior change.

- [x] **M2** Voice Activity Detection. New `vad.rs` module with a
      `Vad` trait and a `EnergyVad` hysteresis-based implementation
      now powers `audio::preprocess`. This is a real upgrade over
      the old "single threshold" trim:
      - Single-frame clicks no longer register as speech (≥3
        consecutive above-enter frames required).
      - Brief intra-utterance pauses (≤500 ms) no longer split a
        sentence.
      - Each voiced span is padded ±80 ms so we don't clip leading
        consonants or trailing fricatives.
      The `Vad` trait is the integration point for a future
      `SileroVad` ONNX implementation; dropping it in is now a
      one-file change rather than a re-architecture.

- [x] **M1** Time-based middle-token merging.
      `SessionManager::add_chunk_with_overlap` + `Engine::process_chunk_with_overlap`
      now accept the overlap window in seconds and drop any STT
      segment whose start falls inside it. This is exact and
      deterministic — no string-matching heuristics. MeetingSessionService
      passes `overlapDurationSecs` (2.0) for every chunk after the
      first, so meeting mode now uses the authoritative path.
      The text-based segment dedup (C4) stays as the fallback for
      callers that don't know the overlap (e.g. PTT) and as a safety
      net even on the new path.

## Minor — 11/11 closed (8 fixed, 3 verified-not-bugs)

- [x] **m1** 60 ms trailing silence pad hardcoded — kept as a documented
      `const TRAILING_SILENCE_PAD_FRAMES`. The audit suggested making it
      configurable, but no caller needs that; revisiting if any do.
- [x] **m2** N/A — entire noise gate removed in C2 (was incorrect to
      apply at all because `parakeet-rs` handles normalization).
- [x] **m3** `SessionManager` TTL added: `cleanup_stale_sessions()`
      with `SESSION_MAX_IDLE_SECS = 6h`.
- [x] **m4** Audit-was-wrong. Per-chunk LLM token guard already exists
      (`llm_max_words` truncates each chunk independently). A
      *session-wide* compounding cap would actively *degrade* long
      meetings — every chunk genuinely needs cleanup, and the per-call
      bound already prevents the timeouts that motivated this guard.
      No fix needed.
- [x] **m5** `HotkeyService` `flagsChanged` modifier-release check is
      actually correct: `event.modifierFlags.contains(self.configuredModifiers)`
      reports the *current* state of all modifiers, so releasing one
      configured modifier while another non-configured modifier is
      still held still triggers stop correctly. Verified, no change
      needed.
- [x] **m6** `AXIsProcessTrusted()` checked upfront in
      `TextInsertionService.insertText` — AX strategy is skipped
      entirely when permission isn't granted.
- [x] **m7** Clipboard restore window bumped 0.5 s → 1.0 s and made
      cancellable via `DispatchWorkItem`; `deinit` cancels any pending
      restore.
- [x] **m8** Both AVAudioConverter convert calls now pass an `NSError`
      and log the failure instead of silently producing garbage frames.
- [x] **m9** Mic / system audio sync drift — audit-was-mostly-wrong.
      The lag is already capped at 60 s per source via
      `maxPendingSamples`; if one source races ahead, the oldest
      excess is dropped with a logged warning. A proper timestamp-
      based clock alignment is a worthwhile follow-up but not a
      correctness bug — accepted as-is.
- [x] **m10** Real leak fixed in `MeetingSessionService.start()`: if
      either capture service throws after `bridge.startSession()`
      succeeded, we now unwind the Rust session and stop the partially
      started capture. (The other timer-leak sites the audit named
      were already correctly handled in their `catch` blocks.)
- [x] **m11** `TextInsertionService.deinit` cancels its pending
      clipboard restore.

## Key references
- NeMo buffered RNNT: `examples/asr/asr_chunked_inference/rnnt/speech_to_text_buffered_infer_rnnt.py`
- HF discussion #9 (ONNX export scope): https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2/discussions/9
- Python ONNX ref impl: https://github.com/istupakov/onnx-asr
- LocalAgreement-2: https://github.com/ufal/whisper_streaming, arxiv 2307.14743
- CoreML EP broken: https://github.com/microsoft/onnxruntime/issues/26355
- Silero VAD: https://github.com/snakers4/silero-vad
- Mic cold-start fix: https://github.com/drewburchfield/macos-mic-keepwarm
- Int8 weights: smcleod/parakeet-tdt-0.6b-v2-int8

## Mel feature canonical params (already implemented in parakeet-rs 0.3.4)
n_mels=128, n_fft=512, win_length=400, hop_length=160, hann, preemph=0.97, log-mel, per-feature mean/var norm, 8× temporal subsampling → 80 ms frame stride.

## Test status (current)
- `cargo test -p parakatt-core`: **129 passed, 1 ignored** across
  5 suites. Added across the architectural overhaul:
  - LocalAgreement-2: 14 unit tests including 2 stuck-after-chunk
    regression tests
  - ScriptedStreamingProvider: 5 lifecycle tests
  - streaming_e2e.rs: 22 E2E integration tests (happy path, flicker
    scenarios, silence handling, speech-resume, long sessions,
    concurrent sessions, reset, error injection, lifecycle, +
    buffered preview lifecycle)
  - audio_pipeline_e2e.rs: 20 audio + VAD scenarios (long pauses,
    quiet trailing fricatives, single-frame clicks, dynamic range
    preservation, realistic dictation patterns)
  - NemotronProvider: 3 construction tests
  - EnergyVad: 8 hysteresis tests
- `make build` (Xcode Debug): clean.

## Live-test status
- Two-style display (committed in primary, tentative in italic) is
  working as intended.
- Chunk-boundary "stuck after ~2 sentences" bug fixed via the
  buffered-preview LA-2 reset on chunk dispatch (commit `e09a4c1`).
- Residual 1-2 s hiccups still observed when a chunk dispatches
  on a CPU-saturated machine. This is structural to running
  Parakeet TDT v3 on the growing preview buffer at ~1.5 s per
  pass; eliminating it requires either:
  1. Downloading the Nemotron streaming model (the streaming
     path's cost is constant per chunk regardless of buffer
     length), or
  2. Lowering pttMinChunkSecs / pttMaxChunkSecs at the cost of
     more chunk dispatches (and more LLM calls if enabled), or
  3. Switching to a smaller distilled commit-path model.
  As of the live-test report, the current implementation is
  "fine for now" — acceptable but not optimal.

---

## Phase 2 — Architectural overhaul (post-original audit)

After the original audit was closed, the user reported live-preview
latency issues during real dictation. Research (whisper-streaming,
WhisperKit, NVIDIA cache-aware streaming Parakeet, Riva) revealed
the core architecture was a buffered-streaming anti-pattern: the
preview path re-encoded a growing audio buffer every 2 s, getting
slower as recording continued. NVIDIA explicitly built cache-aware
streaming Parakeet (Nemotron) to replace this.

### Phase 2 work landed

- [x] **P0-1** Drop Parakeet v2; default to v3. Same `parakeet-rs` API,
      drop-in replacement, 25 European languages, native silence-
      hallucination training, ~+0.3 WER on English (imperceptible
      for general dictation).
- [x] **P0-2** Register `nemotron-speech-streaming-en-0.6b` in the
      model registry as the streaming preview model.
- [x] **P0-3** Implement **LocalAgreement-2** commit policy in
      `crates/parakatt-core/src/local_agreement.rs`. Pure Rust,
      STT-agnostic, 12 unit tests covering flicker suppression,
      casing/punctuation normalization, advance() persistence
      hand-off, and edge cases. Adapted from Macháček et al. (UFAL,
      arXiv 2307.14743).
- [x] **P0-4** VAD-aware PTT chunk dispatch — replaced the fixed
      28 s timer with a 1.5 s tick that flushes when EITHER the
      speaker has been silent ≥500 ms (natural sentence boundary)
      OR the buffer hits 12 s (hard cap). Chunks become variable-
      length and naturally aligned to pauses.
- [x] **P1-1** New `StreamingProvider` trait in `stt/streaming.rs`
      parallel to `SttProvider`. Stateful — exposes
      `start_session() -> Box<dyn StreamingSession>` and the
      session has `feed_chunk` / `current_transcript` / `reset`.
- [x] **P1-2** `NemotronProvider` impl wrapping
      `parakeet_rs::Nemotron`. Lazy model loading, per-session
      cache state, native chunk size = 8960 samples (560 ms).
- [x] **P1-3** `Engine` refactor — holds both `stt` (offline commit
      path) and `streaming` (cache-aware live preview) providers
      simultaneously. `load_model` routes by id prefix
      (`parakeet-*` → stt, `nemotron-*` → streaming). New uniffi
      methods: `is_streaming_model_loaded`,
      `streaming_native_chunk_samples`, `start_streaming_session`,
      `feed_streaming_chunk`, `reset_streaming_session`,
      `finish_streaming_session`, `cancel_streaming_session`,
      `should_use_streaming_preview`.
- [x] **P1-4** `StreamingPreviewSession` wraps the model session
      with a `LocalAgreement2` instance. Each `feed_streaming_chunk`
      call returns a `StreamingChunkResult { committed_text,
      tentative_text, newly_committed_text }` ready for the UI to
      render two-style.
- [x] **P1-5** New `Parakatt/Services/LivePreviewService.swift` —
      owns a dedicated worker queue, accumulates audio samples
      from the AVAudioEngine tap into a small ring, dispatches one
      native chunk at a time, handles backpressure with an
      `inFlight` flag, auto-disables itself after 5 consecutive
      errors, lifecycle: `start` / `enqueue` / `stop` / `cancel`.
      Wired into AppState via two new `@Published` properties:
      `livePreviewCommitted` and `livePreviewTentative`.
- [x] **P1-6** Language routing — `streaming_preview_enabled` user
      flag in `GeneralConfig` (default true). English speakers get
      the fast preview by default; flag-off users (or those who
      didn't download Nemotron) fall back to the buffered v3 +
      LA-2 path, which still works.
- [x] **P1-7** Two-model download orchestration — both v3 and
      Nemotron registered, the existing settings UI surfaces them
      automatically since `list_models_with_status` handles both
      `vocab.txt` (Parakeet) and `tokenizer.model` (Nemotron)
      vocabulary file naming conventions.
- [x] **P2-1** Two-style transcript display in
      `RecordingOverlayView`. Committed text in primary foreground
      / normal weight, tentative tail in secondary foreground /
      italic. Renders as a single concatenated `Text` so it line-
      wraps as one paragraph.
- [x] **P2-2** Legacy throwaway-preview UI path retained as
      fallback for non-streaming users. The two-style display only
      activates when LA-2 has produced text; otherwise the old
      `liveText` rendering takes over.
- [x] **P3-1** Power management — AppState skips feeding the
      streaming model after `livePreviewSleepCallbacks=100`
      (~10 s) of consecutive silence. Existing silence→speech
      transition trigger resumes it on the next audio.
- [x] **P3-2** Per-session config snapshot — reviewed; not worth
      doing as a refactor. Locks are short-lived (~3 acquires
      per chunk), no measurable contention at 3 Hz streaming.
- [x] **P3-3** Latency telemetry in `LivePreviewService`:
      first-token latency logged on first non-empty commit,
      average per-chunk feed latency logged every 20 chunks,
      committed-prefix advance count tracked for churn analysis.

### Phase 2 commit log
- `models: drop Parakeet v2, default to v3 + register Nemotron streaming`
- `core: implement LocalAgreement-2 commit policy`
- `core: StreamingProvider trait + NemotronProvider impl`
- `engine: hold both batch + streaming providers, expose streaming session API`
- `engine: wire LocalAgreement-2 into streaming sessions`
- `swift: VAD-aware PTT dispatch + LivePreviewService for streaming path`
- `appstate: wire LivePreviewService into the recording flow`
- `ui: two-style transcript display (committed + tentative tail)`
- `config + telemetry: streaming preview opt-in flag, latency logging`
