# Parakatt 0.7.0

This release adds video transcription, original-video playback, recording recovery, and improvements to models, meetings, and history.

## New features

- Import local MP4, MOV, MKV, and WebM files, direct HTTP/HTTPS links, and individual public YouTube videos. Select the audio track before transcription. Imports keep checkpoints and can resume after interruption.
- Play the original video in History with the bundled playback engine. Seek from transcript timestamps and use volume, speed, and transcript-follow controls. Export SRT and VTT subtitles.
- Review incomplete recordings, save recognized text, and retry retained audio. Temporary audio retention is optional, off by default, and limited to 24 hours and 512 MiB.
- Retry failed LLM processing, edit processed text, and undo the last edit. Recognized text and timestamps remain available.
- Search within transcripts with highlighted matches and keyboard navigation. History loads recordings in pages and keeps a bounded detail cache.
- Use Parakeet v3 for final recognition and an optional multilingual Nemotron 3.5 preview. Model downloads use pinned revisions and verify required files before activation. Validated systems can use WebGPU; CPU remains available.
- Meeting transcription has live transcript controls, pause/resume, capture status, and separate microphone/system-source labels when selected. These labels identify capture sources; they do not identify individual speakers within one source.
- Test a selected LLM model with a complete synthetic streaming request. Optional preceding-speech context stays off by default.

## Fixes and changes

- Preserve recognized text when speech or LLM processing fails. Incomplete recordings are not pasted automatically.
- Check microphone access before capture. Keep buffered audio while the model loads and report missing or silent input.
- Correct meeting chunk order, overlap, timestamps, and incomplete capture handling.
- Reduce unnecessary overlay updates. Manual scrolling pauses transcript following.
- Bundle yt-dlp, Deno, FFmpeg/ffprobe, and VLCKit. Users do not need separate media tools. Corresponding media source archives and license notices are included with this release.
- Reuse the launcher from the published 0.6.1 app to keep its executable identity. Add checks for app version, build number, dependency signatures, startup, and packaged video decoding.

## Installation and limits

- Requires Apple Silicon and macOS 14 or later. The speech model needs about 2.5 GB and is downloaded explicitly in Settings.
- The app is not signed with Developer ID or notarized by Apple. See the [installation instructions](https://github.com/asabla/parakatt#unsigned-builds) if Gatekeeper blocks it.
- Video imports do not support playlists, live streams, authenticated media, DRM media, or arbitrary website pages. YouTube availability can change.
- Playback requires the retained original video. Deleting app-owned media preserves the transcript.
- OpenAI, Anthropic, LM Studio, and Ollama require a configured model. Use **Test selected model** before enabling processing.

[All changes since 0.6.1](https://github.com/asabla/parakatt/compare/v0.6.1...v0.7.0)
