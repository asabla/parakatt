pub mod audio;
pub mod config;
pub mod dictionary;
pub mod download;
pub mod engine;
pub mod filler;
pub mod llm;
pub mod local_agreement;
pub mod models;
pub mod modes;
pub mod session;
pub mod storage;
pub mod stt;
pub mod vad;

uniffi::setup_scaffolding!();

/// Initialize the Rust core's logger so `log::info!` / `log::warn!` /
/// `log::error!` calls actually reach somewhere a human can read.
///
/// Without this, `env_logger` is in `Cargo.toml` but no `Log`
/// implementation is registered, so every log call inside the core is
/// silently dropped — which was the original reason issue #23 was
/// invisible: the storage failures *were* being logged via
/// `log::warn!`, but those messages went into the void.
///
/// Output goes to stderr. For terminal launches that lands in the
/// terminal directly; for bundled `.app` launches macOS captures it
/// into the unified logging system, where it's visible in Console.app
/// alongside the Swift `NSLog` lines (filter on the process name).
///
/// Safe to call multiple times — the underlying `try_init` is a no-op
/// if a logger has already been installed (e.g. during tests).
///
/// `default_level` is one of `"error"`, `"warn"`, `"info"`, `"debug"`,
/// `"trace"`. The `RUST_LOG` env var, if set, overrides it. If
/// `default_level` is `None` we default to `"info"`.
#[uniffi::export]
pub fn init_logging(default_level: Option<String>) {
    let level = default_level.as_deref().unwrap_or("info");
    let env = env_logger::Env::default().default_filter_or(level);
    let _ = env_logger::Builder::from_env(env)
        .format_timestamp_millis()
        .format_module_path(false)
        .target(env_logger::Target::Stderr)
        .try_init();
    log::info!("parakatt-core logger initialized (level={level})");
}

/// Errors exposed across the FFI boundary.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("Model not found: {0}")]
    ModelNotFound(String),
    #[error("Failed to load model: {0}")]
    ModelLoadFailed(String),
    #[error("Transcription failed: {0}")]
    TranscriptionFailed(String),
    #[error("LLM processing error: {0}")]
    LlmError(String),
    #[error("Configuration error: {0}")]
    ConfigError(String),
    #[error("Audio processing error: {0}")]
    AudioError(String),
    #[error("IO error: {0}")]
    IoError(String),
}

/// A sentence-level timestamp segment from STT.
#[derive(Debug, Clone, uniffi::Record)]
pub struct TimestampedSegment {
    pub text: String,
    /// Start time in seconds relative to the audio start.
    pub start_secs: f64,
    /// End time in seconds relative to the audio start.
    pub end_secs: f64,
}

/// Output of one `feed_streaming_chunk` call.
///
/// Pre-baked by the LocalAgreement-2 commit policy on the Rust side
/// so the UI doesn't have to re-implement it in Swift.
#[derive(Debug, Clone, uniffi::Record)]
pub struct StreamingChunkResult {
    /// Full committed transcript so far. Stable — never revised.
    pub committed_text: String,
    /// The tail that hasn't reached LA-2 agreement yet. Render in
    /// lighter style; this slice can change on every update.
    pub tentative_text: String,
    /// Just the tokens that became committed this call. Useful for
    /// callers that want to do something on every "stable word"
    /// event (e.g. typewriter UI animation, telemetry).
    pub newly_committed_text: String,
}

/// Result of a transcription + optional LLM processing pipeline.
#[derive(Debug, Clone, uniffi::Record)]
pub struct TranscriptionResult {
    pub text: String,
    pub duration_secs: f64,
    pub provider_name: String,
    /// Sentence-level timestamp segments from STT.
    pub segments: Vec<TimestampedSegment>,
    /// If the LLM post-processing step failed (after retries), this
    /// holds the last error message and `text` is the raw STT output.
    /// `None` means LLM either succeeded or wasn't configured for this mode.
    pub llm_error: Option<String>,
}

/// Context about the currently focused application, passed from Swift.
#[derive(Debug, Clone, Default, serde::Serialize, uniffi::Record)]
pub struct AppContext {
    pub app_bundle_id: Option<String>,
    pub app_name: Option<String>,
    pub selected_text: Option<String>,
    pub window_title: Option<String>,
}

/// A dictionary replacement rule exposed to Swift.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct ReplacementRule {
    pub pattern: String,
    pub replacement: String,
    /// One of: "always", "in_app", "when_mode"
    pub context_type: String,
    /// Bundle ID or mode name, depending on context_type.
    pub context_value: Option<String>,
    pub enabled: bool,
}

/// Configuration for a processing mode.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct ModeConfig {
    pub name: String,
    pub stt_provider: Option<String>,
    pub llm_provider: Option<String>,
    pub system_prompt: Option<String>,
    pub dictionary_enabled: bool,
}

/// Metadata about a downloadable/available model.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ModelInfo {
    pub id: String,
    /// "whisper" or "parakeet"
    pub provider_type: String,
    pub display_name: String,
    pub description: Option<String>,
    pub size_bytes: u64,
    pub downloaded: bool,
}

/// Hotkey configuration exposed via FFI.
#[derive(Debug, Clone, uniffi::Record)]
pub struct HotkeyConfig {
    /// Key name (e.g. "space", "r", "f1").
    pub key: String,
    /// Modifier names (e.g. ["option"], ["command", "shift"]).
    pub modifiers: Vec<String>,
    /// Mode: "hold" or "toggle".
    pub mode: String,
}

/// Top-level engine configuration passed from Swift on init.
#[derive(Debug, Clone, uniffi::Record)]
pub struct EngineConfig {
    pub models_dir: String,
    pub config_dir: String,
    pub active_stt_model: Option<String>,
    pub active_llm_provider: Option<String>,
    pub active_mode: String,
}
