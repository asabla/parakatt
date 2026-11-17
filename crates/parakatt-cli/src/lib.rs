#![cfg_attr(
    not(test),
    deny(
        clippy::unwrap_used,
        clippy::indexing_slicing,
        clippy::cast_possible_truncation,
        clippy::cast_possible_wrap,
        clippy::cast_sign_loss,
        clippy::let_underscore_must_use
    )
)]
//! Output-only local file transcription. No Engine, history, or credential store is opened.
pub mod input;
pub mod processing;

use std::path::{Path, PathBuf};

use parakatt_core::{
    models,
    speech::SpeechBackend,
    stt::{parakeet::ParakeetProvider, SttProvider},
};
use serde::Serialize;

pub const MODEL_ID: &str = "parakeet-tdt-0.6b-v3";

#[derive(Debug, Serialize)]
pub struct FileTranscript {
    pub source: FileSource,
    pub model: &'static str,
    pub backend: &'static str,
    pub text: String,
    pub duration_secs: f64,
    pub segments: Vec<Segment>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub processing: Option<processing::Processing>,
}

#[derive(Debug, Serialize)]
pub struct FileSource {
    pub kind: &'static str,
    pub path: String,
}

#[derive(Debug, Serialize)]
pub struct Segment {
    pub text: String,
    pub start_secs: f64,
    pub end_secs: f64,
}

pub fn default_models_dir() -> Result<PathBuf, String> {
    let directory =
        dirs::data_dir().ok_or("Cannot locate the model directory; use --models-dir")?;
    let application = if cfg!(target_os = "macos") {
        "Parakatt"
    } else {
        "parakatt"
    };
    Ok(directory.join(application).join("models"))
}

pub fn transcribe_file(
    input: &Path,
    models_root: &Path,
    raw: bool,
) -> Result<FileTranscript, String> {
    // Complete input checks before model verification/loading or inference.
    let samples = input::read_audio(input, raw)?;
    let directory = models::model_path(models_root, MODEL_ID);
    let manifest = models::model_file_set(MODEL_ID).ok_or("Pinned model manifest is missing")?;
    models::verify_model(&directory, manifest)
        .map_err(|e| format!("Cannot verify model at {}: {e}", directory.display()))?;
    // Reuse the production model, compatible frontend, and four-thread CPU policy.
    // The storage-owning Engine API is intentionally not used for output-only work.
    let provider = ParakeetProvider::load(&directory, MODEL_ID).map_err(|e| e.to_string())?;
    if provider.actual_backend() != SpeechBackend::Cpu {
        return Err("The file CLI requires the CPU backend".into());
    }
    let result = provider
        .transcribe(&samples, input::SAMPLE_RATE)
        .map_err(|e| e.to_string())?;
    Ok(FileTranscript {
        source: FileSource {
            kind: "file",
            path: input.to_string_lossy().into_owned(),
        },
        model: MODEL_ID,
        backend: "cpu",
        text: result.text,
        duration_secs: samples.len() as f64 / f64::from(input::SAMPLE_RATE),
        processing: None,
        segments: result
            .segments
            .into_iter()
            .map(|s| Segment {
                text: s.text,
                start_secs: s.start_secs,
                end_secs: s.end_secs,
            })
            .collect(),
    })
}
