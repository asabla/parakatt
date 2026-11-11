use super::*;
use crate::llm::{LlmProvider, LlmRequest};
use serde_json::json;
use std::{
    io::{Read, Write},
    net::TcpListener,
    sync::atomic::{AtomicBool, Ordering},
    thread::JoinHandle,
    time::Duration,
};

pub(super) struct Server {
    pub base: String,
    pub requests: Arc<Mutex<Vec<String>>>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}
impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(thread) = self.thread.take() {
            let result = thread.join();
            if !std::thread::panicking() {
                result.unwrap();
            }
        }
    }
}
pub(super) fn server(handler: impl Fn(&str) -> (u16, String) + Send + 'static) -> Server {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let stop = Arc::new(AtomicBool::new(false));
    let requests = Arc::new(Mutex::new(Vec::new()));
    let ended = stop.clone();
    let observed = requests.clone();
    let thread = std::thread::spawn(move || {
        while !ended.load(Ordering::Acquire) {
            let (mut stream, _) = match listener.accept() {
                Ok(value) => value,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(10));
                    continue;
                }
                Err(e) => panic!("{e}"),
            };
            stream.set_nonblocking(false).unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let mut bytes = Vec::new();
            let mut buffer = [0; 4096];
            loop {
                let n = stream.read(&mut buffer).unwrap();
                if n == 0 {
                    break;
                }
                bytes.extend_from_slice(&buffer[..n]);
                if let Some(end) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
                    let headers = String::from_utf8_lossy(&bytes[..end]);
                    let size: usize = headers
                        .lines()
                        .find_map(|l| {
                            l.to_lowercase()
                                .strip_prefix("content-length:")
                                .map(|s| s.trim().parse().unwrap())
                        })
                        .unwrap_or(0);
                    if bytes.len() >= end + 4 + size {
                        break;
                    }
                }
            }
            let request = String::from_utf8(bytes).unwrap();
            observed.lock().unwrap().push(request.clone());
            let (status, body) = handler(&request);
            let kind = if body.starts_with("data:") {
                "text/event-stream"
            } else {
                "application/json"
            };
            let _reply = write!(stream, "HTTP/1.1 {status} Test\r\nContent-Type: {kind}\r\nx-request-id: request-test\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
        }
    });
    Server {
        base,
        requests,
        stop,
        thread: Some(thread),
    }
}
pub(super) fn fixture(root: &std::path::Path, base: &str) -> Arc<ChatGptAccounts> {
    Arc::new(ChatGptAccounts {
        store: Store {
            root: root.into(),
            file_backend: true,
        },
        pending: Mutex::new(None),
        auth_base: base.into(),
        api_base: base.into(),
    })
}
pub(super) fn seed(accounts: &ChatGptAccounts, expires: i64) {
    let _lock = accounts.store.lock().unwrap();
    let mut state = accounts.store.read().unwrap();
    state.host_id = "urn:uuid:test-host".into();
    state.active = Some("account-one".into());
    state.accounts.push(Account {
        id: "account-one".into(),
        email: "same@example.test".into(),
        subject: "subject".into(),
        client_id: "issued-one".into(),
        epoch: "epoch-one".into(),
        paused: false,
        confirmed: false,
    });
    state.credentials.insert(
        "account-one".into(),
        Credentials {
            access_token: "test-access".into(),
            refresh_token: "test-refresh".into(),
            id_token: "test-id".into(),
            scopes: SCOPES.split_whitespace().map(str::to_string).collect(),
            expires_at: expires,
            earliest_refresh_at: 0,
        },
    );
    accounts.store.write(&state).unwrap();
}
fn request() -> LlmRequest {
    LlmRequest {
        preceding_text: None,
        allow_preceding_context: false,
        text: "Talet är 42.".into(),
        system_prompt: "Fix punctuation.".into(),
        context: None,
    }
}

