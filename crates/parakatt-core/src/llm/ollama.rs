/// Ollama LLM provider with streaming support.
///
/// Connects to a locally running Ollama instance via its HTTP API
/// at localhost:11434 (default). Uses streaming mode to avoid
/// timeout issues with long-running completions.

use std::io::BufRead;

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
            // Generous timeout for streaming — individual chunks arrive fast,
            // but the full completion can take minutes for long text.
            client: reqwest::blocking::Client::builder()
                .connect_timeout(std::time::Duration::from_secs(10))
                .timeout(std::time::Duration::from_secs(300))
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
            "stream": true,
        });

        let url = format!("{}/api/chat", self.base_url);

        let response = self
            .client
            .post(&url)
            .json(&body)
            .send()
            .map_err(|e| {
                if e.is_timeout() {
                    CoreError::LlmError(
                        "Ollama request timed out — the model may be too slow or the text too long"
                            .into(),
                    )
                } else if e.is_connect() {
                    CoreError::LlmError(format!(
                        "Cannot connect to Ollama at {} — is the server running?",
                        self.base_url
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

        // Read streaming response: newline-delimited JSON objects.
        // Each object has {"message":{"content":"..."},"done":false/true}
        let mut accumulated = String::new();
        let reader = std::io::BufReader::new(response);

        for line in reader.lines() {
            let line = line.map_err(|e| {
                CoreError::LlmError(format!("Error reading Ollama stream: {e}"))
            })?;

            if line.trim().is_empty() {
                continue;
            }

            let chunk: serde_json::Value = serde_json::from_str(&line).map_err(|e| {
                CoreError::LlmError(format!("Failed to parse Ollama stream chunk: {e}"))
            })?;

            if let Some(content) = chunk["message"]["content"].as_str() {
                accumulated.push_str(content);
            }

            if chunk["done"].as_bool() == Some(true) {
                break;
            }
        }

        let result = accumulated.trim().to_string();
        if result.is_empty() {
            return Err(CoreError::LlmError(
                "Ollama returned empty response".into(),
            ));
        }

        Ok(result)
    }

    fn name(&self) -> &str {
        "ollama"
    }

    fn is_available(&self) -> bool {
        let url = format!("{}/api/tags", self.base_url);
        self.client.get(&url).send().is_ok()
    }
}
