# Parakatt

Local-first voice-to-text transcription for macOS. Lives in your menu bar, transcribes speech using [NVIDIA Parakeet](https://huggingface.co/istupakov/parakeet-tdt-0.6b-v2-onnx) running entirely on-device, and pastes the result into whatever app you're using.

## Features

- Menu bar app with global hotkey (Option+Space) to start/stop recording
- On-device speech-to-text via Parakeet TDT 0.6B (ONNX Runtime)
- Optional LLM post-processing (Ollama, LM Studio, OpenAI, Anthropic)
- Dictionary rules for domain-specific word corrections
- Multiple transcription modes (dictation, etc.)
- Auto-paste transcribed text into the active application

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon (ARM64)
- ~2.5 GB disk space for the speech recognition model (downloaded on first launch)

## Installation

### Download

Download the latest `.dmg` from [GitHub Releases](https://github.com/asabla/parakatt/releases), open it, and drag Parakatt to your Applications folder.

### Homebrew

```bash
brew tap asabla/tap
brew install --cask parakatt
```

### Build from Source

You'll need: Rust, [XcodeGen](https://github.com/yonaskolb/XcodeGen), [cargo-swift](https://github.com/nicklimmern/cargo-swift), and Xcode 16+.

```bash
# Install build tools
brew install xcodegen
cargo install cargo-swift

# Build everything
make all

# Run the app
make run
```

## Permissions

Parakatt requires two macOS permissions:

- **Microphone** — for capturing audio to transcribe
- **Accessibility** — for inserting transcribed text into other applications

You'll be prompted to grant these on first launch. They can be managed in **System Settings > Privacy & Security**.

## Configuration

Configuration is stored at `~/Library/Application Support/Parakatt/config/config.toml`. The default settings use dictation mode with auto-paste enabled.

LLM post-processing can be configured in the settings UI to use a local Ollama/LM Studio instance or a cloud provider (OpenAI, Anthropic).

## Unsigned Builds

If you download a release that hasn't been notarized by Apple, macOS Gatekeeper will block it. To open:

1. Right-click the app and select **Open**, then confirm in the dialog, or
2. Run `xattr -cr /Applications/Parakatt.app` in Terminal

This is standard for open-source macOS apps distributed outside the App Store.

## License

[MIT](LICENSE)
