# Changelog

## Unreleased

## 0.7.4

### Fixed
- Let an explicit WebGPU selection try GPU acceleration on other Apple Silicon Macs, including M4, with CPU fallback if initialization or inference fails
- Keep Automatic restricted to validated hardware and OS combinations and report WebGPU loading and fallback states correctly
- Restore YouTube link imports with an optional, explicitly selected browser session and browser-folder access
- Preserve dictionary rules, saved settings, recovery audio, and transcript history when saving or processing fails
- Keep recording controls, hotkey events, and clipboard restoration consistent

## 0.7.3

### Fixed
- Preserve speech that crosses a chunk overlap by checking word timing before grouping sentences
- Preserve multilingual words by removing automatic English filler stripping
- Keep dollar signs literal in plain dictionary replacements while retaining capture expansion for explicit regex rules
- Preserve saved import corrections through pause, resume, restart, completion, and backup restoration, with consistent Undo behavior
- Save the global mode selection and use one mode and application context throughout each push-to-talk recording, including per-app defaults
- Correct meeting label descriptions to identify microphone and system audio sources without promising individual speaker identification

### Added
- Experimental output-only file transcription CLI for macOS and Linux, built from source with bounded 16 kHz mono WAV or raw float input
- Regression coverage for overlapping speech, multilingual words, dictionary replacements, import edits and Undo, and recording mode selection

## 0.7.2

### Changed
- Restore automatic WebGPU for the validated Apple M3 Max/macOS 27.0.1 build 26A434 configuration with the existing model, native runtime, and four-thread policy
- Select Python 3.13 in CI and validate media build environments before reuse

### Fixed
- Skip optional buffered preview while required work is queued or the speech model is busy
- End buffered preview at Stop and reject late results after session finish, cancel, reset, or replacement
- Retry the same preview audio after a transient busy-model response

### Added
- Isolated public-fixture replay of the app's Stop-to-final-state path and retained before/after measurements

## 0.7.1

### Changed
- Update Rust to 1.99.1 and refresh the locked Rust dependencies, including SQLite, SHA-256, Tokio, and TOML support
- Update bundled yt-dlp to 2026.10.26, Deno to 2.9.8, FFmpeg to 9.0.2, and dav1d to 1.5.4 with matching sources and notices
- Update the pinned media build tools and CI artifact actions

### Fixed
- Rebuild dav1d in a version-specific directory when its pinned version changes
- Replace stale media sources and notices when rebuilding dependencies

## 0.7.0

Changes since 0.6.1. See [the release notes](RELEASE_NOTES.md) for installation details and limits.

### Added
- Local video, direct-link, and public YouTube transcription with audio-track selection, checkpoints, and resumable imports
- Bundled original-video playback with timestamp seeking, speed, volume, and transcript following
- SRT and VTT subtitle export
- Recording recovery, optional bounded temporary audio retention, and retry of failed processing
- Processed-text editing and undo while preserving recognized text and timestamps
- Transcript search, keyboard match navigation, paginated history, and a bounded detail cache
- Verified model downloads, multilingual Nemotron preview, and validated WebGPU execution with the existing Parakeet v3 final model
- Live meeting transcript controls, pause/resume, capture diagnostics, and capture-source labels
- Complete LLM provider diagnostics and optional bounded preceding-speech context
- Release version/build checks, matching tag checks, asset checksums, and a cask generated from the release DMG

### Changed
- Package the media tools and playback engine with corresponding sources and notices
- Preserve recognized text through cancellable LLM processing
- Use the same package verification in CI and the tag release workflow
- Use the checked-in stable launcher instead of rebuilding it during a release
- Keep temporary audio retention and preceding-speech context off by default

### Fixed
- Meeting audio loss, chunk order, overlap handling, and timeline offsets
- Microphone permission checks and audio buffering during model startup
- Incomplete recordings being treated as successful or pasted automatically
- Repeated overlay updates, blocked history loading, and controls covering transcript content
- Playback preparation errors, stalled loads, and audible preloading
- Dependency download retries, stale generated bindings, and DMG error propagation
- Cargo tool-manager shims looping during binding generation
- Release launcher identity mismatch with the previously published 0.6.1 package

## Earlier unversioned notes

### Added
- Sentence-level timestamp extraction from Parakeet STT (`TimestampedSegment` type)
- Timeline view in transcription history with `[MM:SS]` timestamps and visual dot/line navigation
- Per-chunk dictionary + LLM processing for meetings and long recordings
- `transcript_segments` SQLite table for persisting timestamp data
- Markdown export with timestamps for transcriptions that have segment data
- Token guard (4000-word limit) to prevent LLM timeouts on large transcripts
- Long push-to-talk recording warning (>5 minutes)
- Pending audio buffer caps (60s per source) in meeting service
- `get_session_text()` API for on-demand accumulated text retrieval

### Changed
- `process_chunk()` now applies dictionary + LLM per-chunk instead of deferring to `finish_session()`
- `finish_session()` simplified — no longer runs LLM on the full accumulated transcript
- `ChunkResult` now includes `segments` and `chunk_offset_secs` fields
- `TranscriptionResult` now includes `segments` field
- Meeting `onChunkTranscribed` callback now includes timestamp segments
- Meeting sessions accept mode and context at start for per-chunk processing

### Fixed
- LLM bomb: long meetings no longer send entire transcript to LLM at once

## 0.1.0

Initial release.

- Menu bar app with global hotkey (Option+Space) for recording
- On-device speech-to-text using Parakeet TDT 0.6B v2 (ONNX)
- Live streaming transcription with recording overlay
- Auto-paste transcribed text via accessibility APIs
- LLM post-processing support (Ollama, LM Studio, OpenAI, Anthropic)
- Dictionary rules for domain-specific word replacement
- In-app model download and management
- Settings UI for general, LLM, models, and dictionary configuration
