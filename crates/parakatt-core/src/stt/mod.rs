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

    /// Live chunks need word timing before overlap removal and sentence grouping.
    /// Providers without word timing retain crossing sentences in the session adapter.
    fn transcribe_chunk(
        &self,
        audio: &[f32],
        sample_rate: u32,
        _overlap_secs: f64,
    ) -> Result<TranscriptionResult, CoreError> {
        self.transcribe(audio, sample_rate)
    }

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

/// Group retained model-timed words only after overlap gating. No timing is invented.
pub(crate) fn group_timed_words(
    words: Vec<crate::TimestampedSegment>,
) -> Vec<crate::TimestampedSegment> {
    let mut grouped: Vec<crate::TimestampedSegment> = Vec::new();
    for word in words {
        let append = grouped.last().is_some_and(|previous| {
            !previous.text.ends_with(['.', '?', '!'])
                && word.start_secs - previous.end_secs < 1.0
                && previous.text.chars().count() + word.text.chars().count() < 160
        });
        if append {
            let previous = grouped.last_mut().unwrap();
            previous.text.push(' ');
            previous.text.push_str(&word.text);
            previous.end_secs = word.end_secs;
        } else {
            grouped.push(word);
        }
    }
    grouped
}
