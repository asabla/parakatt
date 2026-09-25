//! Persisted speech preferences and conservative backend selection.
use crate::CoreError;

#[derive(
    Debug, Clone, Copy, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum,
)]
#[serde(rename_all = "snake_case")]
pub enum SpeechLanguage {
    #[default]
    Automatic,
    English,
    Swedish,
}
impl SpeechLanguage {
    pub fn target(self) -> &'static str {
        match self {
            Self::Automatic => "auto",
            Self::English => "en-US",
            Self::Swedish => "sv-SE",
        }
    }
}
#[derive(
    Debug, Clone, Copy, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum,
)]
#[serde(rename_all = "snake_case")]
pub enum SpeechBackend {
    #[default]
    Automatic,
    Cpu,
    WebGpu,
}
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, uniffi::Record)]
#[serde(default)]
pub struct SpeechSettings {
    pub preview_model: Option<String>,
    pub language: SpeechLanguage,
    pub backend: SpeechBackend,
    pub cpu_threads: u32,
}
#[derive(Debug, Clone, uniffi::Enum)]
pub enum ModelReadiness {
    Unavailable,
    Loading,
    Ready,
    Failed { message: String },
}
#[derive(Debug, Clone, uniffi::Record)]
pub struct SpeechRuntimeStatus {
    pub readiness: ModelReadiness,
    pub requested_backend: SpeechBackend,
    pub actual_backend: SpeechBackend,
    pub message: Option<String>,
}
impl SpeechSettings {
    pub fn validate(&self) -> Result<(), CoreError> {
        if let Some(id) = &self.preview_model {
            if crate::models::model_file_set(id)
                .is_none_or(|m| m.provider_type != "nemotron-streaming")
            {
                return Err(CoreError::ConfigError("Unknown streaming model".into()));
            }
        }
        if self.cpu_threads > 64 {
            return Err(CoreError::ConfigError(
                "CPU thread count must be 0 (automatic) or 1–64".into(),
            ));
        }
        Ok(())
    }
}
