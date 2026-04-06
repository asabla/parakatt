/// Stateful streaming-ASR providers (live preview path).
///
/// This is the parallel of [`SttProvider`] for cache-aware models that
/// keep encoder/decoder state across calls. The shape is intentionally
/// different:
///
///   * `SttProvider::transcribe` is **stateless** — give it a buffer,
///     get a transcript. The caller can call it any number of times
///     concurrently with no setup. Used by the *commit* path.
///
///   * `StreamingProvider` is **stateful** — the model maintains an
///     attention/conv KV cache across `feed_chunk` calls and the
///     transcript grows incrementally. The caller must `start_session`
///     once, then feed audio in small chunks (160–560 ms), and
///     `finish_session` to release per-session state. Used by the
///     *live preview* path with cache-aware streaming Parakeet
///     (Nemotron) and similar models.
///
/// The trait deliberately exposes a session handle (`Box<dyn Any>`)
/// so a single provider can host multiple concurrent sessions, e.g.
/// one per active recording. The provider owns the model weights;
/// the session owns the transient state.
use std::any::Any;

use crate::CoreError;

/// Output from a single `feed_chunk` call.
#[derive(Debug, Clone, Default)]
pub struct StreamChunkResult {
    /// Tokens decoded from THIS chunk only — these are deltas. The
    /// caller can derive the full running transcript by concatenating
    /// `text` across all calls (or by calling `transcript()` if the
    /// provider exposes it).
    pub text: String,
}

/// Trait for stateful streaming ASR.
///
/// Lifecycle:
///   ```text
///   let session = provider.start_session()?;
///   provider.feed_chunk(&mut session, samples_a)?;
///   provider.feed_chunk(&mut session, samples_b)?;
///   ...
///   let final_text = provider.finish_session(session)?;
///   ```
pub trait StreamingProvider: Send + Sync {
    /// Open a new streaming session. Returns an opaque state handle
    /// that the caller passes back into `feed_chunk` and
    /// `finish_session`. The implementation is free to store the
    /// model state inside the box, on a Mutex inside the provider,
    /// or anywhere else.
    fn start_session(&self) -> Result<Box<dyn StreamingSession>, CoreError>;

    /// Provider name (model id, e.g. "nemotron-speech-streaming-en-0.6b").
    fn name(&self) -> &str;

    /// Whether the provider has a usable model loaded.
    fn is_loaded(&self) -> bool;

    /// Native chunk size in samples — the provider's preferred
    /// granularity for `feed_chunk`. The audio plumbing layer
    /// should accumulate at least this many samples before calling
    /// `feed_chunk`. Returning 0 means "any size is fine".
    fn native_chunk_samples(&self) -> usize;
}

/// Per-session streaming state. Implementations hold whatever the
/// underlying model needs (e.g. a `parakeet_rs::Nemotron` instance).
pub trait StreamingSession: Send + Any {
    /// Feed a chunk of 16 kHz mono f32 PCM into the session and
    /// return whatever new text was decoded by it. May return an
    /// empty string if the chunk was below the model's internal
    /// frame threshold — that's normal, just keep feeding.
    fn feed_chunk(&mut self, audio: &[f32]) -> Result<StreamChunkResult, CoreError>;

    /// The full running transcript accumulated across all
    /// `feed_chunk` calls so far. Used by LocalAgreement-2 to
    /// compute the longest common prefix between consecutive passes.
    fn current_transcript(&self) -> String;

    /// Reset the session state without releasing the model. Used
    /// when the caller wants to start a fresh utterance on the same
    /// session handle.
    fn reset(&mut self);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// In-memory dummy provider used by other tests in the crate to
    /// exercise the streaming pipeline without loading a real ONNX
    /// model. Each `feed_chunk` returns a fake "tok-N" token where
    /// N counts the chunks fed so far.
    pub(crate) struct DummyStreamingProvider;

    pub(crate) struct DummyStreamingSession {
        pub fed_chunks: usize,
        pub transcript: String,
    }

    impl StreamingProvider for DummyStreamingProvider {
        fn start_session(&self) -> Result<Box<dyn StreamingSession>, CoreError> {
            Ok(Box::new(DummyStreamingSession {
                fed_chunks: 0,
                transcript: String::new(),
            }))
        }
        fn name(&self) -> &str {
            "dummy"
        }
        fn is_loaded(&self) -> bool {
            true
        }
        fn native_chunk_samples(&self) -> usize {
            0
        }
    }

    impl StreamingSession for DummyStreamingSession {
        fn feed_chunk(&mut self, _audio: &[f32]) -> Result<StreamChunkResult, CoreError> {
            self.fed_chunks += 1;
            let tok = format!("tok-{}", self.fed_chunks);
            if !self.transcript.is_empty() {
                self.transcript.push(' ');
            }
            self.transcript.push_str(&tok);
            Ok(StreamChunkResult { text: tok })
        }
        fn current_transcript(&self) -> String {
            self.transcript.clone()
        }
        fn reset(&mut self) {
            self.fed_chunks = 0;
            self.transcript.clear();
        }
    }

    #[test]
    fn dummy_provider_lifecycle() {
        let p = DummyStreamingProvider;
        let mut s = p.start_session().unwrap();
        assert_eq!(s.feed_chunk(&[]).unwrap().text, "tok-1");
        assert_eq!(s.feed_chunk(&[]).unwrap().text, "tok-2");
        assert_eq!(s.current_transcript(), "tok-1 tok-2");
        s.reset();
        assert_eq!(s.current_transcript(), "");
    }
}
