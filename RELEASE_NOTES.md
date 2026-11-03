# Parakatt 0.7.2

This release restores qualified automatic GPU speech recognition on the tested macOS build and keeps optional buffered preview from delaying queued transcription.

## Changes

- Enable automatic WebGPU for the verified Apple M3 Max, macOS 27.0.1 build `26A434`, four-thread configuration. Explicit CPU selection and CPU fallback remain available. Other combinations require their own validation.
- Skip buffered preview while required transcription is queued or the speech model is busy. End the preview session when Stop is pressed, reject stale results, and retry unchanged audio after a busy-model response. Inference already in progress can finish; it is not interrupted.
- Add isolated public-audio replay of the app's Stop-to-final-state path. Final text matched in all 120 before/after pairs. One Swedish CPU case with queued incremental work and preview fell from a 1.325 s median to 0.991 s; this is a diagnostic stress case, not a general latency guarantee.
- Select Python 3.13 in CI and repair incomplete media build environments before reuse.
- Keep the production speech model, native runtime, thread defaults, and stable launcher. Experimental native speech candidates remain outside the app.

## Installation and limits

- Requires Apple Silicon and macOS 14 or later. Speech models are downloaded explicitly in Settings.
- The app is ad-hoc signed and is not notarized by Apple. See the [installation instructions](https://github.com/asabla/parakatt#unsigned-builds) if Gatekeeper blocks it.
- The replay uses preloaded public audio, temporary data, and the normal processing queues. It does not test microphone or system-audio capture, paste, LLM processing, or physical display latency. The 600 ms capture drain remains unchanged.
- New checks on an actual macOS 14 system, live capture, installed-update permissions, and configured live LLM providers remain pending in the preparation report. The earlier 0.7.1 manual check does not establish those results for this candidate.
- Public YouTube downloads remain subject to site restrictions. The earlier build-host check was blocked by YouTube's bot check.

[Changes since 0.7.1](https://github.com/asabla/parakatt/compare/v0.7.1...v0.7.2)
