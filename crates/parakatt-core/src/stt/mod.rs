/// Speech-to-text provider trait and implementations.
pub mod parakeet;

use crate::{CoreError, TranscriptionResult};

/// Trait that all STT backends must implement.
pub trait SttProvider: Send + Sync {
    /// Transcribe audio samples (16kHz mono f32) into text.
    fn transcribe(&self, audio: &[f32], sample_rate: u32)
        -> Result<TranscriptionResult, CoreError>;

    /// Provider name for display and logging.
    fn name(&self) -> &str;

    /// Whether a model is currently loaded and ready.
    fn is_loaded(&self) -> bool;
}
