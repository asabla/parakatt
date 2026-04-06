# STT Pipeline Overhaul — Tracking

Branch: `stt-pipeline-overhaul`. Working doc — delete on merge.

## Critical (blocks accuracy/timestamps)

- [ ] **C1** Verify mel feature dimensions for Parakeet TDT v2 (must be 128, not 80). Check what `parakeet-rs` crate computes; if wrong, switch model/preprocessor.
- [ ] **C2** Remove peak normalization in `crates/parakatt-core/src/audio.rs:116` — destroys amplitude cues the model needs.
- [ ] **C3** Fix duration mismatch in `crates/parakatt-core/src/engine.rs:847` — use processed (trimmed) length, not raw.
- [ ] **C4** Rewrite segment dedup in `crates/parakatt-core/src/session.rs:119-143` — current word-count math is off-by-one and drops segments.
- [ ] **C5** Fix unsafe AX casts in `Parakatt/Services/ContextService.swift:33,38,50` — `as! AXUIElement?` will crash; use `as?`.

## Major (architecture / robustness)

- [ ] **M1** Replace string-overlap dedup with middle-token merging (NeMo buffered RNNT pattern). Use `[left_ctx, left_ctx + chunk_len]` token gating.
- [ ] **M2** Add Silero VAD for both push-to-talk and meeting modes.
- [ ] **M3** Pre-roll ring buffer in `AudioCaptureService.swift` — keep AVAudioEngine running, capture 500ms before hotkey press (fixes mic cold-start).
- [ ] **M4** Annotate `AppState` with `@MainActor` and serialize all FFI calls through one queue.
- [ ] **M5** Fix meeting audio mixing in `MeetingSessionService.swift:248-275` — apply -6dB gain per source before sum (prevents clipping).
- [ ] **M6** AVAudioConverter recreated inside tap callback (`AudioCaptureService.swift:314-326`) — move to a serialization queue.
- [ ] **M7** Audio device change listener uses `passUnretained` (`AudioCaptureService.swift:210-224`) — UAF risk.
- [ ] **M8** Replace remaining force unwraps (`AVAudioFormat(...)!`, `urls(...).first!`, force casts in TextInsertionService).
- [ ] **M9** LLM failures silently swallowed in `engine.rs:1201-1225` — surface errors, especially for email/code modes.
- [ ] **M10** Remove `accumulated_text` from `ChunkResult` (clones full transcript every chunk in `session.rs:185`).
- [ ] **M11** Hardcoded `16000` sample rate in `stt/parakeet.rs:58` — use the parameter.
- [ ] **M12** Switch to int8 Parakeet weights, force CPU EP only on macOS (CoreML EP broken per ort#26355).
- [ ] **M13** Confirm/migrate to LocalAgreement-2 for live partial display during meetings (deferred — track for follow-up).

## Minor

- [ ] **m1** 60ms trailing silence padding hardcoded in `audio.rs:88` — make configurable.
- [ ] **m2** Noise gate threshold untuned in `audio.rs:23`.
- [ ] **m3** `SessionManager` HashMap unbounded in `session.rs:48` — add TTL or cleanup.
- [ ] **m4** Per-chunk LLM has no compounding token guard across session in `engine.rs:872`.
- [ ] **m5** `HotkeyService.swift:80-93` — Option+Cmd combo edge case in flagsChanged.
- [ ] **m6** `TextInsertionService.swift:21` — no `AXIsProcessTrusted()` check upfront.
- [ ] **m7** `TextInsertionService.swift:146-164` — clipboard restore window 0.5s too tight.
- [ ] **m8** Audio buffer converters ignore errors (`AudioCaptureService.swift:336-341`, `SystemAudioCaptureService.swift:220-225`).
- [ ] **m9** Mic/system audio sync drift in `MeetingSessionService.swift:221-243` — needs timestamp-based alignment.
- [ ] **m10** Timer leaks on early-throw paths (`AppState.swift:232-236, 753`, `MeetingSessionService.swift:100-106`).
- [ ] **m11** `TextInsertionService` no deinit to cancel scheduled clipboard restore.

## Key references
- NeMo buffered RNNT: `examples/asr/asr_chunked_inference/rnnt/speech_to_text_buffered_infer_rnnt.py`
- HF discussion #9 (ONNX export scope): https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2/discussions/9
- Python ONNX ref impl: https://github.com/istupakov/onnx-asr
- LocalAgreement-2: https://github.com/ufal/whisper_streaming, arxiv 2307.14743
- CoreML EP broken: https://github.com/microsoft/onnxruntime/issues/26355
- Silero VAD: https://github.com/snakers4/silero-vad
- Mic cold-start: https://github.com/drewburchfield/macos-mic-keepwarm
- Int8 weights: smcleod/parakeet-tdt-0.6b-v2-int8

## Mel feature canonical params
n_mels=128, n_fft=512, win_length=400, hop_length=160, hann, preemph=0.97, log-mel, per-feature mean/var norm, dither=0, 8× temporal subsampling → 80ms frame stride.
