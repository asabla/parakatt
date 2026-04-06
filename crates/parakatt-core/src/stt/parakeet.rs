/// Parakeet TDT STT provider using parakeet-rs (NVIDIA Parakeet via ONNX Runtime).
///
/// Runs on CPU which is fast enough on Apple Silicon.
/// The model directory should contain:
/// - encoder-model.onnx + encoder-model.onnx.data
/// - decoder_joint-model.onnx
/// - vocab.txt
use std::path::Path;
use std::sync::Mutex;

use parakeet_rs::{ParakeetTDT, TimestampMode, Transcriber};

use crate::{CoreError, TimestampedSegment, TranscriptionResult};

use super::SttProvider;

pub struct ParakeetProvider {
    model: Mutex<ParakeetTDT>,
    model_id: String,
}

impl ParakeetProvider {
    /// Load a Parakeet TDT model from a directory containing ONNX files.
    pub fn load(model_dir: &Path, model_id: &str) -> Result<Self, CoreError> {
        if !model_dir.exists() {
            return Err(CoreError::ModelNotFound(format!(
                "Model directory not found: {}",
                model_dir.display()
            )));
        }

        let model = ParakeetTDT::from_pretrained(model_dir, None).map_err(|e| {
            CoreError::ModelLoadFailed(format!("Failed to load Parakeet TDT model: {e}"))
        })?;

        log::info!("Loaded Parakeet TDT model: {}", model_id);

        Ok(Self {
            model: Mutex::new(model),
            model_id: model_id.to_string(),
        })
    }
}

impl SttProvider for ParakeetProvider {
    fn transcribe(
        &self,
        audio: &[f32],
        sample_rate: u32,
    ) -> Result<TranscriptionResult, CoreError> {
        let start = std::time::Instant::now();

        let mut model = self.model.lock().map_err(|e| {
            CoreError::TranscriptionFailed(format!("Failed to acquire model lock: {e}"))
        })?;

        let result = model
            .transcribe_samples(audio.to_vec(), sample_rate, 1, Some(TimestampMode::Sentences))
            .map_err(|e| {
                CoreError::TranscriptionFailed(format!("Parakeet transcription failed: {e}"))
            })?;

        let duration = start.elapsed();
        let text = result.text.trim().to_string();

        // Extract sentence-level timestamps from parakeet-rs TimedToken.
        let segments: Vec<TimestampedSegment> = result
            .tokens
            .iter()
            .filter(|t| !t.text.trim().is_empty())
            .map(|t| TimestampedSegment {
                text: t.text.trim().to_string(),
                start_secs: t.start as f64,
                end_secs: t.end as f64,
            })
            .collect();

        log::debug!(
            "Parakeet transcribed {} samples in {:.2}s ({} segments): '{}'",
            audio.len(),
            duration.as_secs_f64(),
            segments.len(),
            &text
        );

        Ok(TranscriptionResult {
            text,
            duration_secs: duration.as_secs_f64(),
            provider_name: self.name().to_string(),
            segments,
            llm_error: None,
        })
    }

    fn name(&self) -> &str {
        &self.model_id
    }

    fn is_loaded(&self) -> bool {
        true
    }
}
