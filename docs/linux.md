# Linux desktop

The experimental Linux frontend uses Qt (PySide6) and generated UniFFI Python bindings to the same Rust `Engine` used by the Swift app. It does not maintain a separate transcription implementation or database schema. The first target is x86_64 Ubuntu 24.04+ and current Fedora with GNOME on Wayland. This is an initial desktop port, not a claim of complete macOS feature parity or a validated distribution release.

## Build and run

Install Python 3.12+, the Rust toolchain pinned in `rust-toolchain.toml`, a C/C++ compiler, Make, pkg-config, CMake, and OpenSSL development headers. The desktop needs FFmpeg/FFprobe, the PulseAudio command-line tools (also used with PipeWire), and a running desktop session. Qt and the downloader install into a project-local virtual environment.

Ubuntu:

```sh
sudo apt-get install python3-venv build-essential pkg-config cmake libssl-dev \
  ffmpeg pulseaudio-utils libegl1 libopengl0 libxcb-cursor0
```

Fedora:

```sh
sudo dnf install python3 python3-pip gcc gcc-c++ make pkgconf-pkg-config cmake \
  openssl-devel ffmpeg-free pulseaudio-utils mesa-libEGL mesa-libGL xcb-util-cursor
```

Codec availability depends on your distribution's FFmpeg packages. `ffmpeg-free` does not include every codec. YouTube imports also need a supported JavaScript runtime such as Deno on PATH; browser changes can require downloader updates.

```sh
make linux-desktop
target/linux-venv/bin/parakatt-desktop
```

`make linux-desktop` recreates its project-local virtual environment before installing the locked dependencies. This also replaces incomplete environments restored by build caches.

On x86_64 the build script downloads Microsoft's ONNX Runtime 1.28.0 release, checks the SHA-256 pinned in `config/linux-runtime.json`, and bundles its shared library and notices. `ORT_LIB_PATH` can select an existing matching runtime instead. Other architectures require an explicit compatible runtime and are not validated here. Python bindings are generated from an unstripped build; the installed library uses the release build. Wheels are architecture-specific and must be built on a compatible Linux baseline.

Model installation is explicit: open **Settings → Models → Manage downloads…**, select Parakeet v3, and choose **Download / repair**. An existing installation can be used with `--models-dir /path/to/models`. Use `--data-dir /path/to/isolated-data` for isolated testing. Offline dictation does not require any API credentials.

For a launcher in the application menu:

```sh
python3 scripts/install-linux-desktop.py
```

This creates a per-user launcher pointing at the project's virtual environment; keep that checkout and venv in place. It does not modify system packages or enable autostart.

## Desktop features

| Area | Linux implementation |
| --- | --- |
| Dictation | Mono 16 kHz microphone capture through FFmpeg's PulseAudio input, bounded chunk queue, shared dictionary and optional LLM processing |
| Preview | Buffered Parakeet preview; optional installed Nemotron streaming preview. Preview loss does not discard committed capture |
| Meetings | Separate transcription window, pause/resume and discard, selected microphone plus output monitor, optional **Me** / **Speaker 1** source labels |
| History | Split list/detail window, All/Notes/Meetings/Videos filters, full-text search, pagination, in-transcript find, editable processed text, recognized timeline, undo and retries |
| Export | Text, Markdown, SRT, and WebVTT; subtitle timing comes from recognized segments |
| Settings | Dashboard, General, Models, LLM, Dictionary and Statistics tabs; devices, processing modes, clipboard/overlay behavior, recovery and retention; profiles in Tools |
| Credentials | Provider-specific keys in Secret Service / GNOME Keyring; no plaintext fallback. Verified migration of legacy keys |
| Media | Local audio/video, multiple audio tracks, direct/YouTube links through yt-dlp, durable chunk checkpoints, pause/resume, source fingerprint checks |
| Playback | Qt multimedia plays the original source, with seeking, volume, speed, and sentence-to-time navigation |
| Recovery | Periodic audio checkpoints when enabled, retained interrupted drafts, recovery of committed text or saved audio |
| Backup | Shared Rust database export/import and retention cleanup |
| Desktop controls | Single-instance app, tray controls where supported, local Ctrl+Space, external `--toggle` and `--meeting` commands |

