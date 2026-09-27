# Video import implementation and validation

Implemented on `codex/video-transcription`, 2026-09-26.

## Delivered behavior

- MP4, MOV, MKV, and WebM imports through file selection and drag-and-drop.
- Direct HTTP/HTTPS media downloads and individual public YouTube videos. Website authentication, playlists, live streams, and DRM remain excluded.
- Bundled yt-dlp 2026.08.19, matching EJS, Deno 2.9.7, FFmpeg 8.0.1, and dav1d 1.5.1. Exact sources and checksums are recorded in `config/media-tools.json`.
- One persistent import queue; bounded audio decoding; optional text processing with backpressure; live recording priority between import chunks.
- Atomic speech checkpoints with restart recovery, source fingerprints, explicit interruption states, and protection against changed source files.
- Imported-video History entries, native playback, compatible review copies, timeline seeking, playback speed, and follow controls.
- SRT/VTT export using recognized speech and model timestamps. Word timing is used before overlap removal so a sentence that crosses a chunk boundary does not cause new words to be discarded.
- Local source files stay external. Downloaded media and review copies are app-owned. Removing media preserves the transcript; deleting an import does not delete an external source.

## Checks performed

- Rust formatting and strict Clippy: passed.
- Full Rust suite: 195 passed; three ignored integration/documentation tests remain ignored.
- Swift suite: 47 passed, one existing interactive test skipped.
- New tests cover atomic checkpoint rollback, restart without duplicate text, timestamp offsets, changed-source rejection, silence, source deletion protection, native and fallback decoding, delayed audio, review-copy timing, subtitles, subprocess cancellation, shutdown recovery, and direct HTTP redirects/unknown lengths/invalid responses.
- Release application build, stable-launcher identity, helper signatures, native dependency inspection, and startup smoke: passed.
- Packaged runtime checks use isolated application data and a PATH containing only macOS system directories. All four helpers execute from the app bundle.
- A live public YouTube video downloaded successfully as best-available AV1 video plus Opus audio, merged to Matroska. The initial upstream test video was unavailable; the successful check used `jNQXAC9IVRw`. Live availability is not assumed by automated tests.
- The packaged application transcribed that 19.028-second video with the installed Parakeet model through WebGPU, producing four recognized segments and subtitle output.
- A 65-second repeated speech fixture completed through three chunks and produced 17 recognized segments. The source is from the repository's attributed FLEURS fixtures. This checks the media pipeline and chunk boundaries; it is not a new accuracy benchmark.
- A two-hour synthetic silent video completed through 258 chunks. The largest submitted audio block was 480,000 float samples (30 seconds). This run isolates decoding and checkpoint behavior and does not load the speech model.
- ZIP and separate corresponding-source archives were produced. A DMG was produced with the built-in macOS disk-image tool because the optional `create-dmg` build tool is not installed locally.

## Remaining release acceptance

These checks ran on an Apple Silicon Mac using macOS 27.0. Binary deployment targets were checked against macOS 14, but a clean macOS 14 installation was not available. A clean-machine installation test remains required before publishing.

Playback conversion and timing have automated coverage. The UI automation service timed out, so full manual interaction coverage for drag-and-drop, seeking, and live-recording priority has not been performed. The existing project has no Developer ID signing/notarization setup; this feature preserves its stable launcher and existing distribution policy.

Use `scripts/smoke-media.py` to repeat packaged transcription checks. Detailed local outputs are in the ignored `target/video-validation` directory. Downloaded test videos, source caches, model data, and transcript contents are not committed.

## Playback correction, 2026-09-27

Long videos that need conversion now show source checking, conversion percentage, finalization, and player loading separately. Conversion progress is read directly from the process pipe so it reaches the interface without waiting for a full buffer. A conversion with no advancing media timestamp for 120 seconds fails with a visible error. Player readiness has a separate 20-second deadline.

Each attempt has its own temporary output and cancellation token. Cancelled and superseded attempts cannot publish a player or overwrite the current attempt. Review copies are checked for duration and actual player readiness before publication and reuse; damaged copies are rebuilt. Compatible native sources remain usable without conversion.

The Swift suite passes 51 tests with one existing interactive test skipped. Added checks cover live progress before process exit, stalled conversion, cancellation, stale load results, specific error messages, corrupt-copy recovery, cached-copy reuse, native playback, and player readiness deadlines. The release package and startup checks pass.

Run `python3 scripts/smoke-media.py <app> <video> --playback --output <report.json>` for full-length packaged playback validation. This uses isolated metadata, converts the complete source if needed, checks decoded video frames after seeking to the beginning, middle, and end, then verifies cached reuse and the original source checksum. It does not transcribe the video or change the user's import. Video data and local diagnostic output stay outside Git.
