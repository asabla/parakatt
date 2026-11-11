use super::*;
use crate::chatgpt::tests::{fixture, seed, server};
use aws_lc_rs::{
    rand::SystemRandom,
    rsa::KeySize,
    signature::{KeyPair, RsaKeyPair, RsaPublicKeyComponents, RSA_PKCS1_SHA256},
};
use jsonwebtoken::Header;
use serde_json::{json, Value};
use std::sync::OnceLock;

fn signing_keys() -> &'static (RsaKeyPair, JwkSet) {
    static KEYS: OnceLock<(RsaKeyPair, JwkSet)> = OnceLock::new();
    KEYS.get_or_init(|| {
        let key = RsaKeyPair::generate(KeySize::Rsa2048).unwrap();
        let public = RsaPublicKeyComponents::<Vec<u8>>::from(key.public_key());
        let keys = serde_json::from_value(json!({"keys":[{"kty":"RSA","kid":"test-key","alg":"RS256","use":"sig","n":URL_SAFE_NO_PAD.encode(public.n),"e":URL_SAFE_NO_PAD.encode(public.e)}]})).unwrap();
        (key, keys)
    })
}
fn claims(nonce: &str) -> Value {
    json!({"iss":ISSUER,"aud":"issued-one","sub":"subject","email":"same@example.test","nonce":nonce,"exp":now()+3600})
}
fn signed(claims: &Value) -> String {
    let mut header = Header::new(Algorithm::RS256);
    header.kid = Some("test-key".into());
    let message = format!(
        "{}.{}",
        URL_SAFE_NO_PAD.encode(serde_json::to_vec(&header).unwrap()),
        URL_SAFE_NO_PAD.encode(serde_json::to_vec(claims).unwrap())
    );
    let key = &signing_keys().0;
    let mut signature = vec![0; key.public_modulus_len()];
    key.sign(
        &RSA_PKCS1_SHA256,
        &SystemRandom::new(),
        message.as_bytes(),
        &mut signature,
    )
    .unwrap();
    format!("{message}.{}", URL_SAFE_NO_PAD.encode(signature))
}
#[test]
fn identity_validation_rejects_wrong_signature_issuer_audience_nonce_and_expiry() {
    let good = claims("expected");
    assert!(verify_identity(
        &signed(&good),
        "issued-one",
        Some("expected"),
        &signing_keys().1
    )
    .is_ok());
    for (field, value) in [
        ("iss", json!("https://attacker.example")),
        ("aud", json!("other-client")),
        ("nonce", json!("other")),
        ("exp", json!(now() - 1)),
        ("sub", json!("")),
        ("azp", json!("other-client")),
    ] {
        let mut wrong = good.clone();
        wrong[field] = value;
        assert!(
            verify_identity(
                &signed(&wrong),
                "issued-one",
                Some("expected"),
                &signing_keys().1
            )
            .is_err(),
            "accepted {field}"
        );
    }
    let mut missing = good.clone();
    missing.as_object_mut().unwrap().remove("nonce");
    assert!(verify_identity(
        &signed(&missing),
        "issued-one",
        Some("expected"),
        &signing_keys().1
    )
    .is_err());
    let mut wrong_signature = signed(&good);
    wrong_signature.push('x');
    assert!(verify_identity(
        &wrong_signature,
        "issued-one",
        Some("expected"),
        &signing_keys().1
    )
    .is_err());
    let mut multiple = good;
    multiple["aud"] = json!(["issued-one", "other"]);
    assert!(verify_identity(
        &signed(&multiple),
        "issued-one",
        Some("expected"),
        &signing_keys().1
    )
    .is_err());
    multiple["azp"] = json!("issued-one");
    assert!(verify_identity(
        &signed(&multiple),
        "issued-one",
        Some("expected"),
        &signing_keys().1
    )
    .is_ok());
}
#[test]
fn callback_checks_state_client_and_duplicate_parameters() {
    let root = tempfile::tempdir().unwrap();
    let accounts = fixture(root.path(), ISSUER);
    let attempt = accounts.begin_sign_in(None).unwrap();
    let pending = accounts.pending.lock().unwrap().clone().unwrap();
    let path = format!(
        "/auth/callback?state={}&code=one&client_id=issued-one",
        pending.state
    );
    assert_eq!(
        parse_callback(&path, &pending).unwrap(),
        ("one".into(), "issued-one".into())
    );
    assert!(parse_callback(&path.replace(&pending.state, "wrong-state"), &pending).is_err());
    assert!(parse_callback(&format!("{path}&code=two"), &pending).is_err());
    assert!(parse_callback(
        &path.replace("issued-one", "dynamic_agent_client"),
        &pending
    )
    .is_err());
    assert!(parse_callback(
        &format!("/auth/callback?state={}&error=access_denied", pending.state),
        &pending
    )
    .is_err());
    let first_host = accounts.store.read().unwrap().host_id;
    accounts.cancel_sign_in(attempt.id.clone());
    assert!(accounts.complete_sign_in(attempt.id).is_err());
    let second = accounts.begin_sign_in(None).unwrap();
    assert_eq!(accounts.store.read().unwrap().host_id, first_host);
    accounts.cancel_sign_in(second.id);
    seed(&accounts, now() + 3600);
    let returning = accounts.begin_sign_in(Some("account-one".into())).unwrap();
    let pending = accounts.pending.lock().unwrap().clone().unwrap();
    assert!(!returning.authorization_url.contains("agent_name_hint"));
    assert!(!returning.authorization_url.contains("test-id"));
    assert_eq!(
        parse_callback(
            &format!("/auth/callback?state={}&code=one", pending.state),
            &pending
        )
        .unwrap()
        .1,
        "issued-one"
    );
    assert!(parse_callback(
        &format!(
            "/auth/callback?state={}&code=one&client_id=other",
            pending.state
        ),
        &pending
    )
    .is_err());
    accounts.cancel_sign_in(returning.id);
}
#[test]
fn complete_signin_validates_identity_and_keeps_workspace_registrations_separate() {
    for enabled in [true, false] {
        let root = tempfile::tempdir().unwrap();
        let origin = Arc::new(Mutex::new(String::new()));
        let endpoint_origin = origin.clone();
        let token = Arc::new(Mutex::new(String::new()));
        let endpoint_token = token.clone();
        let server = server(move |request| {
            if request.starts_with("GET /.well-known/openid-configuration") {
                return (200, json!({"issuer":ISSUER,"jwks_uri":format!("{}/jwks", endpoint_origin.lock().unwrap())}).to_string());
            }
            if request.starts_with("GET /jwks") {
                return (200, serde_json::to_string(&signing_keys().1).unwrap());
            }
            assert!(request.starts_with("POST /api/accounts/oauth/token"));
            assert!(request.contains("client_id=issued-two"));
            assert!(request.contains("code_verifier="));
            assert!(request.contains("grant_type=authorization_code"));
            (200, json!({"access_token":"new-access","refresh_token":"new-refresh","id_token":endpoint_token.lock().unwrap().clone(),"token_type":"Bearer","expires_in":3600,"scope":if enabled {SCOPES} else {"openid profile email"}}).to_string())
        });
        *origin.lock().unwrap() = server.base.clone();
        let accounts = fixture(root.path(), &server.base);
        seed(&accounts, now() + 3600);
        let attempt = accounts.begin_sign_in(None).unwrap();
        let auth = url::Url::parse(&attempt.authorization_url).unwrap();
        let pairs: std::collections::BTreeMap<_, _> = auth
            .query_pairs()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        assert_eq!(pairs["client_id"], "dynamic_agent_client");
        assert_eq!(pairs["agent_name_hint"], "Parakatt");
        let pending = accounts.pending.lock().unwrap().clone().unwrap();
        assert_eq!(
            pairs["code_challenge"],
            URL_SAFE_NO_PAD.encode(Sha256::digest(pending.verifier.as_bytes()))
        );
        let mut identity = claims(&pairs["nonce"]);
        identity["aud"] = json!("issued-two");
        *token.lock().unwrap() = signed(&identity);
        let callback = url::Url::parse(&pairs["redirect_uri"]).unwrap();
        let result = std::thread::scope(|scope| {
            let finish = scope.spawn(|| accounts.complete_sign_in(attempt.id));
            let mut browser = TcpStream::connect(("127.0.0.1", callback.port().unwrap())).unwrap();
            // Exercise a callback whose connection arrives before its HTTP headers.
            std::thread::sleep(Duration::from_millis(100));
            write!(browser, "GET /auth/callback?state={}&code=test-code&client_id=issued-two HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", pairs["state"]).unwrap();
            let mut reply = String::new();
            browser.read_to_string(&mut reply).unwrap();
            assert!(reply.contains("200 OK"));
            finish.join().unwrap().unwrap()
        });
        assert_eq!(result.plan_enabled, enabled);
        let saved = accounts.list().unwrap();
        assert_eq!(saved.len(), 2);
        assert_ne!(saved[0].id, saved[1].id);
        assert!(accounts
            .store
            .read()
            .unwrap()
            .credentials
            .contains_key("account-one"));
    }
}
#[test]
fn successful_signout_uses_discovered_endpoint_and_preserves_registration() {
    let origin = Arc::new(Mutex::new(String::new()));
    let endpoint_origin = origin.clone();
    let server = server(move |request| {
        if request.starts_with("GET /.well-known/openid-configuration") {
            return (200, json!({"issuer":ISSUER,"revocation_endpoint":format!("{}/revoke", endpoint_origin.lock().unwrap())}).to_string());
        }
        assert!(request.starts_with("POST /revoke"));
        assert!(request.contains("token=test-refresh"));
        assert!(request.contains("client_id=issued-one"));
        (200, String::new())
    });
    *origin.lock().unwrap() = server.base.clone();
    let root = tempfile::tempdir().unwrap();
    let accounts = fixture(root.path(), &server.base);
    seed(&accounts, now() + 3600);
    assert!(accounts.sign_out(None).unwrap().revoked);
    assert_eq!(accounts.list().unwrap().len(), 1);
    assert!(!accounts.list().unwrap()[0].signed_in);
}

#[test]
fn identity_only_signin_is_retained_without_inference_credentials() {
    let record = token_record(
        &json!({"id_token":"validated-elsewhere","scope":"openid profile email"}),
        None,
    )
    .unwrap();
    assert!(!record.plan_enabled());
    assert!(record.access_token.is_empty());
    assert!(record.refresh_token.is_empty());
    assert!(token_record(&json!({"id_token":"validated-elsewhere","scope":SCOPES,"token_type":"Bearer","expires_in":3600}), None).is_err());
}
