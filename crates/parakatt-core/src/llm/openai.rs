/// OpenAI-compatible LLM provider.
///
/// Works with OpenAI API, LM Studio, and any other service
/// implementing the OpenAI chat completions endpoint.

use crate::CoreError;

use super::{LlmProvider, LlmRequest};

pub struct OpenAiCompatibleProvider {
    base_url: String,
    api_key: Option<String>,
    model: String,
    display_name: String,
    client: reqwest::blocking::Client,
}

impl OpenAiCompatibleProvider {
    /// Create a provider for the real OpenAI API.
    pub fn openai(api_key: &str, model: &str) -> Self {
        Self {
            base_url: "https://api.openai.com/v1".to_string(),
            api_key: Some(api_key.to_string()),
            model: model.to_string(),
            display_name: "openai".to_string(),
            client: reqwest::blocking::Client::builder()
                .timeout(std::time::Duration::from_secs(60))
                .build()
                .expect("Failed to build HTTP client"),
        }
    }

    /// Create a provider for LM Studio (OpenAI-compatible local server).
    pub fn lmstudio(base_url: &str, model: &str) -> Self {
        let base = base_url.trim_end_matches('/');
        // LM Studio serves at /v1 — ensure it's in the URL
        let base = if base.ends_with("/v1") { base.to_string() } else { format!("{}/v1", base) };
        Self {
            base_url: base,
            api_key: None,
            model: model.to_string(),
            display_name: "lmstudio".to_string(),
            client: reqwest::blocking::Client::builder()
                .timeout(std::time::Duration::from_secs(60))
                .build()
                .expect("Failed to build HTTP client"),
        }
    }
}

impl LlmProvider for OpenAiCompatibleProvider {
    fn process(&self, request: &LlmRequest) -> Result<String, CoreError> {
        let mut messages = vec![
            serde_json::json!({
                "role": "system",
                "content": &request.system_prompt
            }),
        ];

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

        log::info!(
            "[{}] Sending to LLM: model={}, text='{}', prompt='{}'",
            self.display_name,
            self.model,
            &request.text,
            &request.system_prompt.chars().take(80).collect::<String>()
        );

        let body = serde_json::json!({
            "model": &self.model,
            "messages": messages,
            "temperature": 0.3,
        });

        let url = format!("{}/chat/completions", self.base_url);

        let mut req = self.client.post(&url).json(&body);
        if let Some(key) = &self.api_key {
            req = req.header("Authorization", format!("Bearer {key}"));
        }

        let response = req
            .send()
            .map_err(|e| CoreError::LlmError(format!("{} request failed: {e}", self.display_name)))?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().unwrap_or_default();
            return Err(CoreError::LlmError(format!(
                "{} returned status {}: {}",
                self.display_name, status, body
            )));
        }

        let json: serde_json::Value = response
            .json()
            .map_err(|e| CoreError::LlmError(format!("Failed to parse response: {e}")))?;

        json["choices"][0]["message"]["content"]
            .as_str()
            .map(|s: &str| s.trim().to_string())
            .ok_or_else(|| CoreError::LlmError("Missing content in response".into()))
    }

    fn name(&self) -> &str {
        &self.display_name
    }

    fn is_available(&self) -> bool {
        if self.api_key.is_some() {
            // For remote APIs, assume available if API key is set
            return true;
        }
        // For local servers, try to reach the models endpoint
        let url = format!("{}/models", self.base_url);
        self.client.get(&url).send().is_ok()
    }
}
