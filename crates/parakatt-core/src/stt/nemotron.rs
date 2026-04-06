/// Nemotron streaming ASR provider — wraps `parakeet_rs::Nemotron`.
///
/// This is the live-preview path. The model is cache-aware: it
/// maintains an attention/conv KV cache across calls and produces
/// new tokens incrementally as audio arrives, rather than re-encoding
/// a growing buffer like the offline TDT model. This is what makes
/// sub-second first-token latency possible.
///
/// One [`NemotronProvider`] holds the model weights; each
/// [`NemotronSession`] holds the per-recording cache state. The model
/// itself is `Mutex`-guarded inside the session because
/// `parakeet_rs::Nemotron::transcribe_chunk` takes `&mut self`.
use std::path::Path;
use std::sync::Mutex;

use parakeet_rs::Nemotron;

use crate::stt::streaming::{StreamChunkResult, StreamingProvider, StreamingSession};
use crate::CoreError;

/// Native chunk size for parakeet-rs Nemotron — 56 mel frames at
/// 10 ms hop = 560 ms of audio = 8960 samples at 16 kHz. This is
/// the canonical "low latency" config from the NVIDIA blog post.
pub const NEMOTRON_NATIVE_CHUNK_SAMPLES: usize = 8_960;

#[derive(Debug)]
pub struct NemotronProvider {
    model_dir: std::path::PathBuf,
    model_id: String,
    /// Set to `true` once `start_session` has succeeded at least
    /// once. Loading the model is deferred to the first session so
    /// the engine can hold a `NemotronProvider` cheaply even if no
    /// streaming session ever runs.
    is_loaded: std::sync::atomic::AtomicBool,
}

impl NemotronProvider {
    /// Construct a provider that knows where to find the model files
    /// but does not load them yet. Loading happens lazily on the
    /// first `start_session` call.
    pub fn new(model_dir: &Path, model_id: &str) -> Result<Self, CoreError> {
        if !model_dir.exists() {
            return Err(CoreError::ModelNotFound(format!(
                "Nemotron model directory not found: {}",
                model_dir.display()
            )));
        }
        // Verify the expected files are present so we fail at construct
        // time rather than at first session start.
        for required in ["encoder.onnx", "decoder_joint.onnx", "tokenizer.model"] {
            if !model_dir.join(required).exists() {
                return Err(CoreError::ModelNotFound(format!(
                    "Nemotron model directory missing required file '{}': {}",
                    required,
                    model_dir.display()
                )));
            }
        }
        Ok(Self {
            model_dir: model_dir.to_path_buf(),
            model_id: model_id.to_string(),
            is_loaded: std::sync::atomic::AtomicBool::new(false),
        })
    }
}

impl StreamingProvider for NemotronProvider {
    fn start_session(&self) -> Result<Box<dyn StreamingSession>, CoreError> {
        let model = Nemotron::from_pretrained(&self.model_dir, None).map_err(|e| {
            CoreError::ModelLoadFailed(format!("Failed to load Nemotron model: {e}"))
        })?;
        self.is_loaded
            .store(true, std::sync::atomic::Ordering::Relaxed);
        log::info!("Loaded Nemotron streaming session: {}", self.model_id);
        Ok(Box::new(NemotronSession {
            model: Mutex::new(model),
            transcript: String::new(),
        }))
    }

    fn name(&self) -> &str {
        &self.model_id
    }

    fn is_loaded(&self) -> bool {
        self.is_loaded.load(std::sync::atomic::Ordering::Relaxed)
    }

    fn native_chunk_samples(&self) -> usize {
        NEMOTRON_NATIVE_CHUNK_SAMPLES
    }
}

pub struct NemotronSession {
    model: Mutex<Nemotron>,
    /// Cached running transcript so `current_transcript()` is cheap.
    /// We rebuild this from the model's internal state on every
    /// `feed_chunk` so it stays in sync with whatever parakeet-rs
    /// has accumulated.
    transcript: String,
}

impl StreamingSession for NemotronSession {
    fn feed_chunk(&mut self, audio: &[f32]) -> Result<StreamChunkResult, CoreError> {
        let mut model = self.model.lock().map_err(|e| {
            CoreError::TranscriptionFailed(format!("Nemotron session lock poisoned: {e}"))
        })?;
        let delta = model.transcribe_chunk(audio).map_err(|e| {
            CoreError::TranscriptionFailed(format!("Nemotron transcribe_chunk failed: {e}"))
        })?;
        // The crate's `transcribe_chunk` returns the *new* tokens
        // decoded from this chunk only — append to our cached running
        // transcript so `current_transcript()` is O(1).
        if !delta.is_empty() {
            if !self.transcript.is_empty() && !delta.starts_with(' ') {
                self.transcript.push(' ');
            }
            self.transcript.push_str(delta.trim_start());
        }
        Ok(StreamChunkResult { text: delta })
    }

    fn current_transcript(&self) -> String {
        self.transcript.clone()
    }

    fn reset(&mut self) {
        if let Ok(mut model) = self.model.lock() {
            model.reset();
        }
        self.transcript.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::Ordering;

    #[test]
    fn provider_construction_requires_model_dir() {
        let tmp = std::env::temp_dir().join("parakatt-test-no-such-nemotron-dir");
        let _ = std::fs::remove_dir_all(&tmp);
        assert!(NemotronProvider::new(&tmp, "nemotron-test").is_err());
    }

    #[test]
    fn provider_construction_requires_expected_files() {
        let tmp = std::env::temp_dir().join("parakatt-test-empty-nemotron-dir");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        let result = NemotronProvider::new(&tmp, "nemotron-test");
        assert!(result.is_err());
        let err = result.unwrap_err();
        let msg = format!("{err:?}");
        assert!(
            msg.contains("encoder.onnx") || msg.contains("Nemotron"),
            "expected message to mention missing encoder.onnx, got: {msg}"
        );
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn is_loaded_starts_false() {
        // Make a fake model dir that satisfies the file-existence
        // check (empty files are fine for the construction guard).
        let tmp = std::env::temp_dir().join("parakatt-test-fake-nemotron-files");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        std::fs::write(tmp.join("encoder.onnx"), b"").unwrap();
        std::fs::write(tmp.join("decoder_joint.onnx"), b"").unwrap();
        std::fs::write(tmp.join("tokenizer.model"), b"").unwrap();

        let provider = NemotronProvider::new(&tmp, "nemotron-fake").unwrap();
        assert!(!provider.is_loaded.load(Ordering::Relaxed));
        assert_eq!(provider.name(), "nemotron-fake");
        assert_eq!(
            provider.native_chunk_samples(),
            NEMOTRON_NATIVE_CHUNK_SAMPLES
        );
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
