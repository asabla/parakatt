# Changelog

## Unreleased

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
