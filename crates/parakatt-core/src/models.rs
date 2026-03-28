/// Model registry and management.
///
/// Tracks available models, their download status, and provides
/// metadata for the settings UI.

use std::path::{Path, PathBuf};

use crate::ModelInfo;

/// Known models that can be downloaded and used.
pub fn available_models() -> Vec<ModelInfo> {
    vec![
        ModelInfo {
            id: "parakeet-tdt-0.6b-v2".to_string(),
            provider_type: "parakeet".to_string(),
            display_name: "Parakeet TDT 0.6B v2 (English)".to_string(),
            description: Some(
                "NVIDIA Parakeet. Fast and accurate for English. Requires ONNX model files."
                    .to_string(),
            ),
            size_bytes: 2_500_000_000, // ~2.5GB full precision
            downloaded: false,
        },
        ModelInfo {
            id: "parakeet-tdt-0.6b-v3".to_string(),
            provider_type: "parakeet".to_string(),
            display_name: "Parakeet TDT 0.6B v3 (Multilingual)".to_string(),
            description: Some(
                "NVIDIA Parakeet. 25 languages. Requires ONNX model files.".to_string(),
            ),
            size_bytes: 2_500_000_000,
            downloaded: false,
        },
    ]
}

/// Check which models are actually downloaded in the models directory.
/// A Parakeet model is "downloaded" if its directory contains a .onnx file and vocab.txt.
pub fn list_models_with_status(models_dir: &Path) -> Vec<ModelInfo> {
    let mut models = available_models();
    for model in &mut models {
        let dir = model_path(models_dir, &model.id);
        model.downloaded = dir.exists()
            && has_onnx_file(&dir)
            && dir.join("vocab.txt").exists();
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
            if entry
                .path()
                .extension()
                .and_then(|s| s.to_str())
                == Some("onnx")
            {
                return true;
            }
        }
    }
    false
}
