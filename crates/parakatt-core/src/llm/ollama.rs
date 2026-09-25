use super::http::{HttpProvider, Wire};
use crate::CoreError;
pub struct OllamaProvider;
impl OllamaProvider {
    #[allow(clippy::new_ret_no_self)]
    pub fn new(base: &str, model: &str) -> Result<HttpProvider, CoreError> {
        Ok(HttpProvider::new(base, model, None, Wire::Ollama))
    }
}
