//! Sign in with ChatGPT for local clients. The account API does not open Engine/history.
mod oauth;
mod provider;
mod store;
#[cfg(test)]
mod tests;

use crate::CoreError;
pub use provider::ChatGptProvider;
use serde::{Deserialize, Serialize};
use std::sync::{Arc, Mutex};
use store::Store;
pub const USAGE_URL: &str = "https://chatgpt.com/settings/usage";
const RESOURCE: &str = "https://api.openai.com/v1";
const ISSUER: &str = "https://auth.openai.com";
const SCOPES: &str =
    "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct";

#[derive(Clone, Serialize, Deserialize, uniffi::Record)]
pub struct ChatGptAccount {
    pub id: String,
    pub label: String,
    pub signed_in: bool,
    pub plan_enabled: bool,
    pub paused: bool,
    pub active: bool,
}
#[derive(Clone, Serialize, Deserialize)]
struct Account {
    id: String,
    email: String,
    subject: String,
    client_id: String,
    epoch: String,
    paused: bool,
    confirmed: bool,
}
// Deliberately no Debug implementation: credentials must not enter diagnostics.
#[derive(Clone, Serialize, Deserialize)]
struct Credentials {
    access_token: String,
    refresh_token: String,
    id_token: String,
    scopes: Vec<String>,
    expires_at: i64,
    #[serde(default)]
    earliest_refresh_at: i64,
}
impl Credentials {
    fn plan_enabled(&self) -> bool {
        self.scopes.iter().any(|s| s == "chatgpt.tokens.use.direct")
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct ChatGptModelChoice {
    pub slug: String,
    pub display_name: String,
}
#[derive(Clone, uniffi::Record)]
pub struct ChatGptSignIn {
    pub id: String,
    pub authorization_url: String,
}
#[derive(Clone, uniffi::Record)]
pub struct ChatGptSignOut {
    pub revoked: bool,
    pub message: String,
}

#[derive(uniffi::Object)]
pub struct ChatGptAccounts {
    store: Store,
    pending: Mutex<Option<Arc<oauth::Pending>>>,
    // Production URLs are fixed. Tests inject a local server through private fields.
    auth_base: String,
    api_base: String,
}
#[uniffi::export]
impl ChatGptAccounts {
    #[uniffi::constructor]
    pub fn new() -> Result<Arc<Self>, CoreError> {
        Ok(Arc::new(Self {
            store: Store::new()?,
            pending: Mutex::new(None),
            auth_base: ISSUER.into(),
            api_base: RESOURCE.into(),
        }))
    }
    pub fn list(&self) -> Result<Vec<ChatGptAccount>, CoreError> {
        let _lock = self.store.lock()?;
        let state = self.store.read()?;
        Ok(state
            .accounts
            .iter()
            .map(|a| {
                let credential = state.credentials.get(&a.id);
                ChatGptAccount {
                    id: a.id.clone(),
                    label: format!("{} ({})", a.email, a.id),
                    signed_in: credential.is_some(),
                    plan_enabled: credential.is_some_and(Credentials::plan_enabled),
                    paused: a.paused,
                    active: state.active.as_ref() == Some(&a.id),
                }
            })
            .collect())
    }
    pub fn select(&self, account_id: String) -> Result<(), CoreError> {
        let _lock = self.store.lock()?;
        let mut state = self.store.read()?;
        if !state.accounts.iter().any(|a| a.id == account_id) {
            return Err(error("account_not_found", "Select a saved ChatGPT account"));
        }
        // Invalidate providers bound to the previously selected account.
        if state.active.as_ref() != Some(&account_id) {
            if let Some(previous) = state
                .accounts
                .iter_mut()
                .find(|a| Some(&a.id) == state.active.as_ref())
            {
                previous.epoch = uuid::Uuid::new_v4().to_string();
            }
        }
        state.active = Some(account_id);
        self.store.write(&state)
    }
    pub fn begin_sign_in(&self, account_id: Option<String>) -> Result<ChatGptSignIn, CoreError> {
        oauth::begin(self, account_id)
    }
    pub fn complete_sign_in(&self, attempt_id: String) -> Result<ChatGptAccount, CoreError> {
        oauth::complete(self, &attempt_id)
    }
    pub fn cancel_sign_in(&self, attempt_id: String) {
        if let Ok(mut pending) = self.pending.lock() {
            if pending.as_ref().is_some_and(|p| p.id == attempt_id) {
                if let Some(attempt) = pending.take() {
                    attempt.cancelled.cancel();
                }
            }
        }
    }
    pub fn sign_out(&self, account_id: Option<String>) -> Result<ChatGptSignOut, CoreError> {
        oauth::sign_out(self, account_id)
    }
    /// Explicit retry releases the account's usage-limit pause.
    pub fn retry(&self, account_id: Option<String>) -> Result<(), CoreError> {
        let _lock = self.store.lock()?;
        let mut state = self.store.read()?;
        let id = resolve_id(&state, account_id.as_deref())?;
        let account = state
            .accounts
            .iter_mut()
            .find(|a| a.id == id)
            .ok_or_else(|| error("account_not_found", "Select a saved account"))?;
        account.paused = false;
        self.store.write(&state)
    }
    /// Returns true once, after plan access is granted, for the welcome message.
    pub fn take_plan_confirmation(&self, account_id: String) -> Result<bool, CoreError> {
        let _lock = self.store.lock()?;
        let mut state = self.store.read()?;
        let enabled = state
            .credentials
            .get(&account_id)
            .is_some_and(Credentials::plan_enabled);
        let account = state
            .accounts
            .iter_mut()
            .find(|a| a.id == account_id)
            .ok_or_else(|| error("account_not_found", "Select a saved account"))?;
        let show = enabled && !account.confirmed;
        if show {
            account.confirmed = true;
            self.store.write(&state)?;
        }
        Ok(show)
    }
    pub fn models(&self, account_id: Option<String>) -> Result<Vec<ChatGptModelChoice>, CoreError> {
        let session = self.session(account_id.as_deref())?;
        let token = self.access_token(&session)?;
        let response = client()?
            .get(format!("{}/models", self.api_base))
            .bearer_auth(token)
            .send()
            .map_err(|_| error("temporary_unavailable", "Cannot connect to OpenAI"))?;
        let body = read_response(response)?;
        session.check(self)?;
        parse_models(&body)
    }
}
impl ChatGptAccounts {
    fn session(&self, account_id: Option<&str>) -> Result<Session, CoreError> {
        let _lock = self.store.lock()?;
        let state = self.store.read()?;
        let id = resolve_id(&state, account_id)?;
        let account = state
            .accounts
            .iter()
            .find(|a| a.id == id)
            .ok_or_else(|| error("account_not_found", "Select a saved account"))?;
        Ok(Session {
            id,
            epoch: account.epoch.clone(),
        })
    }
    fn access_token(&self, session: &Session) -> Result<String, CoreError> {
        oauth::access_token(self, session)
    }
    fn pause(&self, session: &Session) -> Result<(), CoreError> {
        let _lock = self.store.lock()?;
        let mut state = self.store.read()?;
        if let Some(account) = state
            .accounts
            .iter_mut()
            .find(|a| a.id == session.id && a.epoch == session.epoch)
        {
            account.paused = true;
            self.store.write(&state)?;
        }
        Ok(())
    }
}
#[derive(Clone)]
struct Session {
    id: String,
    epoch: String,
}
impl Session {
    fn check(&self, accounts: &ChatGptAccounts) -> Result<(), CoreError> {
        let _lock = accounts.store.lock()?;
        let state = accounts.store.read()?;
        self.check_state(&state)
    }
    fn check_state(&self, state: &store::State) -> Result<(), CoreError> {
        let account = state
            .accounts
            .iter()
            .find(|a| a.id == self.id && a.epoch == self.epoch)
            .ok_or_else(|| {
                error(
                    "account_changed",
                    "The ChatGPT account changed; retry processing",
                )
            })?;
        let credential = state
            .credentials
            .get(&self.id)
            .ok_or_else(|| error("sign_in_required", "Sign in to ChatGPT again"))?;
        if !credential.plan_enabled() {
            return Err(error(
                "consent_required",
                "Enable ChatGPT plan usage with Continue with ChatGPT",
            ));
        }
        if account.paused {
            return Err(error(
                "subscription_sharing_usage_limit_exceeded",
                "Usage limit reached. Manage usage in ChatGPT settings, then retry.",
            ));
        }
        Ok(())
    }
}
fn resolve_id(state: &store::State, id: Option<&str>) -> Result<String, CoreError> {
    id.map(str::to_string)
        .or_else(|| state.active.clone())
        .ok_or_else(|| error("sign_in_required", "Sign in with ChatGPT first"))
}
pub(super) fn error(code: &str, message: &str) -> CoreError {
    CoreError::ChatGptError {
        code: code.into(),
        message: message.into(),
        request_id: None,
        http_status: None,
        param: None,
    }
}
fn client() -> Result<reqwest::blocking::Client, CoreError> {
    reqwest::blocking::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(10))
        .timeout(std::time::Duration::from_secs(30))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| {
            error(
                "temporary_unavailable",
                "Cannot create the OpenAI connection",
            )
        })
}
fn now() -> i64 {
    chrono::Utc::now().timestamp()
}
fn read_response(response: reqwest::blocking::Response) -> Result<serde_json::Value, CoreError> {
    let status = response.status().as_u16();
    let request_id = response
        .headers()
        .get("x-request-id")
        .and_then(|v| v.to_str().ok())
        .map(str::to_string);
    let body = response
        .json::<serde_json::Value>()
        .map_err(|_| error("invalid_response", "OpenAI returned an invalid response"))?;
    if !(200..300).contains(&status) {
        return Err(response_error(status, &body, request_id));
    }
    Ok(body)
}
pub(crate) fn response_error(
    status: u16,
    body: &serde_json::Value,
    request_id: Option<String>,
) -> CoreError {
    // Responses stream errors can carry code/param directly on the event;
    // HTTP errors and response.failed events wrap them in an error object.
    let details = body.get("error").unwrap_or(body);
    let code = details
        .get("code")
        .and_then(serde_json::Value::as_str)
        .filter(|s| s.len() <= 128 && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'))
        .unwrap_or(match status {
            401 => "sign_in_required",
            403 => "permission_denied",
            429 => "rate_limited",
            500..=599 => "temporary_unavailable",
            _ => "request_failed",
        });
    let message = match code {
        "subscription_sharing_usage_limit_exceeded" => {
            "Usage limit reached. Manage usage in ChatGPT settings, then retry."
        }
        "subscription_sharing_user_not_eligible" => {
            "ChatGPT plan usage is unavailable for this account or workspace."
        }
        "sign_in_required" | "subscription_sharing_invalid_user" => {
            "ChatGPT access was rejected. Check the selected account and sign-in permissions."
        }
        "subscription_sharing_unsupported_capability" => {
            "The selected model or request option does not support ChatGPT plan usage."
        }
        "subscription_sharing_usage_unavailable"
        | "subscription_sharing_user_unavailable"
        | "temporary_unavailable" => "ChatGPT is temporarily unavailable. Retry later.",
        _ => "OpenAI rejected the request. Check the selected account, model, and permissions.",
    };
    CoreError::ChatGptError {
        code: code.into(),
        message: format!("{message} (HTTP {status})"),
        request_id,
        http_status: Some(status),
        param: details
            .get("param")
            .and_then(serde_json::Value::as_str)
            .filter(|s| {
                s.len() <= 256
                    && s.chars()
                        .all(|c| c.is_ascii_alphanumeric() || "._[]-".contains(c))
            })
            .map(str::to_string),
    }
}
fn parse_models(body: &serde_json::Value) -> Result<Vec<ChatGptModelChoice>, CoreError> {
    let entries = body["models"]
        .as_array()
        .ok_or_else(|| error("invalid_response", "Invalid ChatGPT model catalog"))?;
    entries
        .iter()
        .filter(|entry| entry["visibility"] == "list")
        .map(|entry| {
            let slug = entry["slug"]
                .as_str()
                .filter(|s| !s.is_empty())
                .ok_or_else(|| error("invalid_response", "Missing ChatGPT model slug"))?;
            let name = entry["display_name"]
                .as_str()
                .ok_or_else(|| error("invalid_response", "Missing ChatGPT model name"))?;
            Ok(ChatGptModelChoice {
                slug: slug.into(),
                display_name: name.into(),
            })
        })
        .collect()
}
