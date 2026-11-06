# Parakatt 0.7.6

This release makes History easier to find, adds a Stop button to the recording popup, and fixes meeting audio capture for Slack and other apps with audio helper processes.

## Changes

- Place **Transcription History** directly below **Start Recording** and **Start Meeting Transcription** in the menu.
- Add a **Stop** button to the recording popup. It stops capture and completes transcription through the same path as the hotkey and menu command.
- Include the system-audio permission description required by macOS. Allow Parakatt's **System Audio Recording** permission when prompted at meeting start.
- Capture the selected app's audio helper processes as well as its main process. Update that selection if helpers start or restart, without switching to other apps' audio.
- Make the Core Audio callback safe on its audio queue under Swift 6, and improve missing-audio diagnostics.
- Keep the 0.7.5 startup fix and explicit WebGPU selection.

## Installation

- Requires Apple Silicon and macOS 14 or later. Speech models are downloaded explicitly in Settings.
- The app is ad-hoc signed and is not notarized by Apple. See the [installation instructions](https://github.com/asabla/parakatt#unsigned-builds) if Gatekeeper blocks it.
- Public YouTube downloads remain subject to site restrictions.

[Changes since 0.7.5](https://github.com/asabla/parakatt/compare/v0.7.5...v0.7.6)
