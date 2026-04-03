# Parakatt Improvement Backlog

Tracked improvements and feature ideas for Parakatt.

---

## UX / Quality of Life

- [ ] **Completion notifications** — transcription finishes silently; add system notification or sound cue when done
- [ ] **Onboarding flow** — no first-run guide explaining the hotkey, modes, or permissions; users jump straight to Settings
- [x] **Expose hidden settings** — `auto_paste` and `show_overlay` exist in config but aren't in the Settings UI
- [ ] **Dictionary editor improvements** — no regex validation or test-before-save functionality
- [ ] **LLM connection test button** — users can't verify Ollama/OpenAI setup without attempting a transcription
- [ ] **Remember last meeting audio source** — requires manual app selection each time
- [ ] **Short recording feedback** — recordings <1s are silently skipped; show "Recording too short" warning
- [ ] **Model download progress in menu bar** — menu bar icon shows idle during model download; no visual hint
- [ ] **"No audio detected" warning** — recording overlay shows "Listening..." forever even if mic produces silence
- [ ] **Text insertion failure feedback** — if all 3 paste strategies fail, user sees nothing; show an alert
- [ ] **Clipboard restore race condition** — if user copies something during the 500ms restore window, their copy gets overwritten

## Export & Data

- [ ] **More export formats** — only Markdown today; add CSV/JSON for integrations
- [ ] **Batch export** — can only export one transcription at a time
- [ ] **Backup/restore** — no way to back up the SQLite DB from within the app
- [ ] **Auto-cleanup** — configurable retention (e.g., auto-delete transcriptions after N days)
- [ ] **Usage statistics** — total hours transcribed, word counts, mode breakdown

## Audio & Performance

- [ ] **Configurable chunk size** — hardcoded at 30s; shorter = faster feedback, longer = better context
- [ ] **LLM token limit slider** — 4000-token guard is hardcoded; power users may want to tune this
- [ ] **Audio quality indicators** — warn if input is too quiet, clipping, or mic isn't connected
- [ ] **Resume interrupted model downloads** — add HTTP Range header support for resumable downloads
- [ ] **Device hot-plug handling** — if user unplugs explicitly-selected headphones mid-recording, no recovery; add AudioObjectPropertyListener
- [ ] **Cache system audio converter** — SystemAudioCaptureService recreates AVAudioConverter every callback; cache and reuse
- [ ] **Audio preprocessing enhancements** — no noise reduction, echo cancellation, or pre-emphasis filtering; could improve STT quality
- [ ] **Unnecessary audio copy in STT** — `parakeet.rs` calls `audio.to_vec()` creating ~115MB copy for 30min recordings; investigate zero-copy API

## Customization

- [ ] **Custom modes** — users can't create their own modes with custom LLM prompts (only 4 built-in)
- [ ] **Per-app mode defaults** — auto-switch to "Code" mode when VS Code is focused, "Email" in Mail, etc.
- [ ] **Profiles** — save/load different config sets (work vs personal)

## Security

- [x] **SQL injection in storage.rs** — `list()` and `search_fts()` use string concatenation for source filter; switch to parameterized queries
- [ ] **API keys stored in plaintext** — config.toml stores OpenAI/Anthropic keys unencrypted; use macOS Keychain instead
- [ ] **Model download checksum verification** — downloaded ONNX files aren't validated against known hashes
- [ ] **ReDoS risk in dictionary** — user-supplied regex patterns (via `re:` prefix) have no complexity limits or timeout

## Concurrency & Correctness

- [ ] **Lock ordering not documented** — Engine holds 8 Mutexes with no documented acquisition order; potential deadlock risk
- [x] **LLM lock held during network I/O** — `apply_llm()` holds llm_guard through entire HTTP request; blocks config changes
- [x] **Inconsistent lock error handling** — some locks use `.unwrap()` (panics on poison), others use `.map_err()`; standardize
- [x] **Recording state race condition** — `startRecording()` guard isn't atomic; rapid start/stop could cause dual recordings
- [x] **Meeting state consistency** — `isMeetingActive` set before verifying session actually started (already correctly implemented)
- [x] **Overlap dedup punctuation bug** — words like "brown." won't match "brown" across chunk boundaries; strip punctuation before comparing
- [ ] **LLM truncation is lossy** — 4000-word truncation splits mid-sentence with no user notification; truncate at sentence boundary and warn

## Robustness

- [ ] **Swift test coverage** — Rust has ~17 unit tests, Swift has essentially none
- [ ] **Better error surfacing** — some failures only log to console; users see generic "No audio captured"
- [ ] **LLM timeout handling** — no explicit timeout UI; requests can hang silently
- [ ] **LLM error messages lack detail** — 4xx/5xx responses only show status code, not response body
- [ ] **LLM streaming support** — both providers hardcode `stream: false`; streaming would give real-time feedback and prevent timeout on long responses
- [ ] **LLM retry logic** — no retry with backoff for transient network failures

## Database

- [x] **Missing indexes** — no index on `created_at` or `source` columns; `ORDER BY created_at DESC` and source filtering do full table scans
- [ ] **Add composite index** — `(source, created_at DESC)` for the common filtered+sorted query pattern

## macOS Integration

- [ ] **Spotlight indexing** — transcriptions not indexed; add Core Spotlight integration for system-wide search
- [ ] **Shortcuts.app support** — no Shortcuts actions for "Start Recording" or "Transcribe"
- [ ] **Share sheet** — no NSShareLink integration; only manual copy/export
- [ ] **Drag and drop** — can't drag transcription text to Finder/Notes/Mail
- [ ] **Services menu** — could add "Transcribe Selection" as a system service

## Localization

- [ ] **50+ hardcoded English strings** — menu bar titles, overlay text, error messages, button labels all use raw strings; no NSLocalizedString or Localizable.strings

## CI/CD & Build

- [ ] **No PR testing workflow** — no CI runs on pull requests (no linting, testing, or build verification)
- [ ] **No linting enforcement** — no SwiftLint, rustfmt, or clippy checks in CI
- [ ] **No code signing / notarization** — self-signed only; users must bypass Gatekeeper with xattr workaround
- [ ] **No auto-update framework** — no Sparkle integration; users must manually download new releases
- [ ] **Manual version bumping** — version hardcoded in 4+ places (Makefile, project.yml, Info.plist, homebrew template); needs single source of truth
- [ ] **No changelog generation** — manual CHANGELOG.md edits; consider git-cliff or conventional commits
- [ ] **swift-package always regenerates** — `make swift-package` deletes and recreates ParakattCore/ even for minor changes; add incremental check
- [ ] **No Cargo release profile optimization** — missing LTO, codegen-units, strip settings in `[profile.release]`

## Logging & Observability

- [ ] **Dual logging systems** — NSLog (Swift) and env_logger (Rust) without coordination; consolidate
- [ ] **No file-based logging** — all logs go to console only; add persistent log files with rotation
- [ ] **No crash reporting** — no Sentry/Bugsnag or lightweight error tracking
- [ ] **No performance metrics** — no os.signpost markers; can't profile STT latency, LLM response time, or text insertion delay in Instruments
- [ ] **No debug mode toggle** — users can't enable verbose logging from Settings

## Accessibility

- [ ] **VoiceOver support** — not tested for screen readers
- [ ] **Respect Reduce Motion** — animations play regardless of system setting

## Documentation

- [ ] **No troubleshooting section** — README lacks guidance for common issues (permissions, model downloads, LLM timeouts)
- [ ] **No contribution guide** — no CONTRIBUTING.md with code style expectations
- [ ] **Minimal Swift doc comments** — Rust types have doc comments; Swift services/views have almost none
