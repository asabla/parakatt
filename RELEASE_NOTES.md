# Parakatt 0.8.0

Parakatt 0.8.0 adds optional ChatGPT plan text cleanup, imports for Microsoft Teams and Slack Huddle transcripts, and an experimental Linux desktop.

## macOS

- In **Settings > LLM**, select **ChatGPT plan** to sign in, choose a model, and apply it for optional text cleanup. Speech recognition runs on your device. ChatGPT receives transcript text when you enable cleanup with this provider. Plan access and model availability depend on your account.
- Choose **Off**, **Punctuation**, or **Grammar + punctuation** for text cleanup. Punctuation rejects changes to words or numbers. History keeps the original recognized text and timestamps if cleanup fails.
- The recording overlay stays visible while Parakatt finishes transcription.
- Select **Import Transcript…** in the menu bar to add a Teams WebVTT file or a supported Slack Huddle JSON file to Transcription History.
- Imports keep source speaker labels and any timestamps in the file. Importing the same transcript again keeps your saved edits. Transcript import does not need a speech model or send text to an LLM.

## Linux preview

- Build the desktop app from source for local dictation, meeting capture, searchable history, and audio and video imports. See the [Linux build guide](https://github.com/asabla/parakatt/blob/v0.8.0/docs/linux.md).
- Preview transcript text, speaker labels, and timing before saving. The preview supports local files and read-only retrieval from configured Teams and Slack accounts. Live account access and Slack transcript formats still need verification in real workspaces.
- Correct speaker labels in a transcript, record confirmed action items with supporting quotes, and export meeting notes as Markdown. Speaker labels come from the source or your corrections. Parakatt does not identify voices.
- Linux uses CPU inference. On Wayland, paste from the clipboard manually. The preview has no Linux installer, and live GNOME/Wayland integration is still unverified.

## Experimental file CLI

The CLI is built from source for macOS and Linux. It can use a connected ChatGPT plan for text cleanup when you request it. See the [CLI guide](https://github.com/asabla/parakatt/blob/v0.8.0/README.md#chatgpt-plan-in-the-cli).

## Installation

- The macOS download requires Apple Silicon and macOS 14 or later. Download speech models in Settings to transcribe audio.
- The macOS app is ad-hoc signed and is not notarized by Apple. See the [installation instructions](https://github.com/asabla/parakatt#unsigned-builds) if Gatekeeper blocks it.
- Public YouTube downloads remain subject to site restrictions.

[Changes since 0.7.6](https://github.com/asabla/parakatt/compare/v0.7.6...v0.8.0)
