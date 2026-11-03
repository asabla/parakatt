# Parakatt 0.7.1

This maintenance release updates dependencies and corrects media build caching.

## Changes

- Update bundled yt-dlp to 2026.10.26, Deno to 2.9.8, FFmpeg/ffprobe to 9.0.2, and dav1d to 1.5.4. Matching sources and notices ship with the release.
- Update Rust to 1.99.1 and refresh locked libraries, including SQLite, SHA-256, Tokio, and TOML support.
- Rebuild dav1d when its pinned version changes. Replace stale media-tool sources and notices while retaining the separate playback sources.
- Complete buffered-preview state updates on the main queue for current Xcode compatibility.
- Keep the existing speech runtime, model selection, and stable launcher. UniFFI remains matched to the Swift binding generator.

## Installation and limits

- Requires Apple Silicon and macOS 14 or later. Speech models are downloaded explicitly in Settings.
- The app is ad-hoc signed and is not notarized by Apple. See the [installation instructions](https://github.com/asabla/parakatt#unsigned-builds) if Gatekeeper blocks it.
- Public YouTube downloads remain subject to site restrictions. The live check from the build host was blocked by YouTube's bot check; local video transcription and playback passed.
- The refreshed Rust dependency audit reports no known vulnerabilities. Informational unmaintained-package warnings remain for `basic-toml` and `paste`.
- New checks on an actual macOS 14 system, live capture, installed-update permissions, and configured live LLM providers remain pending in the preparation report. Local checks do not establish those results.

[Changes since 0.7.0](https://github.com/asabla/parakatt/compare/v0.7.0...v0.7.1)
