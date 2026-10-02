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
- ~2.5 GB disk space for the speech recognition model (downloaded explicitly in Settings)

## Installation

### Download

Download the latest `.dmg` from [GitHub Releases](https://github.com/asabla/parakatt/releases), open it, and drag Parakatt to your Applications folder.

### Homebrew

```bash
brew tap asabla/tap
brew install --cask parakatt
```

### Build from Source

Use the Rust version in `rust-toolchain.toml`. You also need [XcodeGen](https://github.com/yonaskolb/XcodeGen), [cargo-swift](https://github.com/nicklimmern/cargo-swift), and Xcode 16+. The release package targets Apple Silicon and macOS 14.

```bash
# Install build tools
./scripts/install-xcodegen.sh  # XcodeGen 2.46.0
export PATH="/tmp/parakatt-xcodegen/.build/release:$PATH"
cargo install cargo-swift --version 0.11.1 --locked --root target/tools

# Build everything
make all

# Run the app
make run
```

`make run` and `make run-detached` install the checked-in stable launcher before starting the app. Microphone permission is checked when recording starts. If macOS asks for access, grant it and start recording again. Use **Input Device > MacBook Pro Microphone** to test the built-in microphone explicitly; **System Default** follows macOS, including connected headsets.

Make prefers tools in `target/tools/bin` and uses `target/xcode` for Xcode build output. This keeps generated bindings separate from older global Xcode artifacts. Set `PARAKATT_DERIVED_DATA` to use a different build directory.

## Permissions

Parakatt requires the following macOS permissions:

- **Microphone** — for capturing audio to transcribe
- **Accessibility** — for inserting transcribed text into other applications
- **Screen & System Audio Recording** (macOS 14.2+, optional) — for capturing system audio during meeting transcription

You'll be prompted to grant these when needed. They can be managed in **System Settings > Privacy & Security**.

## Configuration

Configuration is stored at `~/Library/Application Support/Parakatt/config/config.toml`. The default settings use dictation mode with auto-paste enabled.

Select speech models and execution settings in **Settings > Models**. Downloads use pinned revisions and verify every required file. Parakeet v3 produces the final transcript. Nemotron 3.5 is an optional multilingual preview; select English, Swedish, or Automatic language detection. New preview downloads do not change an existing selection.

Automatic execution uses WebGPU only for combinations in `crates/parakatt-core/backend-validation.json`. Other systems use CPU. CPU remains available as an explicit setting and as a fallback. See [maintenance validation](reports/maintenance/README.md) for measured results and limits.

Configure optional LLM processing in **Settings > LLM**. Ollama and LM Studio run locally. OpenAI and Anthropic require a model and a provider-specific Keychain credential. They remain disabled until configured. Recognized text appears first; completed processing replaces each accepted chunk. Failures and queue limits preserve recognized text. History keeps the recognized timeline separate from processed text.

Use **Test selected model** in LLM settings to check the connection, authentication, selected model, and a complete synthetic streaming response. The test does not send a recording. **Use preceding speech as context** is optional and off by default. When enabled, it supplies up to 120 words from the two preceding recognized chunks of the same source and session. The original text remains available.

For reproducible benchmarks, fixture attribution, and release checks, see [the validation commands](reports/maintenance/README.md).

For version preparation, packaging, publication, and Homebrew updates, see [the release process](docs/releasing.md).

## Recording recovery and corrections

History marks a recording as incomplete if speech recognition fails. An incomplete recording is not pasted into another app. Use **Review recovery** in History to save the available recognized text or retry retained audio. The text is saved after each submitted speech chunk. With temporary audio retention enabled, audio checkpoints start at capture, including while the speech model loads. Recovery can restore audio through the last completed checkpoint. A process exit can lose pending writes (up to two seconds of mono audio).

Temporary audio retention is off by default. Enable it in Settings only if you want audio recovery. Successful recordings remove their recovery records immediately. Temporary audio expires after 24 hours when the app next accesses recovery data, with a total retention limit of 512 MiB. Turning the setting off clears retained audio. Backups include recognized recovery text, but exclude temporary audio. If capture writes or speech processing cannot keep up with their bounded queues, recording stops and remains marked incomplete.

In the history detail menu, use **Retry failed processing** to process failed LLM sections again. **Edit processed text** changes the display and export text. The original recognized text and timestamps remain available. **Undo last text change** restores the previous display text. Copy uses the selected transcript view.

History loads 100 recordings per page. Use **Load more recordings** to browse older entries. Query failures show a retry action. Use **Cmd+Shift+F** to search within a transcript and **Cmd+G** / **Cmd+Shift+G** to move between matches. **Cmd+F** searches recording history.

The recording overlay shows the actual input device, model readiness, and missing or silent input. Scrolling pauses automatic following; **Follow live** returns to the latest text. Stop instructions follow the configured hold or toggle shortcut. Normal logs contain character counts, not transcript text.

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
- If the selected app is not running, start it and select it again, or explicitly select all system audio. Parakatt does not expand capture automatically.

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

## Video imports

Use **Import Video…** or **Import Link…** in the menu or History. The import window also accepts dropped MP4, MOV, MKV, and WebM files. Select an audio track when the video has more than one. Imports use Dictation by default; Clean uses the configured LLM provider.

Direct HTTP/HTTPS links must return a video file. Public, finite YouTube videos are supported, including Shorts. Other website pages, playlists, live streams, authenticated videos, and DRM are not supported. YouTube downloads select the best available video and audio. Website changes can require a Parakatt update.

Parakatt bundles its media tools: users do not need Homebrew, Python, Deno, FFmpeg, or VLC installed. The existing speech model setup in Settings is still required. Once the model is available, local imports and retained-video playback work offline.

Imports run one at a time and yield between audio chunks to live recording. Pause keeps committed speech and timestamps; Resume validates the source and continues at the next checkpoint. Closing the app marks unfinished work as interrupted. Interrupted downloads start again; completed downloads are reused. Keep the same model and processing settings when resuming. A file changed during transcription requires a new import.

Local files stay in place. Use **Locate File…** if a source moves. Downloaded videos remain in Parakatt's application data until you remove them. **Remove Downloaded Media** preserves the transcript. Deleting an import removes its transcript and app-owned media but never deletes an external source file. Database backups preserve transcripts and import metadata, not media files; locate missing source media after restoring.

In History, use **Load Video** to play the original video with the bundled VLCKit engine. MP4, MOV, MKV, and WebM playback does not need a conversion or a separate playback copy. This also applies to existing imports; old review copies are ignored. Source checking and player loading show progress and can be cancelled. A player that cannot open the file reports an error after a bounded wait. Playback uses the audio track selected for transcription. In the recognized timeline, click a sentence to seek to it. Playback has play/pause, seeking, volume, speed selection, and optional transcript following. The transcript remains available when its video is missing.

Export SRT or WebVTT subtitles from History. Subtitles use recognized sentence timing, not LLM-rewritten text. The export dialog identifies incomplete transcripts. Automatic identification of individual speakers is not included.

### Building bundled media tools

`make media-tools` requires Python 3.12 or later on the build machine and prepares the checksum-pinned tools listed in `config/media-tools.json`. The build downloads standalone yt-dlp (including EJS) and Deno, and builds FFmpeg with dav1d for AV1 decoding. Build-only Meson and Ninja versions are pinned in the preparation script. FFmpeg disables GPL, nonfree, and host-library auto-detection. Audio extraction remains separate from video playback.

The same target prepares VLCKit 3.7.3 from the official VideoLAN binary archive pinned in `config/playback-engine.json`. It retains the arm64 slice, sets its dynamic-library install name to `@rpath`, and signs the framework. The app embeds it in `Contents/Frameworks`. No player download or installation is required at runtime. The pinned VLCKit/libVLC sources, patches, and contrib source archives are included in the media source package; their notices ship in the app. The source package explains how to rebuild or replace the dynamically linked framework.

`make xcode`, `make build`, and `make release` prepare these tools automatically. Xcode copies the executables into the app's Helpers directory and notices into Resources. Runtime calls use absolute bundled paths, ignore user downloader configuration, and disable tool self-updates and remote component installation. Update the tool lock and release Parakatt to update these dependencies.

Release packages include a separate `*-media-sources.zip` with corresponding source archives, build options, and preparation instructions. The stable launcher is unchanged. Developer ID signing and notarization remain separate from this feature.

Run the packaged media check with:

```bash
python3 scripts/smoke-media.py /path/to/Parakatt.app /path/to/video.mp4 \
  --models "$HOME/Library/Application Support/Parakatt/models"
```

The check uses isolated application data and a system-only PATH. It runs the bundled tools, decodes media in bounded chunks, transcribes it, saves History, and creates subtitle output. It reports counts, not transcript text.

To check direct playback without running transcription:

```bash
python3 scripts/smoke-media.py /path/to/Parakatt.app /path/to/video.mkv --playback
```

This check verifies the original source path, displayed frames after seeks at the start, middle, and end, reloading, and source integrity. It fails if a playback copy is created.

On a test host without an accelerated display, add `--headless` to validate decoded frames and seeking. The report identifies this as `video_output: headless`; it does not prove display rendering. CI uses this mode, and `TEST_RUNNER_PARAKATT_TEST_HEADLESS_PLAYBACK=1` selects it when running playback unit tests through `xcodebuild`. Run the command without `--headless` on a Mac to verify displayed frames. Normal History playback always uses the window renderer.
