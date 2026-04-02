/// LLM provider trait and implementations.
///
/// LLM providers are used for post-processing transcribed text:
/// grammar correction, formatting, context-aware rewriting, etc.
pub mod anthropic;
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

impl LlmRequest {
    /// Format the optional application context into a human-readable string.
    /// Returns `None` if no context fields are set.
    pub fn format_context(&self) -> Option<String> {
        let ctx = self.context.as_ref()?;
        let mut parts = Vec::new();
        if let Some(app) = &ctx.app_name {
            parts.push(format!("Active application: {app}"));
        }
        if let Some(selected) = &ctx.selected_text {
            parts.push(format!("Selected text: {selected}"));
        }
        if parts.is_empty() {
            None
        } else {
            Some(format!("Context:\n{}", parts.join("\n")))
        }
    }
}

/// Trait that all LLM backends must implement.
pub trait LlmProvider: Send + Sync {
    /// Process text according to the system prompt and context.
    fn process(&self, request: &LlmRequest) -> Result<String, CoreError>;

    /// Provider name for display and logging.
    fn name(&self) -> &str;

    /// Whether the provider is currently reachable.
    fn is_available(&self) -> bool;
}
