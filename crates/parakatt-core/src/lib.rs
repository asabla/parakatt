pub mod audio;
pub mod config;
pub mod dictionary;
pub mod download;
pub mod engine;
pub mod llm;
pub mod models;
pub mod modes;
pub mod session;
pub mod storage;
pub mod stt;

uniffi::setup_scaffolding!();

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

/// Result of a transcription + optional LLM processing pipeline.
#[derive(Debug, Clone, uniffi::Record)]
pub struct TranscriptionResult {
    pub text: String,
    pub duration_secs: f64,
    pub provider_name: String,
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

/// Top-level engine configuration passed from Swift on init.
#[derive(Debug, Clone, uniffi::Record)]
pub struct EngineConfig {
    pub models_dir: String,
    pub config_dir: String,
    pub active_stt_model: Option<String>,
    pub active_llm_provider: Option<String>,
    pub active_mode: String,
}
