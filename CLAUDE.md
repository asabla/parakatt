# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
make all              # Full build: Rust → UniFFI Swift bindings → XcodeGen → Xcode build
make rust             # Build Rust core only: cargo build --release -p parakatt-core
make swift-package    # Generate UniFFI Swift bindings (requires cargo-swift)
make xcode            # Generate Xcode project from project.yml (requires xcodegen)
make build            # Debug build via xcodebuild
make release          # Release build via xcodebuild
make package          # Package as ZIP + DMG (requires create-dmg)
make run              # Run debug build with console output
make test             # Run Rust tests: cargo test
make test-integration # Run Parakeet integration test (requires downloaded model)
make download-model   # Download Parakeet TDT 0.6B v2 (~2.5GB from HuggingFace)
make clean            # Clean all build artifacts
```

**Build toolchain:** Rust, Xcode 16+, `xcodegen` (brew), `cargo-swift` (cargo install)

## Architecture

Swift+Rust hybrid macOS menu bar app. Rust handles compute-heavy work (STT, LLM), Swift handles macOS integration (audio capture, accessibility, UI).

**FFI boundary:** Rust exposes an `Engine` via UniFFI proc-macros (`#[uniffi::export]`). `cargo-swift` generates a Swift package (`ParakattCore/`) with an `.xcframework`. Swift side wraps this in `CoreBridge.swift`.

**Data flow:** Option+Space → AVAudioEngine captures 16kHz mono → release triggers Rust pipeline: audio preprocessing → Parakeet ONNX STT → dictionary replacements → optional LLM post-processing → text inserted via Accessibility API (with CGEvent/AppleScript fallbacks).

### Rust Core (`crates/parakatt-core/`)

- `engine.rs` — Main Engine orchestrating the STT→Dict→LLM pipeline
- `audio.rs` — Preprocessing (silence trimming, normalization)
- `stt/parakeet.rs` — NVIDIA Parakeet TDT via ONNX Runtime
- `llm/ollama.rs`, `llm/openai.rs` — LLM providers (Ollama, OpenAI-compatible)
- `dictionary.rs` — Regex-based post-STT replacements with context awareness
- `modes.rs` — Built-in modes (Dictation, Clean, Email, Code) with LLM prompts
- `config.rs` — TOML config persistence in `~/Library/Application Support/Parakatt/`
- `download.rs` — HuggingFace model streaming download with progress
- `lib.rs` — Public FFI types and `uniffi::setup_scaffolding!()`

### Swift App (`Parakatt/`)

- `AppState.swift` — Central `@ObservableObject` coordinating all services
- `CoreBridge.swift` — FFI wrapper around UniFFI-generated bindings
- `AudioCaptureService.swift` — AVAudioEngine with device enumeration and resampling
- `TextInsertionService.swift` — 3 paste strategies (Accessibility API → CGEvent → AppleScript)
- `HotkeyService.swift` — Option+Space hotkey via flag monitoring
- `ContextService.swift` — Captures focused app context via Accessibility API
- `MenuBarManager.swift` — NSStatusItem menu bar UI (LSUIElement app, no dock icon)

### Build System

- `project.yml` — XcodeGen config → generates `Parakatt.xcodeproj`
- Target: macOS 14.0+, Apple Silicon (aarch64)
- Swift dependencies: HotKey (0.2.1, via SPM)
- Entitlements: audio-input, apple-events automation, disable-library-validation (for Rust FFI)

## Config

Single TOML file at `~/Library/Application Support/Parakatt/config/config.toml` with sections: general, stt, llm, dictionary, modes.