#[test]
fn model_catalog_preserves_order_and_account_names() {
    let result = parse_models(&json!({"models":[{"slug":"second","display_name":"Second","visibility":"list"},{"slug":"hidden","visibility":"hidden"},{"slug":"first","display_name":"First","visibility":"list"}]})).unwrap();
    assert_eq!(
        result.iter().map(|m| m.slug.as_str()).collect::<Vec<_>>(),
        ["second", "first"]
    );
    assert!(parse_models(&json!({"data":[]})).is_err());
}
#[test]
fn shared_store_preserves_registrations_and_confirms_plan_once() {
    let root = tempfile::tempdir().unwrap();
    let accounts = fixture(root.path(), ISSUER);
    seed(&accounts, now() + 3600);
    let peer = fixture(root.path(), ISSUER);
    assert_eq!(peer.list().unwrap()[0].id, "account-one");
    assert!(accounts
        .take_plan_confirmation("account-one".into())
        .unwrap());
    assert!(!peer.take_plan_confirmation("account-one".into()).unwrap());
    let _lock = accounts.store.lock().unwrap();
    let mut state = accounts.store.read().unwrap();
    let mut second = state.accounts[0].clone();
    second.id = "account-two".into();
    second.client_id = "issued-two".into();
    state.accounts.push(second);
    accounts.store.write(&state).unwrap();
    drop(_lock);
    let session = accounts.session(None).unwrap();
    peer.select("account-two".into()).unwrap();
    assert!(session.check(&accounts).is_err());
    assert_eq!(peer.list().unwrap().len(), 2);
    assert!(peer.list().unwrap()[1].active);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(root.path().join("accounts.json"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
}
#[test]
fn missing_consent_never_sends_inference() {
    let root = tempfile::tempdir().unwrap();
    let accounts = fixture(root.path(), "http://127.0.0.1:1");
    seed(&accounts, now() + 3600);
    let _lock = accounts.store.lock().unwrap();
    let mut state = accounts.store.read().unwrap();
    state
        .credentials
        .get_mut("account-one")
        .unwrap()
        .scopes
        .clear();
    accounts.store.write(&state).unwrap();
    drop(_lock);
    let provider = ChatGptProvider::new(accounts.clone(), None, "model".into()).unwrap();
    assert!(
        matches!(provider.process(&request()), Err(CoreError::ChatGptError {code,..}) if code == "consent_required")
    );
    let attempt = accounts.begin_sign_in(Some("account-one".into())).unwrap();
    assert!(attempt.authorization_url.contains("prompt=consent"));
    accounts.cancel_sign_in(attempt.id.clone());
    assert!(accounts.complete_sign_in(attempt.id).is_err());
}
#[test]
fn rotating_refresh_is_serialized_between_clients() {
    let root = tempfile::tempdir().unwrap();
    let server = server(|request| {
        assert!(request.starts_with("POST /api/accounts/oauth/token"));
        assert!(request.contains("grant_type=refresh_token"));
        assert!(request.contains("client_id=issued-one"));
        assert!(request.contains("refresh_token=test-refresh"));
        (200, json!({"access_token":"new-access","refresh_token":"new-refresh","token_type":"Bearer","expires_in":3600}).to_string())
    });
    let first = fixture(root.path(), &server.base);
    let second = fixture(root.path(), &server.base);
    seed(&first, now() - 1);
    let session = first.session(None).unwrap();
    let peer_session = second.session(None).unwrap();
    std::thread::scope(|scope| {
        let a = scope.spawn(|| first.access_token(&session).unwrap());
        let b = scope.spawn(|| second.access_token(&peer_session).unwrap());
        assert_eq!(a.join().unwrap(), "new-access");
        assert_eq!(b.join().unwrap(), "new-access");
    });
    assert_eq!(server.requests.lock().unwrap().len(), 1);
    assert_eq!(
        first.store.read().unwrap().credentials["account-one"].refresh_token,
        "new-refresh"
    );
}
#[test]
fn terminal_refresh_clears_tokens_but_temporary_failure_keeps_them() {
    for (status, body, cleared) in [
        (400, json!({"error":"invalid_grant"}), true),
        (503, json!({"detail":"private diagnostic"}), false),
    ] {
        let root = tempfile::tempdir().unwrap();
        let server = server(move |_| (status, body.to_string()));
        let accounts = fixture(root.path(), &server.base);
        seed(&accounts, now() - 1);
        let session = accounts.session(None).unwrap();
        let result = accounts.access_token(&session);
        assert!(result.is_err());
        assert_eq!(
            accounts.store.read().unwrap().credentials.is_empty(),
            cleared
        );
        assert_eq!(accounts.list().unwrap().len(), 1);
    }
}
#[test]
fn inference_uses_plan_contract_and_only_completed_text() {
    let server = server(|request| {
        assert!(request.starts_with("POST /responses"));
        assert!(request
            .to_lowercase()
            .contains("authorization: bearer test-access"));
        let body: serde_json::Value =
            serde_json::from_str(request.split("\r\n\r\n").nth(1).unwrap()).unwrap();
        assert_eq!(body["store"], false);
        assert_eq!(body["stream"], true);
        assert!(body["input"].is_array());
        assert!(body.get("max_output_tokens").is_none());
        (200, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"draft\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Talet är 42.\"}]}]}}\n\n".into())
    });
    let root = tempfile::tempdir().unwrap();
    let accounts = fixture(root.path(), &server.base);
    seed(&accounts, now() + 3600);
    let provider = ChatGptProvider::new(accounts, None, "selected".into()).unwrap();
    assert_eq!(provider.process(&request()).unwrap(), "Talet är 42.");
    provider.invalidate();
    assert!(provider.process(&request()).is_err());
}
#[test]
fn usage_limit_before_or_during_stream_pauses_until_explicit_retry() {
    for event in ["http", "response.failed", "error"] {
        let server = server(move |_| {
            if event == "response.failed" {
                (200, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\ndata: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\",\"message\":\"private input\"}}}\n\n".into())
            } else if event == "error" {
                (200, "data: {\"type\":\"error\",\"code\":\"subscription_sharing_usage_limit_exceeded\",\"message\":\"private input\",\"param\":\"model\"}\n\n".into())
            } else {
                (429, json!({"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"private input"}}).to_string())
            }
        });
        let root = tempfile::tempdir().unwrap();
        let accounts = fixture(root.path(), &server.base);
        seed(&accounts, now() + 3600);
        let provider = ChatGptProvider::new(accounts.clone(), None, "selected".into()).unwrap();
        let error = provider.process(&request()).unwrap_err();
        assert!(
            matches!(&error, CoreError::ChatGptError {code,request_id,..} if code == "subscription_sharing_usage_limit_exceeded" && request_id.as_deref() == Some("request-test"))
        );
        assert!(!error.to_string().contains("private input"));
        if event == "error" {
            assert!(
                matches!(&error, CoreError::ChatGptError { param, .. } if param.as_deref() == Some("model"))
            );
        }
        assert!(provider.process(&request()).is_err());
        assert_eq!(server.requests.lock().unwrap().len(), 1);
        accounts.retry(None).unwrap();
        assert!(provider.process(&request()).is_err());
        assert_eq!(server.requests.lock().unwrap().len(), 2);
    }
}
#[test]
fn interrupted_stream_does_not_return_partial_output() {
    let server = server(|_| {
        (
            200,
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n".into(),
        )
    });
    let root = tempfile::tempdir().unwrap();
    let accounts = fixture(root.path(), &server.base);
    seed(&accounts, now() + 3600);
    let provider = ChatGptProvider::new(accounts, None, "selected".into()).unwrap();
    assert!(
        matches!(provider.process(&request()), Err(CoreError::ChatGptError {code,..}) if code == "incomplete_output")
    );
}
#[test]
fn offline_signout_clears_only_selected_credentials_and_invalidates_session() {
    let root = tempfile::tempdir().unwrap();
    let accounts = fixture(root.path(), "http://127.0.0.1:1");
    seed(&accounts, now() + 3600);
    let session = accounts.session(None).unwrap();
    let result = accounts.sign_out(None).unwrap();
    assert!(!result.revoked);
    assert!(result.message.contains("not confirmed"));
    assert!(session.check(&accounts).is_err());
    assert!(!accounts.list().unwrap()[0].signed_in);
    assert_eq!(accounts.store.read().unwrap().host_id, "urn:uuid:test-host");
}
#[test]
fn config_contains_only_chatgpt_references() {
    let mut config = crate::config::Config::default();
    config.llm.active_provider = Some("chatgpt".into());
    config.llm.chatgpt.account_id = Some("account-one".into());
    config.llm.chatgpt.model = Some("model".into());
    let encoded = toml::to_string(&config).unwrap();
    assert!(!encoded.contains("access_token"));
    assert!(!encoded.contains("refresh_token"));
    let decoded: crate::config::Config = toml::from_str(&encoded).unwrap();
    assert_eq!(
        decoded.llm.chatgpt.account_id.as_deref(),
        Some("account-one")
    );
}

#[test]
fn refresh_child_process() {
    let Some(root) = std::env::var_os("PARAKATT_CHATGPT_TEST_STORE") else {
        return;
    };
    let accounts = fixture(
        std::path::Path::new(&root),
        &std::env::var("PARAKATT_CHATGPT_TEST_SERVER").unwrap(),
    );
    let session = accounts.session(None).unwrap();
    assert_eq!(accounts.access_token(&session).unwrap(), "child-access");
}
#[test]
fn rotating_refresh_is_serialized_across_processes() {
    let server = server(|request| {
        assert!(request.contains("refresh_token=test-refresh"));
        (200, json!({"access_token":"child-access","refresh_token":"child-refresh","token_type":"Bearer","expires_in":3600}).to_string())
    });
    let root = tempfile::tempdir().unwrap();
    let accounts = fixture(root.path(), &server.base);
    seed(&accounts, now() - 1);
    let spawn = || {
        std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "chatgpt::tests::refresh_child_process"])
            .env("PARAKATT_CHATGPT_TEST_STORE", root.path())
            .env("PARAKATT_CHATGPT_TEST_SERVER", &server.base)
            .stdout(std::process::Stdio::null())
            .spawn()
            .unwrap()
    };
    let mut first = spawn();
    let mut second = spawn();
    assert!(first.wait().unwrap().success());
    assert!(second.wait().unwrap().success());
    assert_eq!(server.requests.lock().unwrap().len(), 1);
}
#[test]
fn account_switch_cancels_inflight_request_without_returning_rewrite() {
    let server = server(|_| {
        std::thread::sleep(Duration::from_millis(700));
        (200, "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Must not be returned\"}]}]}}\n\n".into())
    });
    let root = tempfile::tempdir().unwrap();
    let accounts = fixture(root.path(), &server.base);
    seed(&accounts, now() + 3600);
    let _lock = accounts.store.lock().unwrap();
    let mut state = accounts.store.read().unwrap();
    let mut other = state.accounts[0].clone();
    other.id = "other".into();
    other.client_id = "other-client".into();
    state.accounts.push(other);
    accounts.store.write(&state).unwrap();
    drop(_lock);
    let provider = ChatGptProvider::new(accounts.clone(), None, "model".into()).unwrap();
    std::thread::scope(|scope| {
        let work = scope.spawn(|| provider.process(&request()));
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while server.requests.lock().unwrap().is_empty() {
            assert!(std::time::Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        }
        fixture(root.path(), &server.base)
            .select("other".into())
            .unwrap();
        assert!(work.join().unwrap().is_err());
    });
}

#[test]
fn provider_change_and_signout_keep_recognized_text_for_active_and_queued_chunks() {
    for sign_out in [false, true] {
        let server = server(|request| {
            if !request.starts_with("POST /responses") {
                return (503, json!({"detail":"unavailable"}).to_string());
            }
            std::thread::sleep(Duration::from_millis(400));
            (200, "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Must not replace recognized text\"}]}]}}\n\n".into())
        });
        let root = tempfile::tempdir().unwrap();
        let accounts = fixture(root.path(), &server.base);
        seed(&accounts, now() + 3600);
        let provider =
            Arc::new(ChatGptProvider::new(accounts.clone(), None, "model".into()).unwrap());
        let session = crate::processing::ProcessingSession::new("chatgpt-cancellation".into());
        for (index, text) in [(0, "Talet är 42."), (1, "Nästa mening.")] {
            let mut input = request();
            input.text = text.into();
            session
                .enqueue(
                    index,
                    crate::ChunkSource::Mixed,
                    text.into(),
                    Some((provider.clone(), input)),
                    None,
                )
                .unwrap();
        }
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while server.requests.lock().unwrap().is_empty() {
            assert!(std::time::Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        }
        if sign_out {
            accounts.sign_out(None).unwrap();
        } else {
            provider.invalidate();
        }
        let (text, summary, error) = session.finish().unwrap();
        assert_eq!(text, summary.recognized_text);
        assert!(text.contains("Talet är 42."));
        assert!(text.contains("Nästa mening."));
        assert!(!text.contains("Must not replace"));
        assert!(error.is_some());
        assert_eq!(
            server
                .requests
                .lock()
                .unwrap()
                .iter()
                .filter(|request| request.starts_with("POST /responses"))
                .count(),
            1
        );
    }
}
