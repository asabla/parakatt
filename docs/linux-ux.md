# Linux interface alignment

The history, settings, meeting window, and recording overlay now follow the supplied macOS screenshots. This replaces the previous green sidebar/serif prototype with neutral dark surfaces, blue selection, compact controls, and system sans-serif text. Linux retains its native window controls; GNOME shortcut and Wayland clipboard limitations remain explicit.

## History

The top toolbar contains sidebar visibility, search, video/link imports and an additional-actions menu. All/Notes/Meetings/Videos filters sit above the list. The detail pane contains title/metadata, copy/export/actions/delete, processed text or recognized timeline, and find with previous/next navigation. Transcript and title edits require an explicit Save changes action.

Teams and Slack transcript imports appear under Meetings. Audio/video imports appear under Videos. Imported speaker corrections are reflected in both text and timeline. The extra menu retains original recognized text, speaker correction, confirmed meeting actions, undo and retry. Media playback remains available when a source is attached.

![Selected history and processed text](images/linux-desktop/history.png)

![Recognized timeline](images/linux-desktop/timeline.png)

![History without a selection](images/linux-desktop/history-empty.png)

## Settings

Dashboard, General, Models, LLM, Dictionary and Statistics form the top tab bar. Existing settings still persist through the shared engine. General contains shortcut guidance, processing mode, clipboard behavior, overlay, recovery, debug logging, source labels, audio devices, retention and custom modes. Model download controls, import management, backups, profiles and recovery are still reachable.

Unavailable saved audio devices and a saved preview-model identifier are retained when the device service or model catalog is unavailable.

![Dashboard](images/linux-desktop/dashboard.png)

![General settings](images/linux-desktop/general.png)

![Statistics](images/linux-desktop/statistics.png)

## Recording

Meetings have a separate window with elapsed time, source badge, processed/timeline selector, first-batch progress, Pause/Resume, Stop, and Discard. The overlay has the recording indicator, measured microphone level, Stop, shortcut hint, microphone and model status. It avoids requesting keyboard focus.

![Meeting transcription](images/linux-desktop/meeting.png)

![Compact recording overlay](images/linux-desktop/overlay.png)

## Reproducing the screenshots

Build the Linux native bindings and install the desktop dependencies first, then run:

```sh
QT_QPA_PLATFORM=offscreen PYTHONPATH=linux \
  target/linux-venv/bin/python -m parakatt_linux.preview --output target/linux-ui-preview
```

The preview uses a temporary database and synthetic office conversations. Recording states are staged without opening audio devices; the meter remains at zero. These are actual Qt widget captures, without window-manager decorations. They demonstrate layout, not hardware recording or GNOME integration.

Behavioral tests cover filtering/pagination, find and timeline navigation, edit persistence, settings tabs and saved unavailable devices, separate windows, chronological live segments, paused-audio exclusion, timer pause accounting, discard cleanup, and original-source video decoding/seeking. Real recognition uses an injected audio fixture. Actual GNOME Wayland focus, clipboard, global shortcuts, audio devices, output monitors and window placement still require a logged-in desktop check.


## Follow-up workflows

The utility views retain the same neutral dark surfaces, blue selection and compact system controls. Dictionary rules have a searchable list and a focused, shared-validator-backed editor. Processing modes use a multiline prompt editor. Models and LLM settings group related controls; the download window distinguishes the main recognizer from preview models and only enables relevant actions. Tools separates backups/profiles, recovery and diagnostics.

Transcript imports now show a read-only preview with original source labels, timing and a complete selected passage before anything is saved. Teams has connection, account and transcript selection; Slack has workspace, accessible Huddle-source and known-file-ID selection. Permission descriptions appear during setup. These views do not infer speakers or connect an account automatically.

[Workflow captures](images/linux-workflows/) include transcript preview, Teams/Slack source selection, connection setup, Dictionary and its editor, mode editor, Models/LLM settings, downloads, and all three Tools tabs. Account/source examples are synthetic and explicitly labeled; they demonstrate layout rather than live integration access.

Reproduce after building the native bindings:

```sh
QT_QPA_PLATFORM=offscreen PYTHONPATH=linux \
  target/linux-venv/bin/python -m parakatt_linux.preview_workflows \
  --output target/linux-workflow-preview
```

The renderer uses a temporary database and sample office text. It does not authenticate, download models or open capture devices.

## ChatGPT and unified cleanup

The General and LLM tabs use the macOS cleanup labels while retaining stable shared-engine mode names. ChatGPT account controls reuse the core's browser sign-in and account/model APIs. Available models, permission status and usage pauses come from that account; OpenAI API remains a separate provider.

[Cleanup and ChatGPT captures](images/linux-cleanup/) show the real Qt settings with a signed-out fixture. No account is connected and no account storage is read. Reproduce them with:

```sh
QT_QPA_PLATFORM=offscreen PYTHONPATH=linux \
  target/linux-venv/bin/python -m parakatt_linux.preview_cleanup \
  --output target/linux-cleanup-preview
```
