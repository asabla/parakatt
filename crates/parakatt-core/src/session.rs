/// Session-based chunked transcription for long-form audio (meetings, etc.).
///
/// Audio is processed in fixed-size chunks with overlap to avoid word splitting
/// at boundaries. Each chunk is independently transcribed via STT, then
/// overlap-deduplication stitches the results into a continuous transcript.

use std::collections::HashMap;

use crate::CoreError;

/// Result of processing a single audio chunk.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ChunkResult {
    /// New text from this chunk (after overlap dedup).
    pub text: String,
    /// Zero-based index of this chunk.
    pub chunk_index: u32,
    /// Accumulated full transcript so far.
    pub accumulated_text: String,
}

/// Internal state for a running transcription session.
struct SessionState {
    /// Full accumulated transcript text.
    accumulated_text: String,
    /// Trailing words from the previous chunk, used for overlap dedup.
    prev_trailing_words: Vec<String>,
    /// Number of chunks processed so far.
    chunk_count: u32,
    /// Total audio duration processed (seconds).
    total_duration_secs: f64,
}

/// Manages multiple concurrent transcription sessions.
pub struct SessionManager {
    sessions: HashMap<String, SessionState>,
}

/// Number of words to compare for overlap deduplication.
const OVERLAP_WORD_COUNT: usize = 8;

impl SessionManager {
    pub fn new() -> Self {
        Self {
            sessions: HashMap::new(),
        }
    }

    /// Start a new transcription session.
    pub fn start(&mut self, session_id: &str) -> Result<(), CoreError> {
        if self.sessions.contains_key(session_id) {
            return Err(CoreError::TranscriptionFailed(format!(
                "Session already exists: {session_id}"
            )));
        }

        self.sessions.insert(
            session_id.to_string(),
            SessionState {
                accumulated_text: String::new(),
                prev_trailing_words: Vec::new(),
                chunk_count: 0,
                total_duration_secs: 0.0,
            },
        );

        Ok(())
    }

    /// Process a chunk's STT result and stitch it into the session transcript.
    ///
    /// `raw_text` is the STT output for this chunk (caller runs STT externally).
    /// `chunk_duration_secs` is the audio duration of this chunk.
    pub fn add_chunk(
        &mut self,
        session_id: &str,
        raw_text: &str,
        chunk_duration_secs: f64,
    ) -> Result<ChunkResult, CoreError> {
        let state = self.sessions.get_mut(session_id).ok_or_else(|| {
            CoreError::TranscriptionFailed(format!("Session not found: {session_id}"))
        })?;

        let chunk_index = state.chunk_count;
        let new_text = if chunk_index == 0 {
            // First chunk — no dedup needed.
            raw_text.to_string()
        } else {
            deduplicate_overlap(&state.prev_trailing_words, raw_text)
        };

        // Update trailing words for next chunk's dedup.
        let all_words: Vec<String> = raw_text
            .split_whitespace()
            .map(|w| w.to_string())
            .collect();
        state.prev_trailing_words = all_words
            .iter()
            .rev()
            .take(OVERLAP_WORD_COUNT)
            .rev()
            .cloned()
            .collect();

        // Append to accumulated text.
        if !new_text.is_empty() {
            if !state.accumulated_text.is_empty() {
                state.accumulated_text.push(' ');
            }
            state.accumulated_text.push_str(&new_text);
        }

        state.chunk_count += 1;
        state.total_duration_secs += chunk_duration_secs;

        Ok(ChunkResult {
            text: new_text,
            chunk_index,
            accumulated_text: state.accumulated_text.clone(),
        })
    }

    /// Finish a session and return the full accumulated text.
    /// Removes the session from the manager.
    pub fn finish(&mut self, session_id: &str) -> Result<(String, f64), CoreError> {
        let state = self.sessions.remove(session_id).ok_or_else(|| {
            CoreError::TranscriptionFailed(format!("Session not found: {session_id}"))
        })?;

        Ok((state.accumulated_text, state.total_duration_secs))
    }

    /// Cancel and remove a session without returning results.
    pub fn cancel(&mut self, session_id: &str) {
        self.sessions.remove(session_id);
    }

    /// Check if a session exists.
    pub fn has_session(&self, session_id: &str) -> bool {
        self.sessions.contains_key(session_id)
    }
}

