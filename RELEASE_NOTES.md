# Parakatt 0.7.4

This release lets you select WebGPU on other Apple Silicon Macs, including M4. It also includes fixes for imports, saved settings, and recording state.

## Changes

- Select **WebGPU** under **Settings > Models > Speech settings > Execution**, then click **Apply speech settings** to try GPU acceleration. The app no longer requires your Mac and macOS build to appear in its validation list for this explicit selection.
- Use CPU automatically if WebGPU initialization or inference fails. Settings shows the backend in use. The encoder uses WebGPU; the decoder and Nemotron streaming preview use CPU.
- Keep **Automatic** restricted to combinations with recorded validation results. Explicit WebGPU selection does not imply that the hardware has passed the same accuracy and performance checks.
- Restore YouTube link imports with an optional, explicitly selected browser session. Request browser-folder access when macOS requires it, and report access failures.
- Preserve dictionary rules, saved settings, recovery audio, and transcript history when saving or processing fails.
- Keep recording controls, hotkey events, and clipboard restoration consistent.

## Installation

- Requires Apple Silicon and macOS 14 or later. Speech models are downloaded explicitly in Settings.
- The app is ad-hoc signed and is not notarized by Apple. See the [installation instructions](https://github.com/asabla/parakatt#unsigned-builds) if Gatekeeper blocks it.
- Public YouTube downloads remain subject to site restrictions.

[Changes since 0.7.3](https://github.com/asabla/parakatt/compare/v0.7.3...v0.7.4)
