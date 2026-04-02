/// Ollama LLM provider.
///
/// Connects to a locally running Ollama instance via its HTTP API
/// at localhost:11434 (default).
use crate::CoreError;

use super::{LlmProvider, LlmRequest};

pub struct OllamaProvider {
    base_url: String,
    model: String,
    client: reqwest::blocking::Client,
}

impl OllamaProvider {
    pub fn new(base_url: &str, model: &str) -> Self {
        Self {
            base_url: base_url.trim_end_matches('/').to_string(),
            model: model.to_string(),
            client: reqwest::blocking::Client::builder()
                .timeout(std::time::Duration::from_secs(60))
                .build()
                .expect("Failed to build HTTP client"),
        }
    }
}

impl LlmProvider for OllamaProvider {
    fn process(&self, request: &LlmRequest) -> Result<String, CoreError> {
        let mut messages = vec![serde_json::json!({
            "role": "system",
            "content": &request.system_prompt
        })];

        if let Some(ctx_text) = request.format_context() {
            messages.push(serde_json::json!({
                "role": "system",
                "content": ctx_text
            }));
        }

        messages.push(serde_json::json!({
            "role": "user",
            "content": &request.text
        }));

        let body = serde_json::json!({
            "model": &self.model,
            "messages": messages,
            "stream": false,
        });

        let url = format!("{}/api/chat", self.base_url);

        let response = self
            .client
            .post(&url)
            .json(&body)
            .send()
            .map_err(|e| CoreError::LlmError(format!("Ollama request failed: {e}")))?;

        if !response.status().is_success() {
            return Err(CoreError::LlmError(format!(
                "Ollama returned status {}",
                response.status()
            )));
        }

        let json: serde_json::Value = response
            .json()
            .map_err(|e| CoreError::LlmError(format!("Failed to parse Ollama response: {e}")))?;

        json["message"]["content"]
            .as_str()
            .map(|s: &str| s.trim().to_string())
            .ok_or_else(|| CoreError::LlmError("Missing content in Ollama response".into()))
    }

    fn name(&self) -> &str {
        "ollama"
    }

    fn is_available(&self) -> bool {
        let url = format!("{}/api/tags", self.base_url);
        self.client.get(&url).send().is_ok()
    }
}
