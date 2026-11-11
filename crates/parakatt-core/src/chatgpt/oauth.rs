use super::*;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use jsonwebtoken::{decode, decode_header, jwk::JwkSet, Algorithm, DecodingKey, Validation};
use sha2::{Digest, Sha256};
use std::{
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    time::{Duration, Instant},
};
use tokio_util::sync::CancellationToken;

pub(super) struct Pending {
    pub id: String,
    listener: Mutex<Option<TcpListener>>,
    state: String,
    nonce: String,
    verifier: String,
    redirect: String,
    account: Option<Account>,
    pub cancelled: CancellationToken,
    started: Instant,
}
fn random() -> String {
    format!(
        "{}{}",
        uuid::Uuid::new_v4().simple(),
        uuid::Uuid::new_v4().simple()
    )
}
pub(super) fn begin(
    accounts: &ChatGptAccounts,
    account_id: Option<String>,
) -> Result<ChatGptSignIn, CoreError> {
    let listener = TcpListener::bind("127.0.0.1:0").map_err(|_| {
        error(
            "callback_unavailable",
            "Cannot open the local sign-in callback",
        )
    })?;
    listener.set_nonblocking(true).map_err(|_| {
        error(
            "callback_unavailable",
            "Cannot prepare the sign-in callback",
        )
    })?;
    let address = listener
        .local_addr()
        .map_err(|_| error("callback_unavailable", "Cannot read the callback address"))?;
    let _lock = accounts.store.lock()?;
    let mut state = accounts.store.read()?;
    let account = match account_id {
        Some(id) => Some(
            state
                .accounts
                .iter()
                .find(|a| a.id == id)
                .cloned()
                .ok_or_else(|| error("account_not_found", "Select a saved account"))?,
        ),
        None => None,
    };
    if state.host_id.is_empty() {
        state.host_id = format!("urn:uuid:{}", uuid::Uuid::new_v4());
        accounts.store.write(&state)?;
    }
    let pending = Arc::new(Pending {
        id: uuid::Uuid::new_v4().to_string(),
        listener: Mutex::new(Some(listener)),
        state: random(),
        nonce: random(),
        verifier: random(),
        redirect: format!("http://127.0.0.1:{}/auth/callback", address.port()),
        account,
        cancelled: CancellationToken::new(),
        started: Instant::now(),
    });
    let mut url = url::Url::parse(&format!("{}/api/accounts/authorize", accounts.auth_base))
        .map_err(|_| error("configuration", "Invalid OpenAI authorization endpoint"))?;
    {
        let mut query = url.query_pairs_mut();
        query
            .append_pair(
                "client_id",
                pending
                    .account
                    .as_ref()
                    .map_or("dynamic_agent_client", |a| a.client_id.as_str()),
            )
            .append_pair("ext_agent_host_id", &state.host_id)
            .append_pair("response_type", "code")
            .append_pair("redirect_uri", &pending.redirect)
            .append_pair("scope", SCOPES)
            .append_pair("resource", RESOURCE)
            .append_pair("state", &pending.state)
            .append_pair("nonce", &pending.nonce)
            .append_pair("code_challenge_method", "S256")
            .append_pair(
                "code_challenge",
                &URL_SAFE_NO_PAD.encode(Sha256::digest(pending.verifier.as_bytes())),
            );
        if let Some(account) = &pending.account {
            // Do not put the retained ID token in browser URLs/process arguments.
            query.append_pair("login_hint", &account.email);
            if state
                .credentials
                .get(&account.id)
                .is_some_and(|c| !c.plan_enabled())
            {
                query.append_pair("prompt", "consent");
            }
        } else {
            query.append_pair("agent_name_hint", "Parakatt");
        }
    }
    let result = ChatGptSignIn {
        id: pending.id.clone(),
        authorization_url: url.to_string(),
    };
    let mut slot = accounts
        .pending
        .lock()
        .map_err(|_| error("internal", "Cannot start sign-in"))?;
    if let Some(old) = slot.replace(pending) {
        old.cancelled.cancel();
    }
    Ok(result)
}
pub(super) fn complete(
    accounts: &ChatGptAccounts,
    attempt_id: &str,
) -> Result<ChatGptAccount, CoreError> {
    let pending = accounts
        .pending
        .lock()
        .map_err(|_| error("internal", "Cannot read sign-in state"))?
        .as_ref()
        .filter(|p| p.id == attempt_id)
        .cloned()
        .ok_or_else(|| error("cancelled", "Sign-in was cancelled"))?;
    let result = finish(accounts, &pending);
    if let Ok(mut slot) = accounts.pending.lock() {
        if slot.as_ref().is_some_and(|p| p.id == attempt_id) {
            *slot = None;
        }
    }
    result
}
fn finish(accounts: &ChatGptAccounts, pending: &Pending) -> Result<ChatGptAccount, CoreError> {
    let listener = pending
        .listener
        .lock()
        .map_err(|_| error("internal", "Cannot read callback state"))?
        .take()
        .ok_or_else(|| {
            error(
                "sign_in_in_progress",
                "This sign-in is already being completed",
            )
        })?;
    let (code, issued) = loop {
        if pending.cancelled.is_cancelled() {
            return Err(error("cancelled", "Sign-in was cancelled"));
        }
        if pending.started.elapsed() > Duration::from_secs(300) {
            return Err(error("sign_in_timeout", "Sign-in expired. Start again."));
        }
        match listener.accept() {
            Ok((mut stream, _)) => {
                match callback(&mut stream, pending) {
                    Ok(result) => {
                        reply(&mut stream, true);
                        break result;
                    }
                    Err(e) if matches!(&e, CoreError::ChatGptError { code, .. } if code == "access_denied") =>
                    {
                        reply(&mut stream, false);
                        return Err(e);
                    }
                    Err(_) => reply(&mut stream, false), // An unrelated local request cannot end a pending attempt.
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(50))
            }
            Err(_) => return Err(error("callback_unavailable", "The sign-in callback failed")),
        }
    };
    let body = read_response(
        client()?
            .post(format!("{}/api/accounts/oauth/token", accounts.auth_base))
            .form(&[
                ("grant_type", "authorization_code"),
                ("client_id", issued.as_str()),
                ("code", code.as_str()),
                ("code_verifier", pending.verifier.as_str()),
                ("redirect_uri", pending.redirect.as_str()),
                ("resource", RESOURCE),
            ])
            .send()
            .map_err(|_| error("temporary_unavailable", "Cannot complete ChatGPT sign-in"))?,
    )?;
    let id_token = body
        .get("id_token")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| error("invalid_identity", "OpenAI did not return an ID token"))?;
    let claims = validate_identity(accounts, id_token, &issued, Some(&pending.nonce))?;
    if pending
        .account
        .as_ref()
        .is_some_and(|a| a.subject != claims.sub || a.client_id != issued)
    {
        return Err(error(
            "identity_mismatch",
            "The signed-in account does not match the selected registration",
        ));
    }
    let credentials = token_record(&body, None)?;
    let _lock = accounts.store.lock()?;
    if pending.cancelled.is_cancelled() {
        return Err(error("cancelled", "Sign-in was cancelled"));
    }
    let mut state = accounts.store.read()?;
    if let Some(previous) = &pending.account {
        if !state
            .accounts
            .iter()
            .any(|a| a.id == previous.id && a.epoch == previous.epoch)
        {
            return Err(error(
                "account_changed",
                "The account changed during sign-in. Start again.",
            ));
        }
    }
    let index = state.accounts.iter().position(|a| a.client_id == issued);
    if index.is_some_and(|i| {
        state
            .accounts
            .get(i)
            .is_some_and(|a| a.subject != claims.sub)
    }) {
        return Err(error(
            "identity_mismatch",
            "The account registration has a different identity",
        ));
    }
    let id = index
        .and_then(|i| state.accounts.get(i))
        .map_or_else(|| uuid::Uuid::new_v4().to_string(), |a| a.id.clone());
    let confirmed = index
        .and_then(|i| state.accounts.get(i))
        .is_some_and(|a| a.confirmed);
    let account = Account {
        id: id.clone(),
        email: claims
            .email
            .unwrap_or_else(|| "ChatGPT account".into())
            .chars()
            .filter(|c| !c.is_control())
            .take(254)
            .collect(),
        subject: claims.sub,
        client_id: issued,
        epoch: uuid::Uuid::new_v4().to_string(),
        paused: false,
        confirmed,
    };
    if let Some(index) = index {
        if let Some(existing) = state.accounts.get_mut(index) {
            *existing = account;
        }
    } else {
        state.accounts.push(account);
    }
    // Switching the active account also invalidates pending work for the old account.
    if state.active.as_ref() != Some(&id) {
        if let Some(old) = state
            .accounts
            .iter_mut()
            .find(|a| Some(&a.id) == state.active.as_ref())
        {
            old.epoch = uuid::Uuid::new_v4().to_string();
        }
    }
    state.active = Some(id.clone());
    state.credentials.insert(id.clone(), credentials);
    accounts.store.write(&state)?;
    drop(_lock);
    accounts
        .list()?
        .into_iter()
        .find(|a| a.id == id)
        .ok_or_else(|| error("storage", "Cannot read the connected account"))
}
fn callback(stream: &mut TcpStream, pending: &Pending) -> Result<(String, String), CoreError> {
    // Accepted sockets can inherit O_NONBLOCK on macOS. A browser may send headers after accept.
    stream
        .set_nonblocking(false)
        .map_err(|_| error("invalid_callback", "Cannot prepare callback connection"))?;
    stream
        .set_read_timeout(Some(Duration::from_secs(1)))
        .map_err(|_| error("invalid_callback", "Cannot read callback"))?;
    let mut bytes = Vec::new();
    let mut buffer = [0u8; 1024];
    while bytes.len() < 16 * 1024 {
        let read = stream
            .read(&mut buffer)
            .map_err(|_| error("invalid_callback", "Cannot read callback"))?;
        if read == 0 {
            break;
        }
        bytes.extend_from_slice(
            buffer
                .get(..read)
                .ok_or_else(|| error("invalid_callback", "Invalid callback"))?,
        );
        if bytes.windows(4).any(|w| w == b"\r\n\r\n") {
            break;
        }
    }
    let request = std::str::from_utf8(&bytes)
        .map_err(|_| error("invalid_callback", "Invalid callback encoding"))?;
    let mut parts = request.lines().next().unwrap_or("").split_whitespace();
    if parts.next() != Some("GET") {
        return Err(error("invalid_callback", "Invalid callback method"));
    }
    let path = parts
        .next()
        .filter(|s| s.starts_with("/auth/callback?"))
        .ok_or_else(|| error("invalid_callback", "Invalid callback path"))?;
    parse_callback(path, pending)
}
fn parse_callback(path: &str, pending: &Pending) -> Result<(String, String), CoreError> {
    let url = url::Url::parse(&format!("http://127.0.0.1{path}"))
        .map_err(|_| error("invalid_callback", "Invalid callback URL"))?;
    let mut pairs = std::collections::BTreeMap::new();
    for (key, value) in url.query_pairs() {
        if pairs.insert(key.into_owned(), value.into_owned()).is_some() {
            return Err(error("invalid_callback", "Duplicate callback parameter"));
        }
    }
    if pairs.get("state") != Some(&pending.state) {
        return Err(error("invalid_state", "Sign-in state did not match"));
    }
    if pairs.contains_key("error") {
        return Err(error("access_denied", "ChatGPT sign-in was declined"));
    }
    let issued = match (&pending.account, pairs.get("client_id")) {
        (Some(account), None) => account.client_id.clone(),
        (Some(account), Some(id)) if id == &account.client_id => id.clone(),
        (None, Some(id)) if !id.is_empty() && id != "dynamic_agent_client" => id.clone(),
        _ => {
            return Err(error(
                "invalid_client",
                "The callback did not return the expected client registration",
            ))
        }
    };
    let code = pairs
        .get("code")
        .filter(|s| !s.is_empty())
        .cloned()
        .ok_or_else(|| error("invalid_callback", "Missing authorization code"))?;
    Ok((code, issued))
}
fn reply(stream: &mut TcpStream, success: bool) {
    let message = if success {
        "Sign-in received. Return to Parakatt to check the result."
    } else {
        "This sign-in callback was not accepted. Return to Parakatt."
    };
    let status = if success { "200 OK" } else { "400 Bad Request" };
    let _timeout = stream.set_write_timeout(Some(Duration::from_secs(1)));
    let _response = write!(stream, "HTTP/1.1 {status}\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{message}", message.len());
}
#[derive(Clone, Deserialize)]
struct Claims {
    sub: String,
    nonce: Option<String>,
    email: Option<String>,
    azp: Option<String>,
    aud: serde_json::Value,
}
fn metadata(accounts: &ChatGptAccounts) -> Result<serde_json::Value, CoreError> {
    let response = read_response(
        client()?
            .get(format!(
                "{}/.well-known/openid-configuration",
                accounts.auth_base
            ))
            .send()
            .map_err(|_| {
                error(
                    "temporary_unavailable",
                    "Cannot read OpenAI sign-in metadata",
                )
            })?,
    )?;
    if response.get("issuer").and_then(serde_json::Value::as_str) != Some(ISSUER) {
        return Err(error(
            "invalid_identity",
            "Unexpected OpenAI identity issuer",
        ));
    }
    Ok(response)
}
fn trusted_endpoint(
    accounts: &ChatGptAccounts,
    metadata: &serde_json::Value,
    field: &str,
) -> Result<String, CoreError> {
    let endpoint = metadata[field]
        .as_str()
        .ok_or_else(|| error("invalid_identity", "Missing OpenAI sign-in endpoint"))?;
    let url = url::Url::parse(endpoint)
        .map_err(|_| error("invalid_identity", "Invalid OpenAI sign-in endpoint"))?;
    let expected = url::Url::parse(&accounts.auth_base)
        .map_err(|_| error("configuration", "Invalid OpenAI sign-in origin"))?;
    if url.origin() != expected.origin() || !url.username().is_empty() || url.password().is_some() {
        return Err(error(
            "invalid_identity",
            "Unexpected OpenAI sign-in endpoint",
        ));
    }
    Ok(endpoint.into())
}
fn validate_identity(
    accounts: &ChatGptAccounts,
    token: &str,
    audience: &str,
    nonce: Option<&str>,
) -> Result<Claims, CoreError> {
    let metadata = metadata(accounts)?;
    let jwks = trusted_endpoint(accounts, &metadata, "jwks_uri")?;
    let keys: JwkSet = client()?
        .get(jwks)
        .send()
        .map_err(|_| error("temporary_unavailable", "Cannot read OpenAI signing keys"))?
        .error_for_status()
        .map_err(|_| error("temporary_unavailable", "Cannot read OpenAI signing keys"))?
        .json()
        .map_err(|_| error("invalid_identity", "Invalid OpenAI signing keys"))?;
    verify_identity(token, audience, nonce, &keys)
}
fn verify_identity(
    token: &str,
    audience: &str,
    nonce: Option<&str>,
    keys: &JwkSet,
) -> Result<Claims, CoreError> {
    let invalid = || error("invalid_identity", "OpenAI ID token validation failed");
    let header = decode_header(token).map_err(|_| invalid())?;
    if !matches!(header.alg, Algorithm::RS256 | Algorithm::ES256) {
        return Err(invalid());
    }
    let key = header
        .kid
        .as_ref()
        .and_then(|id| keys.find(id))
        .ok_or_else(invalid)?;
    use jsonwebtoken::jwk::{KeyAlgorithm, KeyOperations, PublicKeyUse};
    let expected_algorithm = match header.alg {
        Algorithm::RS256 => KeyAlgorithm::RS256,
        Algorithm::ES256 => KeyAlgorithm::ES256,
        _ => return Err(invalid()),
    };
    if key
        .common
        .public_key_use
        .as_ref()
        .is_some_and(|usage| *usage != PublicKeyUse::Signature)
        || key
            .common
            .key_algorithm
            .is_some_and(|algorithm| algorithm != expected_algorithm)
        || key
            .common
            .key_operations
            .as_ref()
            .is_some_and(|operations| !operations.contains(&KeyOperations::Verify))
    {
        return Err(invalid());
    }
    let key = DecodingKey::from_jwk(key).map_err(|_| invalid())?;
    let mut validation = Validation::new(header.alg);
    validation.set_issuer(&[ISSUER]);
    validation.set_audience(&[audience]);
    validation.set_required_spec_claims(&["exp", "iss", "aud", "sub"]);
    validation.leeway = 0;
    validation.validate_nbf = true;
    let claims = decode::<Claims>(token, &key, &validation)
        .map_err(|_| invalid())?
        .claims;
    if claims.sub.is_empty()
        || nonce.is_some_and(|n| claims.nonce.as_deref() != Some(n))
        || claims.azp.as_ref().is_some_and(|a| a != audience)
        || (claims.aud.as_array().is_some_and(|a| a.len() > 1)
            && claims.azp.as_deref() != Some(audience))
    {
        return Err(invalid());
    }
    Ok(claims)
}
fn token_record(
    body: &serde_json::Value,
    previous: Option<&Credentials>,
) -> Result<Credentials, CoreError> {
    let scopes: Vec<String> = match body.get("scope").and_then(serde_json::Value::as_str) {
        Some(scopes) => scopes.split_whitespace().map(str::to_string).collect(),
        None => previous.map(|p| p.scopes.clone()).unwrap_or_default(),
    };
    let plan_enabled = scopes
        .iter()
        .any(|scope| scope == "chatgpt.tokens.use.direct");
    if plan_enabled
        && !body
            .get("token_type")
            .and_then(serde_json::Value::as_str)
            .is_some_and(|t| t.eq_ignore_ascii_case("Bearer"))
    {
        return Err(error(
            "invalid_response",
            "OpenAI returned an unsupported token type",
        ));
    }
    let access = body
        .get("access_token")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("");
    let refresh = body
        .get("refresh_token")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("");
    if plan_enabled && (access.is_empty() || refresh.is_empty()) {
        return Err(error(
            "invalid_response",
            "Missing ChatGPT access or replacement refresh token",
        ));
    }
    let id = body
        .get("id_token")
        .and_then(serde_json::Value::as_str)
        .or_else(|| previous.map(|p| p.id_token.as_str()))
        .ok_or_else(|| error("invalid_response", "Missing ChatGPT ID token"))?;
    let lifetime = body
        .get("expires_in")
        .and_then(serde_json::Value::as_i64)
        .filter(|n| *n > 0 && *n <= 86400)
        .or(if plan_enabled { None } else { Some(0) })
        .ok_or_else(|| error("invalid_response", "Invalid ChatGPT token expiry"))?;
    Ok(Credentials {
        access_token: access.into(),
        refresh_token: refresh.into(),
        id_token: id.into(),
        scopes,
        expires_at: now().saturating_add(lifetime),
        earliest_refresh_at: body["earliest_refresh_at"].as_i64().unwrap_or(0),
    })
}
pub(super) fn access_token(
    accounts: &ChatGptAccounts,
    session: &Session,
) -> Result<String, CoreError> {
    // The OS lock stays held through refresh and the atomic replacement.
    let _lock = accounts.store.lock()?;
    let mut state = accounts.store.read()?;
    session.check_state(&state)?;
    let credential = state
        .credentials
        .get(&session.id)
        .cloned()
        .ok_or_else(|| error("sign_in_required", "Sign in with ChatGPT"))?;
    if credential.expires_at > now() + 60
        || credential.earliest_refresh_at > now() && credential.expires_at > now()
    {
        return Ok(credential.access_token);
    }
    let account = state
        .accounts
        .iter()
        .find(|a| a.id == session.id)
        .ok_or_else(|| error("account_not_found", "Select an account"))?;
    let response = client()?
        .post(format!("{}/api/accounts/oauth/token", accounts.auth_base))
        .form(&[
            ("grant_type", "refresh_token"),
            ("client_id", account.client_id.as_str()),
            ("refresh_token", credential.refresh_token.as_str()),
            ("resource", RESOURCE),
        ])
        .send()
        .map_err(|_| error("temporary_unavailable", "Cannot renew ChatGPT access"))?;
    let status = response.status();
    let body: serde_json::Value = response
        .json()
        .map_err(|_| error("invalid_response", "Invalid ChatGPT refresh response"))?;
    if !status.is_success() {
        let code = body
            .get("error")
            .and_then(serde_json::Value::as_str)
            .or_else(|| {
                body.pointer("/error/code")
                    .and_then(serde_json::Value::as_str)
            })
            .unwrap_or("");
        if matches!(
            code,
            "invalid_grant"
                | "invalid_refresh_token"
                | "token_expired"
                | "refresh_token_expired"
                | "refresh_token_invalidated"
                | "refresh_token_reused"
        ) {
            state.credentials.remove(&session.id);
            accounts.store.write(&state)?;
            return Err(error(
                "sign_in_required",
                "ChatGPT access expired or was revoked. Sign in again.",
            ));
        }
        return Err(response_error(status.as_u16(), &body, None));
    }
    if let Some(id_token) = body.get("id_token").and_then(serde_json::Value::as_str) {
        let claims = validate_identity(accounts, id_token, &account.client_id, None)?;
        if claims.sub != account.subject {
            return Err(error(
                "identity_mismatch",
                "The renewed ChatGPT identity changed",
            ));
        }
    }
    let updated = token_record(&body, Some(&credential))?;
    let token = updated.access_token.clone();
    state.credentials.insert(session.id.clone(), updated);
    accounts.store.write(&state)?;
    session.check_state(&state)?;
    Ok(token)
}
pub(super) fn sign_out(
    accounts: &ChatGptAccounts,
    account_id: Option<String>,
) -> Result<ChatGptSignOut, CoreError> {
    let _lock = accounts.store.lock()?;
    let mut state = accounts.store.read()?;
    let id = resolve_id(&state, account_id.as_deref())?;
    let account = state
        .accounts
        .iter_mut()
        .find(|a| a.id == id)
        .ok_or_else(|| error("account_not_found", "Select a saved account"))?;
    account.epoch = uuid::Uuid::new_v4().to_string();
    let issued = account.client_id.clone();
    let credential = state.credentials.get(&id).cloned();
    // Persist invalidation before attempting revocation, so other processes stop.
    state.credentials.remove(&id);
    accounts.store.write(&state)?;
    drop(_lock);
    let revoked = if let Some(credential) = credential.filter(|c| !c.refresh_token.is_empty()) {
        let result: Result<bool, CoreError> = (|| {
            let metadata = metadata(accounts)?;
            let endpoint = trusted_endpoint(accounts, &metadata, "revocation_endpoint")?;
            let client = client()?;
            for attempt in 0..3 {
                match client
                    .post(&endpoint)
                    .form(&[
                        ("token", credential.refresh_token.as_str()),
                        ("token_type_hint", "refresh_token"),
                        ("client_id", issued.as_str()),
                    ])
                    .send()
                {
                    Ok(response) if response.status().as_u16() == 200 => return Ok(true),
                    Ok(response) if !response.status().is_server_error() => return Ok(false),
                    _ if attempt < 2 => {
                        std::thread::sleep(Duration::from_millis(250 * (1 << attempt)))
                    }
                    _ => return Ok(false),
                }
            }
            Ok(false)
        })();
        result.unwrap_or(false)
    } else {
        true
    };
    Ok(ChatGptSignOut { revoked, message: if revoked { "Signed out of ChatGPT." } else { "Signed out locally. Remote revocation was not confirmed. Disconnect Parakatt in ChatGPT Settings." }.into() })
}

#[cfg(test)]
#[path = "oauth_tests.rs"]
mod tests;
