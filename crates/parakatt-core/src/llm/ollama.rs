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
        let mut messages = vec![
            serde_json::json!({
                "role": "system",
                "content": &request.system_prompt
            }),
        ];

        // Add context if available
        if let Some(ctx) = &request.context {
            let mut context_parts = Vec::new();
            if let Some(app) = &ctx.app_name {
                context_parts.push(format!("Active application: {app}"));
            }
            if let Some(selected) = &ctx.selected_text {
                context_parts.push(format!("Selected text: {selected}"));
            }
            if !context_parts.is_empty() {
                messages.push(serde_json::json!({
                    "role": "system",
                    "content": format!("Context:\n{}", context_parts.join("\n"))
                }));
            }
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
            .map_err(|e| {
                if e.is_timeout() {
                    CoreError::LlmError(format!(
                        "Ollama request timed out after 60s — the model may be too slow or the text too long"
                    ))
                } else if e.is_connect() {
                    CoreError::LlmError(format!(
                        "Cannot connect to Ollama at {} — is the server running?", self.base_url
                    ))
                } else {
                    CoreError::LlmError(format!("Ollama request failed: {e}"))
                }
            })?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().unwrap_or_default();
            return Err(CoreError::LlmError(format!(
                "Ollama returned status {status}: {body}"
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
