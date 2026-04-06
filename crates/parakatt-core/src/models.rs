/// Model registry and management.
///
/// Tracks available models, their download status, and provides
/// metadata for the settings UI.
use std::path::{Path, PathBuf};

use crate::ModelInfo;

/// Download metadata for a model: HuggingFace repo URL and list of files.
pub struct ModelFileSet {
    pub repo_url: &'static str,
    pub files: &'static [&'static str],
}

/// Get the download file set for a known model.
pub fn model_file_set(model_id: &str) -> Option<ModelFileSet> {
    match model_id {
        // Multilingual offline commit-path model. Default Parakatt
        // model since the v2-deprecation overhaul.
        "parakeet-tdt-0.6b-v3" => Some(ModelFileSet {
            repo_url: "https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx/resolve/main",
            files: &[
                "vocab.txt",
                "decoder_joint-model.onnx",
                "encoder-model.onnx",
                "encoder-model.onnx.data",
            ],
        }),
        // Cache-aware streaming model used for the live preview path
        // (English only). See `crate::stt::nemotron` for usage.
        // File names are dictated by `parakeet-rs::Nemotron::from_pretrained`:
        //   encoder.onnx + encoder.onnx.data
        //   decoder_joint.onnx
        //   tokenizer.model      (SentencePiece protobuf, NOT vocab.txt)
        "nemotron-speech-streaming-en-0.6b" => Some(ModelFileSet {
            repo_url: "https://huggingface.co/altunenes/parakeet-rs/resolve/main/nemotron-speech-streaming-en-0.6b",
            files: &[
                "tokenizer.model",
                "encoder.onnx",
                "encoder.onnx.data",
                "decoder_joint.onnx",
            ],
        }),
        _ => None,
    }
}

/// Known models that can be downloaded and used.
pub fn available_models() -> Vec<ModelInfo> {
    vec![
        ModelInfo {
            id: "parakeet-tdt-0.6b-v3".to_string(),
            provider_type: "parakeet".to_string(),
            display_name: "Parakeet TDT 0.6B v3 (Multilingual)".to_string(),
            description: Some(
                "NVIDIA Parakeet. 25 European languages, native punctuation, \
                 reduced silence-hallucination training. Required for the \
                 committed transcript path."
                    .to_string(),
            ),
            size_bytes: 2_550_000_000, // ~2.55 GB full precision
            downloaded: false,
        },
        ModelInfo {
            id: "nemotron-speech-streaming-en-0.6b".to_string(),
            provider_type: "nemotron-streaming".to_string(),
            display_name: "Nemotron Speech Streaming 0.6B (English live preview)".to_string(),
            description: Some(
                "NVIDIA cache-aware streaming Parakeet variant. Provides \
                 sub-second live preview for English dictation. Optional — \
                 if absent, the live preview falls back to the v3 commit \
                 model with LocalAgreement-2."
                    .to_string(),
            ),
            size_bytes: 1_200_000_000, // ~1.2 GB full precision
            downloaded: false,
        },
    ]
}

/// Check which models are actually downloaded in the models directory.
/// A model is "downloaded" if its directory contains a .onnx file and the
/// expected vocabulary file (vocab.txt for Parakeet, tokenizer.model for
/// Nemotron-style streaming models).
pub fn list_models_with_status(models_dir: &Path) -> Vec<ModelInfo> {
    let mut models = available_models();
    for model in &mut models {
        let dir = model_path(models_dir, &model.id);
        let has_vocab = dir.join("vocab.txt").exists() || dir.join("tokenizer.model").exists();
        model.downloaded = dir.exists() && has_onnx_file(&dir) && has_vocab;
    }
    models
}

/// Get the expected directory path for a model.
pub fn model_path(models_dir: &Path, model_id: &str) -> PathBuf {
    models_dir.join(model_id)
}

/// Check if a directory contains at least one .onnx file.
fn has_onnx_file(dir: &Path) -> bool {
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            if entry.path().extension().and_then(|s| s.to_str()) == Some("onnx") {
                return true;
            }
        }
    }
    false
}
