/// LLM provider trait and implementations.
///
/// LLM providers are used for post-processing transcribed text:
/// grammar correction, formatting, context-aware rewriting, etc.
pub mod http;
pub mod ollama;
pub mod openai;

use crate::CoreError;

/// Request to an LLM provider for text processing.
#[derive(Debug, Clone)]
pub struct LlmRequest {
    /// The transcribed text to process.
    pub text: String,
    /// System prompt defining the processing behavior.
    pub system_prompt: String,
    /// Optional context about the focused application.
    pub context: Option<crate::AppContext>,
}

/// Trait that all LLM backends must implement.
pub trait LlmProvider: Send + Sync {
    /// Process text according to the system prompt and context.
    fn process(&self, request: &LlmRequest) -> Result<String, CoreError>;

    fn process_cancellable(
        &self,
        request: &LlmRequest,
        cancellation: &tokio_util::sync::CancellationToken,
        _observer: &(dyn Fn(&str) + Send + Sync),
    ) -> Result<String, CoreError> {
        if cancellation.is_cancelled() {
            return Err(CoreError::LlmError("Request cancelled".into()));
        }
        self.process(request)
    }

    /// Provider name for display and logging.
    fn name(&self) -> &str;

    /// Whether the provider is currently reachable.
    fn is_available(&self) -> bool;
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct LlmSettings {
    pub provider: String,
    pub base_url: String,
    pub model: String,
}
#[derive(Debug, Clone, uniffi::Record)]
pub struct LegacyCredential {
    pub profile: Option<String>,
    pub account: String,
    pub provider: String,
    pub api_key: String,
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, uniffi::Record)]
#[serde(default)]
pub struct GenerationSettings {
    pub output_limit: u32,
    pub keep_alive: String,
    pub think: Option<bool>,
    pub thinking_level: Option<String>,
}
impl Default for GenerationSettings {
    fn default() -> Self {
        Self {
            output_limit: 4096,
            keep_alive: "5m".into(),
            think: None,
            thinking_level: None,
        }
    }
}
