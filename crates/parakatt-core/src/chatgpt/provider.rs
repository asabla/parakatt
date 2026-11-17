use super::*;
use crate::llm::{
    http::{HttpProvider, Wire},
    LlmProvider, LlmRequest, ProviderDiagnostic,
};
use std::sync::atomic::{AtomicBool, Ordering};
use tokio_util::sync::CancellationToken;

pub struct ChatGptProvider {
    accounts: Arc<ChatGptAccounts>,
    session: Session,
    model: String,
    invalidated: CancellationToken,
}
impl ChatGptProvider {
    pub fn new(
        accounts: Arc<ChatGptAccounts>,
        account_id: Option<String>,
        model: String,
    ) -> Result<Self, CoreError> {
        if model.trim().is_empty() {
            return Err(error("model_required", "Select a ChatGPT model"));
        }
        let session = accounts.session(account_id.as_deref())?;
        Ok(Self {
            accounts,
            session,
            model,
            invalidated: CancellationToken::new(),
        })
    }
}
impl LlmProvider for ChatGptProvider {
    fn process(&self, request: &LlmRequest) -> Result<String, CoreError> {
        self.process_cancellable(request, &CancellationToken::new(), &|_| {})
    }
    fn process_cancellable(
        &self,
        request: &LlmRequest,
        cancellation: &CancellationToken,
        observer: &(dyn Fn(&str) + Send + Sync),
    ) -> Result<String, CoreError> {
        if cancellation.is_cancelled() || self.invalidated.is_cancelled() {
            return Err(error("cancelled", "ChatGPT processing was cancelled"));
        }
        let token = self.accounts.access_token(&self.session)?;
        if cancellation.is_cancelled() || self.invalidated.is_cancelled() {
            return Err(error("cancelled", "ChatGPT processing was cancelled"));
        }
        self.session.check(&self.accounts)?;
        let http = HttpProvider::new(
            &self.accounts.api_base,
            &self.model,
            Some(token),
            Wire::ChatGpt,
        );
        let stop = AtomicBool::new(false);
        let child = cancellation.child_token();
        let result = std::thread::scope(|scope| {
            scope.spawn(|| {
                while !stop.load(Ordering::Acquire) {
                    if self.invalidated.is_cancelled()
                        || self.session.check(&self.accounts).is_err()
                    {
                        child.cancel();
                        break;
                    }
                    std::thread::sleep(std::time::Duration::from_millis(150));
                }
            });
            let result = http.process_cancellable(request, &child, observer);
            stop.store(true, Ordering::Release);
            result
        });
        if self.invalidated.is_cancelled() {
            return Err(error(
                "cancelled",
                "The LLM provider changed; recognized text was kept",
            ));
        }
        if matches!(&result, Err(CoreError::ChatGptError { code, .. }) if code == "subscription_sharing_usage_limit_exceeded")
        {
            self.accounts.pause(&self.session)?;
            return result;
        }
        self.session.check(&self.accounts)?;
        result
    }
    fn invalidate(&self) {
        self.invalidated.cancel();
    }
    fn name(&self) -> &str {
        "chatgpt"
    }
    fn is_available(&self) -> bool {
        !self.invalidated.is_cancelled() && self.session.check(&self.accounts).is_ok()
    }
    fn diagnose(&self) -> ProviderDiagnostic {
        let mut report = ProviderDiagnostic {
            connection: "Not tested".into(),
            authentication: "Not tested".into(),
            model: "Not tested".into(),
            completion: "Not tested".into(),
        };
        match self.accounts.models(Some(self.session.id.clone())) {
            Ok(models) => {
                report.connection = "Passed".into();
                report.authentication = "ChatGPT account accepted".into();
                if !models.iter().any(|m| m.slug == self.model) {
                    report.model = "Selected model is absent from this account's catalog".into();
                    return report;
                }
            }
            Err(e) => {
                report.authentication = e.to_string();
                return report;
            }
        }
        let request = LlmRequest {
            preceding_text: None,
            allow_preceding_context: false,
            text: "Reply with READY.".into(),
            system_prompt: "This is a synthetic connection test. Return only READY.".into(),
            context: None,
        };
        match self.process(&request) {
            Ok(_) => {
                report.model = "Accepted selected model".into();
                report.completion = "Passed: complete non-empty stream".into();
            }
            Err(e) => report.completion = e.to_string(),
        }
        report
    }
}
