//! Provider-specific wire formats over one cancellable HTTP transport.
use super::{LlmProvider, LlmRequest};
use crate::CoreError;
use futures_util::StreamExt;
use serde_json::{json, Value};
use std::{sync::OnceLock, time::Duration};
use tokio_util::sync::CancellationToken;

#[derive(Debug, Clone, Copy)]
pub enum Wire {
    Ollama,
    Chat,
    Responses,
    Anthropic,
}
#[derive(Debug, thiserror::Error)]
enum Failure {
    #[error("Request cancelled")]
    Cancelled,
    #[error("HTTP {0}")]
    Http(u16, Option<u64>),
    #[error("Transport error: {0}")]
    Transport(reqwest::Error),
    #[error("Invalid provider response: {0}")]
    Protocol(String),
}
impl Failure {
    fn retry_delay(&self, attempt: u32) -> Option<Duration> {
        match self {
            Self::Http(code, retry) if *code == 429 || *code >= 500 => {
                Some(Duration::from_secs(retry.unwrap_or(1 << attempt)))
            }
            Self::Transport(e) if e.is_connect() || e.is_timeout() || e.is_body() => {
                Some(Duration::from_millis(500 * (1 << attempt)))
            }
            _ => None,
        }
    }
}
pub struct HttpProvider {
    pub base_url: String,
    pub model: String,
    pub key: Option<String>,
    pub wire: Wire,
    pub output_limit: u32,
    pub keep_alive: String,
    pub think: Option<bool>,
    pub thinking_level: Option<String>,
}
fn runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("LLM runtime")
    })
}
impl HttpProvider {
    pub fn new(base: &str, model: &str, key: Option<String>, wire: Wire) -> Self {
        Self {
            base_url: base.trim_end_matches('/').into(),
            model: model.into(),
            key,
            wire,
            output_limit: 4096,
            keep_alive: "5m".into(),
            think: None,
            thinking_level: None,
        }
    }
    fn payload(&self, request: &LlmRequest) -> Value {
        let mut text = request.text.clone();
        if let Some(context) = &request.context {
            // Context is user data, not additional system instructions.
            if let Some(selected) = &context.selected_text {
                text = format!("Selected text (context):\n{selected}\n\nTranscription:\n{text}");
            }
        }
        match self.wire {
            Wire::Responses => {
                json!({"model":self.model,"instructions":request.system_prompt,"input":text,"stream":true,"store":false,"max_output_tokens":self.output_limit})
            }
            Wire::Anthropic => {
                json!({"model":self.model,"system":request.system_prompt,"messages":[{"role":"user","content":text}],"stream":true,"max_tokens":self.output_limit})
            }
            wire => {
                let mut value = json!({"model":self.model,"messages":[{"role":"system","content":request.system_prompt},{"role":"user","content":text}],"stream":true});
                if matches!(wire, Wire::Ollama) {
                    value["keep_alive"] = json!(self.keep_alive);
                    value["options"] = json!({"num_predict":self.output_limit});
                    if let Some(level) = &self.thinking_level {
                        value["think"] = json!(level);
                    } else if let Some(think) = self.think {
                        value["think"] = json!(think);
                    }
                } else {
                    value["max_tokens"] = json!(self.output_limit);
                }
                value
            }
        }
    }
    async fn attempt(
        &self,
        request: &LlmRequest,
        observer: &(dyn Fn(&str) + Send + Sync),
    ) -> Result<String, Failure> {
        static CLIENT: OnceLock<Result<reqwest::Client, String>> = OnceLock::new();
        let client = CLIENT
            .get_or_init(|| {
                reqwest::Client::builder()
                    .connect_timeout(Duration::from_secs(10))
                    .build()
                    .map_err(|e| e.to_string())
            })
            .as_ref()
            .map_err(|e| Failure::Protocol(e.clone()))?;
        let payload = self.payload(request);
        if matches!(self.wire, Wire::Ollama) && payload.get("think").is_some() {
            let response = client
                .post(format!("{}/api/show", self.base_url))
                .json(&json!({"model":self.model}))
                .send()
                .await
                .map_err(Failure::Transport)?;
            if !response.status().is_success() {
                return Err(Failure::Http(response.status().as_u16(), None));
            }
            let metadata: Value = response.json().await.map_err(Failure::Transport)?;
            if !metadata["thinking"]["values"]
                .as_array()
                .is_some_and(|values| values.contains(&payload["think"]))
            {
                return Err(Failure::Protocol(
                    "The model does not advertise the selected thinking control; use its default"
                        .into(),
                ));
            }
        }
        let endpoint = match self.wire {
            Wire::Ollama => "api/chat",
            Wire::Chat => "chat/completions",
            Wire::Responses => "responses",
            Wire::Anthropic => "messages",
        };
        let mut call = client
            .post(format!("{}/{endpoint}", self.base_url))
            .json(&payload);
        if let Some(key) = &self.key {
            call = if matches!(self.wire, Wire::Anthropic) {
                call.header("x-api-key", key)
                    .header("anthropic-version", "2023-06-01")
            } else {
                call.bearer_auth(key)
            };
        }
        let response = call.send().await.map_err(Failure::Transport)?;
        if !response.status().is_success() {
            let retry = response
                .headers()
                .get("retry-after")
                .and_then(|v| v.to_str().ok())
                .and_then(|s| {
                    s.parse().ok().or_else(|| {
                        chrono::DateTime::parse_from_rfc2822(s).ok().map(|date| {
                            (date.timestamp() - chrono::Utc::now().timestamp()).max(0) as u64
                        })
                    })
                });
            return Err(Failure::Http(response.status().as_u16(), retry));
        }
        let mut stream = response.bytes_stream();
        let mut buffer = Vec::new();
        let mut data = String::new();
        let mut decoder = Decoder::new(self.wire);
        while let Some(bytes) = stream.next().await {
            buffer.extend_from_slice(&bytes.map_err(Failure::Transport)?);
            if buffer.len() > 2 * 1024 * 1024 {
                return Err(Failure::Protocol("event too large".into()));
            }
            while let Some(end) = buffer.iter().position(|b| *b == b'\n') {
                let bytes: Vec<_> = buffer.drain(..=end).collect();
                let line = std::str::from_utf8(&bytes)
                    .map_err(|e| Failure::Protocol(e.to_string()))?
                    .trim_end_matches(['\r', '\n']);
                if matches!(self.wire, Wire::Ollama) {
                    if !line.is_empty() {
                        decoder.accept(line)?;
                        observer(&decoder.text);
                    }
                } else if line.is_empty() {
                    if !data.is_empty() {
                        decoder.accept(data.trim_end())?;
                        data.clear();
                        observer(&decoder.text);
                    }
                } else if let Some(value) = line.strip_prefix("data:") {
                    data.push_str(value.trim_start());
                    data.push('\n');
                }
                if data.len() > 2 * 1024 * 1024 {
                    return Err(Failure::Protocol("event too large".into()));
                }
                if decoder.done {
                    return decoder.finish();
                }
            }
        }
        // A final newline is optional in NDJSON, but a completion record is not.
        if matches!(self.wire, Wire::Ollama) && !buffer.is_empty() {
            decoder.accept(
                std::str::from_utf8(&buffer).map_err(|e| Failure::Protocol(e.to_string()))?,
            )?;
        }
        decoder.finish()
    }
}
impl LlmProvider for HttpProvider {
    fn process(&self, request: &LlmRequest) -> Result<String, CoreError> {
        self.process_cancellable(request, &CancellationToken::new(), &|_| {})
    }
    fn process_cancellable(
        &self,
        request: &LlmRequest,
        cancellation: &CancellationToken,
        observer: &(dyn Fn(&str) + Send + Sync),
    ) -> Result<String, CoreError> {
        let deadline = if matches!(self.wire, Wire::Ollama) {
            300
        } else {
            60
        };
        runtime().block_on(async {
            let work = async {
                for attempt in 0..3 {
                    match self.attempt(request, observer).await {
                        Ok(text) => return Ok(text),
                        Err(error) => {
                            if attempt < 2 { if let Some(delay) = error.retry_delay(attempt) { tokio::time::sleep(delay).await; continue; } }
                            return Err(error);
                        }
                    }
                }
                unreachable!()
            };
            tokio::select! {
                _ = cancellation.cancelled() => Err(Failure::Cancelled),
                result = tokio::time::timeout(Duration::from_secs(deadline), work) => result.unwrap_or_else(|_| Err(Failure::Protocol(format!("Request deadline exceeded ({deadline}s)")))),
            }
        }).map_err(|e| CoreError::LlmError(e.to_string()))
    }
    fn name(&self) -> &str {
        match self.wire {
            Wire::Ollama => "ollama",
            Wire::Chat => "lmstudio",
            Wire::Responses => "openai",
            Wire::Anthropic => "anthropic",
        }
    }
    fn is_available(&self) -> bool {
        runtime().block_on(async {
            let Ok(client) = reqwest::Client::builder()
                .timeout(Duration::from_secs(10))
                .build()
            else {
                return false;
            };
            let suffix = if matches!(self.wire, Wire::Ollama) {
                "api/tags"
            } else {
                "models"
            };
            let mut request = client.get(format!("{}/{suffix}", self.base_url));
            if let Some(key) = &self.key {
                request = if matches!(self.wire, Wire::Anthropic) {
                    request
                        .header("x-api-key", key)
                        .header("anthropic-version", "2023-06-01")
                } else {
                    request.bearer_auth(key)
                };
            }
            request.send().await.is_ok_and(|r| r.status().is_success())
        })
    }
}

