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

// =============================================================
// Scriptable in-memory streaming provider used by integration
// tests across the crate. Lives in the main module (not under
// #[cfg(test)]) so it's reachable from `tests/*.rs` integration
// files. Real builds never run a ScriptedStreamingProvider in
// production code paths — it's only constructed by tests.
// =============================================================

use std::sync::Mutex;

/// A streaming provider whose output is fully scripted by the test.
/// Each `feed_chunk` call advances an internal cursor through a
/// pre-set list of "hypotheses" — each hypothesis is the FULL
/// running transcript that the model would have produced after that
/// chunk. (This matches the way real cache-aware streaming models
/// work: each chunk causes the model's accumulated output to be
/// extended or revised.)
///
/// Configuration knobs:
///   - `hypotheses`: ordered list of full transcripts, one per chunk
///   - `feed_latency_ms`: artificial sleep inside `feed_chunk`
///   - `error_at_chunk`: if `Some(n)`, the n-th feed_chunk returns Err
///
/// When chunks exceed the scripted list, the provider keeps emitting
/// the LAST hypothesis indefinitely (simulating "no new audio").
pub struct ScriptedStreamingProvider {
    pub hypotheses: Vec<String>,
    pub feed_latency_ms: u64,
    pub error_at_chunk: Option<usize>,
    pub native_chunk: usize,
    pub name: String,
}

impl ScriptedStreamingProvider {
    /// Build a provider with a fixed sequence of full-transcript
    /// hypotheses. The Nth `feed_chunk` returns the Nth hypothesis
    /// as the new running transcript.
    pub fn new(hypotheses: Vec<&str>) -> Self {
        Self {
            hypotheses: hypotheses.into_iter().map(String::from).collect(),
            feed_latency_ms: 0,
            error_at_chunk: None,
            native_chunk: 0,
            name: "scripted-streaming".to_string(),
        }
    }

    pub fn with_latency(mut self, ms: u64) -> Self {
        self.feed_latency_ms = ms;
        self
    }

    pub fn with_error_at(mut self, chunk: usize) -> Self {
        self.error_at_chunk = Some(chunk);
        self
    }

    pub fn with_native_chunk(mut self, samples: usize) -> Self {
        self.native_chunk = samples;
        self
    }
}

impl StreamingProvider for ScriptedStreamingProvider {
    fn start_session(&self) -> Result<Box<dyn StreamingSession>, CoreError> {
        Ok(Box::new(ScriptedStreamingSession {
            hypotheses: self.hypotheses.clone(),
            feed_latency_ms: self.feed_latency_ms,
            error_at_chunk: self.error_at_chunk,
            cursor: Mutex::new(0),
            transcript: Mutex::new(String::new()),
        }))
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn is_loaded(&self) -> bool {
        true
    }

    fn native_chunk_samples(&self) -> usize {
        self.native_chunk
    }
}

pub struct ScriptedStreamingSession {
    hypotheses: Vec<String>,
    feed_latency_ms: u64,
    error_at_chunk: Option<usize>,
    cursor: Mutex<usize>,
    transcript: Mutex<String>,
}

impl StreamingSession for ScriptedStreamingSession {
    fn feed_chunk(&mut self, _audio: &[f32]) -> Result<StreamChunkResult, CoreError> {
        if self.feed_latency_ms > 0 {
            std::thread::sleep(std::time::Duration::from_millis(self.feed_latency_ms));
        }

        let mut cursor = self.cursor.lock().unwrap();
        let chunk_index = *cursor;
        *cursor += 1;

        if let Some(err_at) = self.error_at_chunk {
            if chunk_index == err_at {
                return Err(CoreError::TranscriptionFailed(format!(
                    "scripted error at chunk {chunk_index}"
                )));
            }
        }

        // Pick the scripted hypothesis (clamp to last entry once
        // we've consumed the script).
        let new_full = if self.hypotheses.is_empty() {
            String::new()
        } else if chunk_index < self.hypotheses.len() {
            self.hypotheses[chunk_index].clone()
        } else {
            self.hypotheses
                .last()
                .cloned()
                .unwrap_or_default()
        };

        // Compute delta vs the previous transcript.
        let mut transcript = self.transcript.lock().unwrap();
        let delta = if new_full.starts_with(&*transcript) {
            new_full[transcript.len()..].trim_start().to_string()
        } else {
            // Hypothesis revision (shouldn't happen with monotonic
            // streams but the test API supports it).
            new_full.clone()
        };
        *transcript = new_full;

        Ok(StreamChunkResult { text: delta })
    }

    fn current_transcript(&self) -> String {
        self.transcript.lock().unwrap().clone()
    }

    fn reset(&mut self) {
        *self.cursor.lock().unwrap() = 0;
        self.transcript.lock().unwrap().clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scripted_provider_emits_hypotheses_in_order() {
        let p = ScriptedStreamingProvider::new(vec!["hello", "hello world", "hello world and more"]);
        let mut s = p.start_session().unwrap();
        assert_eq!(s.feed_chunk(&[]).unwrap().text, "hello");
        assert_eq!(s.current_transcript(), "hello");
        assert_eq!(s.feed_chunk(&[]).unwrap().text, "world");
        assert_eq!(s.current_transcript(), "hello world");
        assert_eq!(s.feed_chunk(&[]).unwrap().text, "and more");
        assert_eq!(s.current_transcript(), "hello world and more");
    }

    #[test]
    fn scripted_provider_clamps_past_end_of_script() {
        let p = ScriptedStreamingProvider::new(vec!["one"]);
        let mut s = p.start_session().unwrap();
        assert_eq!(s.feed_chunk(&[]).unwrap().text, "one");
        // Past end → still returns "one" as the running transcript,
        // delta is empty (no new tokens).
        let r = s.feed_chunk(&[]).unwrap();
        assert_eq!(r.text, "");
        assert_eq!(s.current_transcript(), "one");
    }

    #[test]
    fn scripted_provider_error_injection() {
        let p = ScriptedStreamingProvider::new(vec!["a", "b", "c"]).with_error_at(1);
        let mut s = p.start_session().unwrap();
        assert!(s.feed_chunk(&[]).is_ok());
        assert!(s.feed_chunk(&[]).is_err());
        // Cursor still advanced past the error so the next call
        // returns the next hypothesis.
        assert!(s.feed_chunk(&[]).is_ok());
    }

    #[test]
    fn scripted_provider_reset_rewinds_cursor() {
        // Real streaming models emit a *growing full transcript*
        // at each chunk, not isolated tokens — hypotheses must
        // contain the cumulative text.
        let p = ScriptedStreamingProvider::new(vec!["a", "a b"]);
        let mut s = p.start_session().unwrap();
        let _ = s.feed_chunk(&[]);
        let _ = s.feed_chunk(&[]);
        assert_eq!(s.current_transcript(), "a b");
        s.reset();
        assert_eq!(s.current_transcript(), "");
        assert_eq!(s.feed_chunk(&[]).unwrap().text, "a");
    }

    #[test]
    fn scripted_provider_with_latency_does_sleep() {
        let p = ScriptedStreamingProvider::new(vec!["x"]).with_latency(10);
        let mut s = p.start_session().unwrap();
        let start = std::time::Instant::now();
        let _ = s.feed_chunk(&[]);
        assert!(start.elapsed().as_millis() >= 10);
    }
}
