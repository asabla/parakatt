# Parakatt 0.7.3

This release fixes transcript loss at chunk boundaries, preserves multilingual words and saved corrections, and makes recording mode selection consistent.

## Changes

- Preserve new speech when a sentence crosses a chunk overlap. Live transcription checks word timing before grouping sentences.
- Preserve recognized multilingual words before dictionary rules and optional LLM processing. English filler expressions are no longer stripped automatically.
- Preserve dollar signs in plain dictionary replacements. Explicit `re:` rules retain capture expansion.
- Keep saved import corrections through pause, resume, restart, completion, and backup restoration. Undoing the first manual edit returns to the latest generated text; later edits and processing retries restore the preceding display text.
- Save the selected global mode and use the mode and application context captured at the start of each push-to-talk recording, including per-app defaults.
- Correct the meeting setting to describe microphone and system audio labels. All system audio is labelled `Speaker 1`; individual speakers are not identified.
- Include the experimental output-only file CLI in source. It supports bounded 16 kHz mono WAV and raw float input on macOS and Linux. It does not save history or use app settings, dictionary rules, or LLM processing. Build it from source as described in the README; the macOS app packages remain separate.

## Installation

- Requires Apple Silicon and macOS 14 or later. Speech models are downloaded explicitly in Settings.
- The app is ad-hoc signed and is not notarized by Apple. See the [installation instructions](https://github.com/asabla/parakatt#unsigned-builds) if Gatekeeper blocks it.
- Public YouTube downloads remain subject to site restrictions.

[Changes since 0.7.2](https://github.com/asabla/parakatt/compare/v0.7.2...v0.7.3)
