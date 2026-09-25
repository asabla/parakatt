use super::http::{HttpProvider, Wire};
use crate::CoreError;
pub struct OpenAiCompatibleProvider;
impl OpenAiCompatibleProvider {
    pub fn openai(key: &str, model: &str) -> Result<HttpProvider, CoreError> {
        Ok(HttpProvider::new(
            "https://api.openai.com/v1",
            model,
            Some(key.into()),
            Wire::Responses,
        ))
    }
    pub fn lmstudio(base: &str, model: &str) -> Result<HttpProvider, CoreError> {
        let base = base.trim_end_matches('/');
        let base = if base.ends_with("/v1") {
            base.into()
        } else {
            format!("{base}/v1")
        };
        Ok(HttpProvider::new(&base, model, None, Wire::Chat))
    }
}
