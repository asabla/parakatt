/// Speech-to-text provider trait and implementations.
pub mod nemotron;
pub mod parakeet;
pub mod streaming;

pub use streaming::{
    ScriptedStreamingProvider, ScriptedStreamingSession, StreamChunkResult, StreamingProvider,
    StreamingSession,
};

use crate::{CoreError, TranscriptionResult};

/// Trait that all *batch / commit-path* STT backends must implement.
///
/// For *streaming / live-preview* backends see [`StreamingProvider`]
/// in `streaming.rs`.
pub trait SttProvider: Send + Sync {
    fn backend(&self) -> crate::speech::SpeechBackend {
        crate::speech::SpeechBackend::Cpu
    }
    /// Transcribe audio samples (16kHz mono f32) into text.
    fn transcribe(&self, audio: &[f32], sample_rate: u32)
        -> Result<TranscriptionResult, CoreError>;

    /// Imported media uses word timing at overlap boundaries when supported.
    fn transcribe_import(
        &self,
        audio: &[f32],
        sample_rate: u32,
    ) -> Result<TranscriptionResult, CoreError> {
        self.transcribe(audio, sample_rate)
    }

    /// Provider name for display and logging.
    fn name(&self) -> &str;

    /// Whether a model is currently loaded and ready.
    fn is_loaded(&self) -> bool;
}
