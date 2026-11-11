//! Optional text processing; never opens the storage-owning Engine.
use parakatt_core::{
    llm::{LlmProvider, LlmRequest},
    CoreError,
};
use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct Processing {
    pub provider: &'static str,
    pub model: String,
    pub status: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub processed_text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ProcessingError>,
}
#[derive(Debug, Serialize)]
pub struct ProcessingError {
    pub code: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
}

pub fn process(
    text: &str,
    model: &str,
    mode: &str,
    provider: Result<&dyn LlmProvider, CoreError>,
) -> Processing {
    let result = provider.and_then(|provider| {
        let modes = parakatt_core::modes::default_modes();
        let prompt = parakatt_core::modes::find_mode(&modes, mode)
            .and_then(|m| m.system_prompt.clone())
            .ok_or_else(|| CoreError::ConfigError("Select clean, email, or code".into()))?;
        provider.process(&LlmRequest {
            preceding_text: None,
            allow_preceding_context: false,
            text: text.into(),
            system_prompt: prompt,
            context: None,
        })
    });
    match result {
        Ok(text) => Processing {
            provider: "chatgpt",
            model: model.into(),
            status: "completed",
            processed_text: Some(text),
            error: None,
        },
        Err(error) => {
            let (code, message, request_id) = match error {
                CoreError::ChatGptError {
                    code,
                    message,
                    request_id,
                    ..
                } => (code, message, request_id),
                _ => (
                    "processing_failed".into(),
                    "Text processing failed. Recognized text was kept.".into(),
                    None,
                ),
            };
            Processing {
                provider: "chatgpt",
                model: model.into(),
                status: "failed",
                processed_text: None,
                error: Some(ProcessingError {
                    code,
                    message,
                    request_id,
                }),
            }
        }
    }
}
