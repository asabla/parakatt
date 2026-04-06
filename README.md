# Parakatt

Local-first voice-to-text transcription for macOS. Lives in your menu bar, transcribes speech using [NVIDIA Parakeet](https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx) running entirely on-device, and pastes the result into whatever app you're using.

## Features

- Menu bar app with global hotkey (Option+Space) to start/stop recording
- On-device speech-to-text via Parakeet TDT 0.6B (ONNX Runtime)
- Meeting transcription with dual audio capture (microphone + system audio)
- Sentence-level timestamps with timeline navigation in transcription history
- Per-chunk LLM processing for responsive long-form transcription
- Optional LLM post-processing (Ollama, LM Studio, OpenAI, Anthropic)
- Dictionary rules for domain-specific word corrections
- Multiple transcription modes (dictation, clean, email, code)
- Transcription history with full-text search, markdown export with timestamps
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

Parakatt requires the following macOS permissions:

- **Microphone** — for capturing audio to transcribe
- **Accessibility** — for inserting transcribed text into other applications
- **Screen & System Audio Recording** (macOS 14.2+, optional) — for capturing system audio during meeting transcription

You'll be prompted to grant these when needed. They can be managed in **System Settings > Privacy & Security**.

## Configuration

Configuration is stored at `~/Library/Application Support/Parakatt/config/config.toml`. The default settings use dictation mode with auto-paste enabled.

LLM post-processing can be configured in the settings UI to use a local Ollama/LM Studio instance or a cloud provider (OpenAI, Anthropic).

## Unsigned Builds

If you download a release that hasn't been notarized by Apple, macOS Gatekeeper will block it. To open:

1. Right-click the app and select **Open**, then confirm in the dialog, or
2. Run `xattr -cr /Applications/Parakatt.app` in Terminal

This is standard for open-source macOS apps distributed outside the App Store.

## Troubleshooting

**"No audio captured" after recording**
- Check that Parakatt has Microphone permission in System Settings > Privacy & Security > Microphone
- If using Bluetooth headphones, try switching to the built-in microphone — some Bluetooth devices cause issues with AVAudioEngine

**Model download stalls or fails**
- The Parakeet model is ~2.5GB; ensure a stable internet connection
- If download fails partway, restart the app — it will skip already-downloaded files and resume
- Check Console.app for `[Parakatt]` logs for detailed error messages

**LLM post-processing not working**
- Use the "Test Connection" button in Settings > LLM to verify connectivity
- For Ollama: ensure the server is running (`ollama serve`) and the model is pulled (`ollama pull llama3.2`)
- For OpenAI: verify your API key is correct and has available credits
- Dictation mode skips LLM processing by design — switch to Clean, Email, or Code mode

**Meeting transcription: no system audio captured**
- System Audio Recording permission is required: System Settings > Privacy & Security > Screen & System Audio Recording
- On macOS 15+, only "System Audio Recording" is needed (not full Screen Recording)
- If a specific app is selected but not running, Parakatt falls back to all system audio

**Hotkey not working**
- Ensure Accessibility permission is granted in System Settings > Privacy & Security > Accessibility
- Option+Space may conflict with system input source switching — check System Settings > Keyboard > Shortcuts
- Hotkey may not work in full-screen apps or during Screen Time restrictions

**Text not pasted after recording**
- Parakatt needs Accessibility permission to insert text directly
- If paste fails, the transcription is still available in the menu bar and history
- Check that "Auto-paste transcription" is enabled in Settings > General

## License

[MIT](LICENSE)