Imports run one at a time and yield to live capture between chunks. A changed source or changed processing configuration cannot silently resume an old import. Files imported from disk stay external; **Remove downloaded media** only removes files under Parakatt's own media directory. Removing a transcript does not delete external files. Database backups do not include source videos or downloaded speech models.

YouTube browser sign-in is selected for one attempt in **Parakatt → Imports…**. Sign into the browser first. Cookie access is handled by yt-dlp; the app does not save cookies or the browser selection in history or settings. Live streams, playlists, DRM, and non-media web pages are not a supported import contract.

## Interface and review screenshots

The Linux interface follows the supplied macOS references: compact history toolbar, blue selected list rows, processed text and timed timeline views, grouped settings, separate meeting controls, and a compact recording overlay. Linux keeps its own window decorations. Recording controls are in the **Parakatt** menu and tray where available; imports and recovery tools remain reachable in their own windows.

The **Meetings** filter includes imported Teams and Slack transcripts. **Videos** includes audio/video imports. The pencil enables editing; **Save changes** commits it, while background refreshes preserve an open edit. The transcript overflow menu exposes original recognized text, speaker corrections, meeting actions, undo, and retry. Ctrl+F focuses transcript find when an item is selected and history search otherwise. The selection control enables multiple selection and batch deletion.

The overlay uses measured microphone levels and does not request keyboard focus. Its visibility follows **General → Show recording overlay**. Closing the meeting window leaves capture running; Stop finishes and saves, while Discard confirms deletion of the active recording and its recovery data. Pause drains incoming audio without retaining it for recognition or recovery; the elapsed timer excludes paused time. Recognition may still finish processing audio captured before the pause.

[Review screenshots and reproduction instructions](linux-ux.md) cover the empty/selected history states, timeline, settings and recording controls. All preview transcripts are synthetic.

## GNOME and Wayland

In **GNOME Settings → Keyboard → View and Customize Shortcuts → Custom Shortcuts**, bind the absolute command printed by the installer, followed by `--toggle`. The `--meeting` command toggles meeting recording. The first invocation starts the app if needed. The shortcut is a toggle; hold-to-talk is not implemented.

Wayland text is copied to the clipboard; paste with Ctrl+V. Unrestricted synthetic keystrokes and focused-window inspection are not available to ordinary Wayland applications. Automatic paste is currently supported only on X11 with `xdotool`. There is no automatic per-application context/default-mode detection on Wayland. A future consent-based portal integration is needed for equivalent behavior on supported compositors.

GNOME does not show StatusNotifier tray icons by default. Install a compatible AppIndicator extension if tray controls are wanted; otherwise the app remains a normal window and closing it stops active work and quits. Meeting output capture uses an output monitor, not macOS-style per-application audio isolation. It requires PipeWire's PulseAudio compatibility service or PulseAudio itself. Headphones help avoid microphone feedback.

Linux inference currently uses CPU. WebGPU acceleration, macOS permission prompts, hold-to-talk, and automatic focused-app context are not ported. The desktop is not packaged as a signed AppImage, Flatpak, or native distribution package yet.

## Validation

```sh
make linux-test
QT_QPA_PLATFORM=offscreen PARAKATT_TEST_QT=1 make linux-test
PARAKATT_TEST_MODELS=/path/to/models PARAKATT_TEST_AUDIO=/path/to/short-speech.wav \
  make linux-test
target/linux-venv/bin/parakatt-desktop --diagnostics
```

The tests cover checkpoint overlap and pause/resume, changed-source rejection, bounded capture behavior, paths, subtitles, native settings persistence, actual recognition/history edits when a model is supplied, and recording lifecycle/recovery using an injected audio source. The Qt tests exercise category filters and pagination (including Teams/Slack classification), find/timeline navigation, explicit edit/save, settings persistence, clipboard use, separate panels, pause/discard, and original-video playback. CI builds the native bindings and runs these checks on Ubuntu, including real recognition from pinned speech fixtures.

Offscreen tests do not prove microphone access, output-monitor capture, browser-cookie access, GNOME shortcut handling, Wayland clipboard ownership, or visible video/audio playback. Verify those in a real logged-in GNOME session before treating the port as a daily-use replacement. No claim is made that Fedora, actual audio devices, or GNOME integration have been validated by the cloud tests.