/// Remove overlapping words between the end of the previous chunk and the
/// start of the current chunk's STT output.
///
/// Finds the longest suffix of `prev_trailing` that matches a prefix of
/// `current_text` (word-level, case-insensitive), then strips that prefix.
fn deduplicate_overlap(prev_trailing: &[String], current_text: &str) -> String {
    if prev_trailing.is_empty() || current_text.is_empty() {
        return current_text.to_string();
    }

    let current_words: Vec<&str> = current_text.split_whitespace().collect();
    if current_words.is_empty() {
        return String::new();
    }

    // Try progressively shorter suffixes of prev_trailing as a prefix of current_words.
    let max_check = prev_trailing.len().min(current_words.len());

    let mut best_overlap = 0;
    for suffix_len in (1..=max_check).rev() {
        let suffix = &prev_trailing[prev_trailing.len() - suffix_len..];
        let prefix = &current_words[..suffix_len];

        if suffix
            .iter()
            .zip(prefix.iter())
            .all(|(a, b)| a.to_lowercase() == b.to_lowercase())
        {
            best_overlap = suffix_len;
            break;
        }
    }

    if best_overlap == 0 {
        current_text.to_string()
    } else {
        current_words[best_overlap..].join(" ")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_deduplicate_overlap_no_overlap() {
        let prev = vec!["hello".into(), "world".into()];
        let current = "foo bar baz";
        assert_eq!(deduplicate_overlap(&prev, current), "foo bar baz");
    }

    #[test]
    fn test_deduplicate_overlap_partial() {
        let prev = vec![
            "the".into(),
            "quick".into(),
            "brown".into(),
            "fox".into(),
        ];
        let current = "brown fox jumps over";
        assert_eq!(deduplicate_overlap(&prev, current), "jumps over");
    }

    #[test]
    fn test_deduplicate_overlap_full() {
        let prev = vec!["hello".into(), "world".into()];
        let current = "hello world and more";
        assert_eq!(deduplicate_overlap(&prev, current), "and more");
    }

    #[test]
    fn test_deduplicate_overlap_case_insensitive() {
        let prev = vec!["Hello".into(), "World".into()];
        let current = "hello world more text";
        assert_eq!(deduplicate_overlap(&prev, current), "more text");
    }

    #[test]
    fn test_deduplicate_overlap_empty_prev() {
        let prev: Vec<String> = vec![];
        let current = "some text here";
        assert_eq!(deduplicate_overlap(&prev, current), "some text here");
    }

    #[test]
    fn test_deduplicate_overlap_empty_current() {
        let prev = vec!["hello".into()];
        assert_eq!(deduplicate_overlap(&prev, ""), "");
    }

    #[test]
    fn test_session_lifecycle() {
        let mut mgr = SessionManager::new();

        mgr.start("test-1").unwrap();
        assert!(mgr.has_session("test-1"));

        // First chunk
        let r1 = mgr.add_chunk("test-1", "hello world this is chunk one", 30.0).unwrap();
        assert_eq!(r1.chunk_index, 0);
        assert_eq!(r1.text, "hello world this is chunk one");

        // Second chunk with overlap ("chunk one" repeated)
        let r2 = mgr.add_chunk("test-1", "chunk one and here is chunk two", 30.0).unwrap();
        assert_eq!(r2.chunk_index, 1);
        assert_eq!(r2.text, "and here is chunk two");
        assert_eq!(
            r2.accumulated_text,
            "hello world this is chunk one and here is chunk two"
        );

        // Finish
        let (text, duration) = mgr.finish("test-1").unwrap();
        assert_eq!(text, "hello world this is chunk one and here is chunk two");
        assert!((duration - 60.0).abs() < 0.01);
        assert!(!mgr.has_session("test-1"));
    }

    #[test]
    fn test_session_cancel() {
        let mut mgr = SessionManager::new();
        mgr.start("cancel-me").unwrap();
        mgr.add_chunk("cancel-me", "some text", 10.0).unwrap();
        mgr.cancel("cancel-me");
        assert!(!mgr.has_session("cancel-me"));
    }

    #[test]
    fn test_duplicate_session_id() {
        let mut mgr = SessionManager::new();
        mgr.start("dup").unwrap();
        assert!(mgr.start("dup").is_err());
    }
}
