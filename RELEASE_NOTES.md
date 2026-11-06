# Parakatt 0.7.5

This release fixes an immediate startup crash in 0.7.4. It keeps explicit WebGPU selection for Apple Silicon Macs, including M4.

## Changes

- Prevent an immediate crash when macOS returns the notification permission result on a background queue. Notification delivery callbacks can also run safely on a background queue.
- Check the normal app startup path, engine initialization, and notification callback before packaging a release.
- To use WebGPU, select **WebGPU** under **Settings > Models > Speech settings > Execution**, then click **Apply speech settings**. GPU initialization or inference failure still falls back to CPU. Automatic keeps its existing validation rules.

## Installation

- Requires Apple Silicon and macOS 14 or later. Speech models are downloaded explicitly in Settings.
- The app is ad-hoc signed and is not notarized by Apple. See the [installation instructions](https://github.com/asabla/parakatt#unsigned-builds) if Gatekeeper blocks it.
- Public YouTube downloads remain subject to site restrictions.

[Changes since 0.7.4](https://github.com/asabla/parakatt/compare/v0.7.4...v0.7.5)