struct Decoder {
    wire: Wire,
    text: String,
    done: bool,
    stopped: bool,
}
impl Decoder {
    fn new(wire: Wire) -> Self {
        Self {
            wire,
            text: String::new(),
            done: false,
            stopped: false,
        }
    }
    fn accept(&mut self, data: &str) -> Result<(), Failure> {
        if data == "[DONE]" {
            self.done = self.stopped;
            return Ok(());
        }
        let value: Value =
            serde_json::from_str(data).map_err(|e| Failure::Protocol(e.to_string()))?;
        if let Some(error) = value.get("error").filter(|e| !e.is_null()) {
            return Err(match error["type"].as_str() {
                Some("overloaded_error" | "server_error" | "api_error") => Failure::Http(503, None),
                Some("rate_limit_error") => Failure::Http(429, None),
                _ => Failure::Protocol("provider reported an error".into()),
            });
        }
        let mut delta = None;
        match self.wire {
            Wire::Ollama => {
                delta = value["message"]["content"].as_str();
                if value["done"].as_bool() == Some(true) {
                    if value["done_reason"].as_str() == Some("length") {
                        return Err(Failure::Protocol("output limit reached".into()));
                    }
                    self.done = true;
                }
            }
            Wire::Chat => {
                delta = value["choices"][0]["delta"]["content"].as_str();
                if let Some(reason) = value["choices"][0]["finish_reason"].as_str() {
                    if reason != "stop" {
                        return Err(Failure::Protocol(format!("completion stopped: {reason}")));
                    }
                    self.stopped = true;
                }
            }
            Wire::Responses => match value["type"].as_str().unwrap_or("") {
                "response.output_text.delta" => delta = value["delta"].as_str(),
                "response.failed" | "response.incomplete" | "error" => {
                    return Err(Failure::Protocol("response did not complete".into()))
                }
                "response.completed" => {
                    if value["response"]["status"].as_str() != Some("completed") {
                        return Err(Failure::Protocol("invalid completion status".into()));
                    }
                    let output = value["response"]["output"].as_array().ok_or_else(|| {
                        Failure::Protocol("missing completed response output".into())
                    })?;
                    {
                        self.text = output
                            .iter()
                            .filter(|item| item["type"] == "message" && item["role"] == "assistant")
                            .filter_map(|item| item["content"].as_array())
                            .flatten()
                            .filter(|item| item["type"] == "output_text")
                            .filter_map(|item| item["text"].as_str())
                            .collect::<Vec<_>>()
                            .join("\n");
                    }
                    self.done = true;
                }
                _ => {}
            },
            Wire::Anthropic => match value["type"].as_str().unwrap_or("") {
                "content_block_start" if value["content_block"]["type"] == "text" => {
                    delta = value["content_block"]["text"].as_str();
                }
                "content_block_delta" if value["delta"]["type"] == "text_delta" => {
                    delta = value["delta"]["text"].as_str()
                }
                "message_delta" => {
                    if let Some(reason) = value["delta"]["stop_reason"].as_str() {
                        if !["end_turn", "stop_sequence"].contains(&reason) {
                            return Err(Failure::Protocol(format!("completion stopped: {reason}")));
                        }
                        self.stopped = true;
                    }
                }
                "message_stop" => self.done = self.stopped,
                "error" => return Err(Failure::Protocol("provider stream failed".into())),
                _ => {}
            },
        }
        if let Some(text) = delta {
            self.text.push_str(text);
        }
        if self.text.len() > 8 * 1024 * 1024 {
            return Err(Failure::Protocol("output too large".into()));
        }
        Ok(())
    }
    fn finish(self) -> Result<String, Failure> {
        if !self.done {
            return Err(Failure::Protocol("stream ended without completion".into()));
        }
        if self.text.trim().is_empty() {
            return Err(Failure::Protocol("empty output".into()));
        }
        Ok(self.text.trim().into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn partial_streams_are_not_successes() {
        for wire in [Wire::Chat, Wire::Responses, Wire::Anthropic, Wire::Ollama] {
            assert!(Decoder::new(wire).finish().is_err());
        }
    }
    #[test]
    fn authoritative_response_replaces_deltas() {
        let mut d = Decoder::new(Wire::Responses);
        d.accept(r#"{"type":"response.output_text.delta","delta":"preview"}"#)
            .unwrap();
        d.accept(r#"{"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"final"}]}]}}"#).unwrap();
        assert_eq!(d.finish().unwrap(), "final");
    }
    #[test]
    fn anthropic_requires_stop_reason_and_terminal_event() {
        let mut d = Decoder::new(Wire::Anthropic);
        d.accept(r#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hej"}}"#)
            .unwrap();
        d.accept(r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#)
            .unwrap();
        d.accept(r#"{"type":"message_stop"}"#).unwrap();
        assert_eq!(d.finish().unwrap(), "Hej");
    }
    #[test]
    fn output_limits_fail_without_accepting_partial_text() {
        let mut d = Decoder::new(Wire::Ollama);
        assert!(d
            .accept(r#"{"done":true,"done_reason":"length","message":{"content":"partial"}}"#)
            .is_err());
    }
}

#[cfg(test)]
mod transport_tests {
    use super::*;
    use std::{
        io::{Read, Write},
        net::TcpListener,
        sync::mpsc,
    };
    fn server(
        responses: Vec<(u16, &'static str, String)>,
    ) -> (String, std::thread::JoinHandle<Vec<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let worker = std::thread::spawn(move || {
            let mut requests = Vec::new();
            for (status, headers, body) in responses {
                let (mut socket, _) = listener.accept().unwrap();
                socket
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let mut received = Vec::new();
                loop {
                    let mut buffer = [0; 4096];
                    let n = socket.read(&mut buffer).unwrap();
                    assert!(n > 0);
                    received.extend_from_slice(&buffer[..n]);
                    if let Some(end) = received.windows(4).position(|w| w == b"\r\n\r\n") {
                        let header = String::from_utf8_lossy(&received[..end]);
                        let length = header
                            .lines()
                            .find_map(|line| {
                                line.to_lowercase()
                                    .strip_prefix("content-length:")
                                    .map(|v| v.trim().parse::<usize>().unwrap())
                            })
                            .unwrap_or(0);
                        if received.len() >= end + 4 + length {
                            break;
                        }
                    }
                }
                requests.push(String::from_utf8(received).unwrap());
                write!(socket,"HTTP/1.1 {status} Test\r\nContent-Length: {}\r\nConnection: close\r\n{headers}\r\n", body.len()).unwrap();
                // Split multibyte UTF-8 and SSE frames across network writes.
                for fragment in body.as_bytes().chunks(3) {
                    socket.write_all(fragment).unwrap();
                }
            }
            requests
        });
        (url, worker)
    }
    fn request() -> LlmRequest {
        LlmRequest {
            text: "recognized".into(),
            system_prompt: "correct spelling".into(),
            context: None,
        }
    }
    fn chat() -> String {
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hälsningar\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".into()
    }
    #[test]
    fn retries_503_then_accepts_complete_utf8_response() {
        let (url, server) = server(vec![
            (503, "Retry-After: 0\r\n", String::new()),
            (200, "", chat()),
        ]);
        let provider = HttpProvider::new(&url, "configured-model", None, Wire::Chat);
        assert_eq!(provider.process(&request()).unwrap(), "Hälsningar");
        let requests = server.join().unwrap();
        assert_eq!(requests.len(), 2);
        assert!(requests[0].contains("POST /chat/completions"));
        assert!(!requests[0].contains("temperature"));
    }
    #[test]
    fn retries_at_most_twice_and_does_not_retry_401() {
        let (url, server) = server(vec![(503, "Retry-After: 0\r\n", String::new()); 3]);
        assert!(HttpProvider::new(&url, "m", None, Wire::Chat)
            .process(&request())
            .is_err());
        assert_eq!(server.join().unwrap().len(), 3);
        let (url, server) = self::server(vec![(401, "", String::new())]);
        assert!(HttpProvider::new(&url, "m", None, Wire::Chat)
            .process(&request())
            .is_err());
        assert_eq!(server.join().unwrap().len(), 1);
    }
    #[test]
    fn incomplete_http_stream_is_rejected() {
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n";
        let (url, server) = server(vec![(200, "", body.into())]);
        assert!(HttpProvider::new(&url, "m", None, Wire::Chat)
            .process(&request())
            .is_err());
        server.join().unwrap();
    }
    #[test]
    fn anthropic_uses_required_headers_and_top_level_system() {
        let body=concat!("data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hej\"}}\n\n",
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n",
            "data: {\"type\":\"message_stop\"}\n\n");
        let (url, server) = server(vec![(200, "", body.into())]);
        assert_eq!(
            HttpProvider::new(&url, "chosen", Some("mock-key".into()), Wire::Anthropic)
                .process(&request())
                .unwrap(),
            "Hej"
        );
        let requests = server.join().unwrap();
        let lower = requests[0].to_lowercase();
        assert!(lower.contains("x-api-key: mock-key"));
        assert!(lower.contains("anthropic-version: 2023-06-01"));
        let payload: Value =
            serde_json::from_str(requests[0].split("\r\n\r\n").nth(1).unwrap()).unwrap();
        assert_eq!(payload["system"], "correct spelling");
        assert_eq!(payload["max_tokens"], 4096);
    }
    #[test]
    fn responses_uses_ephemeral_storage_and_accepts_only_completed_output() {
        let body = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Result\"}]}]}}\n\n";
        let (url, server) = server(vec![(200, "", body.into())]);
        assert_eq!(
            HttpProvider::new(&url, "selected-model", Some("mock".into()), Wire::Responses)
                .process(&request())
                .unwrap(),
            "Result"
        );
        let requests = server.join().unwrap();
        let payload: Value =
            serde_json::from_str(requests[0].split("\r\n\r\n").nth(1).unwrap()).unwrap();
        assert_eq!(payload["store"], false);
        assert_eq!(payload["instructions"], "correct spelling");
        assert_eq!(payload["max_output_tokens"], 4096);
        assert!(payload.get("temperature").is_none());
        let mut decoder = Decoder::new(Wire::Responses);
        assert!(decoder
            .accept(r#"{"type":"response.completed","response":{"status":"completed"}}"#)
            .is_err());
    }
    #[test]
    fn cancellation_interrupts_a_pending_http_response() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let provider = HttpProvider::new(
            &format!("http://{}", listener.local_addr().unwrap()),
            "m",
            None,
            Wire::Chat,
        );
        let token = CancellationToken::new();
        let worker_token = token.clone();
        let (ready_tx, ready_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let server = std::thread::spawn(move || {
            let (_socket, _) = listener.accept().unwrap();
            ready_tx.send(()).unwrap();
            release_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        });
        let worker = std::thread::spawn(move || {
            provider.process_cancellable(&request(), &worker_token, &|_| {})
        });
        ready_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        let start = std::time::Instant::now();
        token.cancel();
        assert!(worker.join().unwrap().is_err());
        assert!(start.elapsed() < Duration::from_secs(1));
        release_tx.send(()).unwrap();
        server.join().unwrap();
    }
    #[test]
    fn ollama_thinking_must_match_advertised_values() {
        let (url, server) = server(vec![(
            200,
            "",
            r#"{"thinking":{"values":["low","high"],"default":"low"}}"#.into(),
        )]);
        let mut provider = HttpProvider::new(&url, "m", None, Wire::Ollama);
        provider.think = Some(false);
        assert!(provider.process(&request()).is_err());
        assert_eq!(server.join().unwrap().len(), 1);
    }
}
