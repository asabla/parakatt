/// Anthropic LLM provider.
///
/// Connects to the Anthropic Messages API. Supports both regular API keys
/// (`x-api-key` header) and OAuth tokens from `claude setup-token`
/// (`Authorization: Bearer` header).
use crate::CoreError;

use super::{LlmProvider, LlmRequest};

pub struct AnthropicProvider {
    api_key: String,
    model: String,
    client: reqwest::blocking::Client,
}

impl AnthropicProvider {
    pub fn new(api_key: &str, model: &str) -> Self {
        Self {
            api_key: api_key.to_string(),
            model: model.to_string(),
            client: reqwest::blocking::Client::builder()
                .timeout(std::time::Duration::from_secs(60))
                .build()
                .expect("Failed to build HTTP client"),
        }
    }

    /// Returns true if the key is an OAuth token (from `claude setup-token`).
    fn is_oauth_token(&self) -> bool {
        self.api_key.starts_with("sk-ant-oat")
    }
}

impl LlmProvider for AnthropicProvider {
    fn process(&self, request: &LlmRequest) -> Result<String, CoreError> {
        let mut user_content = request.text.clone();

        if let Some(ctx_text) = request.format_context() {
            user_content = format!("{ctx_text}\n\n{user_content}");
        }

        log::info!(
            "[anthropic] Sending to LLM: model={}, text='{}', prompt='{}'",
            self.model,
            &request.text,
            &request.system_prompt.chars().take(80).collect::<String>()
        );

        let body = serde_json::json!({
            "model": &self.model,
            "max_tokens": 1024,
            "system": &request.system_prompt,
            "messages": [
                {
                    "role": "user",
                    "content": &user_content
                }
            ]
        });

        let mut req = self
            .client
            .post("https://api.anthropic.com/v1/messages")
            .header("anthropic-version", "2023-06-01")
            .header("content-type", "application/json")
            .json(&body);

        // OAuth tokens use Bearer auth; regular API keys use x-api-key
        if self.is_oauth_token() {
            req = req.header("Authorization", format!("Bearer {}", self.api_key));
        } else {
            req = req.header("x-api-key", &self.api_key);
        }

        let response = req
            .send()
            .map_err(|e| CoreError::LlmError(format!("Anthropic request failed: {e}")))?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().unwrap_or_default();
            return Err(CoreError::LlmError(format!(
                "Anthropic returned status {}: {}",
                status, body
            )));
        }

        let json: serde_json::Value = response
            .json()
            .map_err(|e| CoreError::LlmError(format!("Failed to parse Anthropic response: {e}")))?;

        // Anthropic Messages API returns: { "content": [{ "type": "text", "text": "..." }] }
        json["content"][0]["text"]
            .as_str()
            .map(|s| s.trim().to_string())
            .ok_or_else(|| CoreError::LlmError("Missing content in Anthropic response".into()))
    }

    fn name(&self) -> &str {
        "anthropic"
    }

    fn is_available(&self) -> bool {
        !self.api_key.is_empty()
    }
}

/// Hardcoded list of available Anthropic models.
/// Anthropic doesn't expose a /models endpoint.
pub fn available_models() -> Vec<String> {
    vec![
        "claude-haiku-4-5-20251001".to_string(),
        "claude-sonnet-4-5-20250514".to_string(),
        "claude-opus-4-20250514".to_string(),
    ]
}
