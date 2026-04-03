# Parakatt Improvement Backlog

Tracked improvements and feature ideas for Parakatt.

**Status:** 61 completed, 10 deferred for future consideration.

---

## Completed

### UX / Quality of Life
- [x] Completion notifications
- [x] Onboarding flow
- [x] Expose hidden settings (auto_paste, show_overlay)
- [x] Dictionary editor improvements (regex validation)
- [x] LLM connection test button
- [x] Remember last meeting audio source
- [x] Short recording feedback
- [x] Model download progress in menu bar
- [x] "No audio detected" warning
- [x] Text insertion failure feedback
- [x] Clipboard restore race condition fix

### Export & Data
- [x] JSON export format
- [x] Batch export
- [x] Backup/restore (SQLite export/import)
- [x] Auto-cleanup retention setting
- [x] Usage statistics (Dashboard + Statistics tab)

### Audio & Performance
- [x] Configurable chunk size
- [x] LLM token limit configurable
- [x] Audio quality indicators (clipping detection)
- [x] Resume interrupted model downloads (HTTP Range)
- [x] Device hot-plug handling
- [x] Audio preprocessing (noise gate, pre-emphasis)
- [x] Filler word removal (uh, um, mmm, etc.)
- [x] Earlier incremental processing (2s instead of 5s)
- [x] Dynamic paragraph breaks (sentence-based)

### Customization
- [x] Custom modes with user-defined LLM prompts
- [x] Per-app mode defaults
- [x] Config profiles (save/load)

### Security
- [x] SQL injection fix (parameterized queries)
- [x] API keys in macOS Keychain
- [x] Model download size verification
- [x] ReDoS protection (pattern length limit)

### Concurrency & Correctness
- [x] Lock ordering documented
- [x] LLM lock released before network I/O
- [x] Standardized lock error handling
- [x] Recording state race condition fix
- [x] Overlap dedup punctuation fix
- [x] LLM truncation at sentence boundary

### Robustness
- [x] Swift test coverage (8 XCTests)
- [x] Better error surfacing
- [x] LLM timeout handling
- [x] LLM error messages with response body
- [x] LLM streaming (Ollama)
- [x] LLM retry logic (transient errors only)

### Database
- [x] Indexes on created_at, source
- [x] Composite index (source, created_at DESC)

### CI/CD & Build
- [x] PR testing workflow (cargo test, clippy, fmt, SwiftFormat)
- [x] Cargo release profile (LTO, codegen-units, strip)
- [x] Version single source of truth (VERSION file + sync script)
- [x] Changelog generation (git-cliff config)
- [x] Incremental swift-package builds

### Logging & Observability
- [x] Consolidated logging (file-based with rotation)
- [x] Performance metrics (os.signpost)
- [x] Debug mode toggle in Settings

### UI & Design
- [x] Redesigned recording overlay (draggable, animated, auto-resize)
- [x] Redesigned selection mode toolbar
- [x] Redesigned Behavior section (icon badges)
- [x] Dashboard tab with app info and quick stats
- [x] Statistics tab with extended metrics
- [x] Settings window widened for 6 tabs
- [x] Consistent icon colors across settings

### Accessibility
- [x] Respect Reduce Motion

### Documentation
- [x] Troubleshooting section in README
- [x] Contribution guide (CONTRIBUTING.md)
- [x] Swift doc comments

---

## Deferred (Future Consideration)

### macOS Integration
- [ ] Spotlight indexing of transcriptions
- [ ] Shortcuts.app support
- [ ] Share sheet integration
- [ ] Drag and drop from history
- [ ] Services menu

### Localization
- [ ] Localize 50+ hardcoded English strings

### CI/CD & Distribution
- [ ] Code signing / notarization
- [ ] Sparkle auto-update framework

### Logging
- [ ] Crash reporting (Sentry/Bugsnag)

### Accessibility
- [ ] VoiceOver support
