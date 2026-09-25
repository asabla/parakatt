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
// No backend is promoted without a checked-in acceptance result for its exact
// model revision, OS and hardware. Development benchmarks bypass this policy.
#[derive(serde::Deserialize)]
struct Validation {
    model_revision: String,
    hardware: String,
    os_build: String,
    backend: SpeechBackend,
    cpu_threads: u32,
    runtime_api_version: u32,
    packaged_startup: bool,
    english_no_regression: bool,
    swedish_no_regression: bool,
    median_improvement: f64,
    p95_no_regression: bool,
}
#[derive(serde::Deserialize)]
struct Matrix {
    validated: Vec<Validation>,
}
fn system_value(key: &str) -> String {
    std::process::Command::new("sysctl")
        .args(["-n", key])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().into())
        .unwrap_or_default()
}
pub fn validated_backend(settings: &SpeechSettings) -> SpeechBackend {
    if settings.backend == SpeechBackend::Cpu || !cfg!(feature = "webgpu") {
        return SpeechBackend::Cpu;
    }
    static SYSTEM: std::sync::OnceLock<(String, String)> = std::sync::OnceLock::new();
    let (hardware, os_build) = SYSTEM.get_or_init(|| {
        (
            system_value("machdep.cpu.brand_string"),
            system_value("kern.osversion"),
        )
    });
    let revision = &crate::models::model_file_set("parakeet-tdt-0.6b-v3")
        .unwrap()
        .revision;
    let matrix: Matrix = serde_json::from_str(include_str!("../backend-validation.json"))
        .expect("backend validation schema");
    select_backend(settings, &matrix, hardware, os_build, revision)
}
fn select_backend(
    settings: &SpeechSettings,
    matrix: &Matrix,
    hardware: &str,
    os_build: &str,
    revision: &str,
) -> SpeechBackend {
    if settings.backend == SpeechBackend::Cpu {
        return SpeechBackend::Cpu;
    }
    let threads = if settings.cpu_threads == 0 {
        4
    } else {
        settings.cpu_threads
    };
    matrix
        .validated
        .iter()
        .find(|v| {
            v.model_revision == revision
                && v.hardware == hardware
                && v.os_build == os_build
                && v.cpu_threads == threads
                && v.runtime_api_version == ort::MINOR_VERSION
                && v.packaged_startup
                && v.backend == SpeechBackend::WebGpu
                && v.english_no_regression
                && v.swedish_no_regression
                && v.median_improvement >= 0.10
                && v.p95_no_regression
        })
        .map(|v| v.backend)
        .unwrap_or(SpeechBackend::Cpu)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn automatic_selection_requires_every_release_gate_and_keeps_explicit_cpu() {
        let mut matrix = Matrix {
            validated: vec![Validation {
                model_revision: "model".into(),
                hardware: "tested".into(),
                os_build: "tested-os".into(),
                backend: SpeechBackend::WebGpu,
                cpu_threads: 4,
                runtime_api_version: ort::MINOR_VERSION,
                packaged_startup: true,
                english_no_regression: true,
                swedish_no_regression: true,
                median_improvement: 0.2,
                p95_no_regression: true,
            }],
        };
        let mut settings = SpeechSettings::default();
        assert_eq!(
            select_backend(&settings, &matrix, "tested", "tested-os", "model"),
            SpeechBackend::WebGpu
        );
        assert_eq!(
            select_backend(&settings, &matrix, "unknown", "tested-os", "model"),
            SpeechBackend::Cpu
        );
        assert_eq!(
            select_backend(&settings, &matrix, "tested", "other-os", "model"),
            SpeechBackend::Cpu
        );
        settings.cpu_threads = 2;
        assert_eq!(
            select_backend(&settings, &matrix, "tested", "tested-os", "model"),
            SpeechBackend::Cpu
        );
        settings.cpu_threads = 4;
        settings.backend = SpeechBackend::Cpu;
        assert_eq!(
            select_backend(&settings, &matrix, "tested", "tested-os", "model"),
            SpeechBackend::Cpu
        );
        settings.backend = SpeechBackend::Automatic;
        matrix.validated[0].swedish_no_regression = false;
        assert_eq!(
            select_backend(&settings, &matrix, "tested", "tested-os", "model"),
            SpeechBackend::Cpu
        );
        matrix.validated[0].swedish_no_regression = true;
        matrix.validated[0].packaged_startup = false;
        assert_eq!(
            select_backend(&settings, &matrix, "tested", "tested-os", "model"),
            SpeechBackend::Cpu
        );
    }
}
