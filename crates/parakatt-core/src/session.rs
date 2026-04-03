/// Session-based chunked transcription for long-form audio (meetings, etc.).
///
/// Audio is processed in fixed-size chunks with overlap to avoid word splitting
/// at boundaries. Each chunk is independently transcribed via STT, then
/// overlap-deduplication stitches the results into a continuous transcript.

use std::collections::HashMap;

use crate::{CoreError, TimestampedSegment};

/// Result of processing a single audio chunk.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ChunkResult {
    /// New text from this chunk (after overlap dedup).
    pub text: String,
    /// Zero-based index of this chunk.
    pub chunk_index: u32,
    /// Accumulated full transcript so far.
    pub accumulated_text: String,
    /// Sentence-level timestamp segments for this chunk.
    pub segments: Vec<TimestampedSegment>,
    /// Offset in seconds from session start for this chunk's timestamps.
    pub chunk_offset_secs: f64,
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
    /// All segments accumulated across chunks, with absolute timestamps.
    accumulated_segments: Vec<TimestampedSegment>,
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
                accumulated_segments: Vec::new(),
            },
        );

        Ok(())
    }

    /// Process a chunk's STT result and stitch it into the session transcript.
    ///
    /// `raw_text` is the STT output for this chunk (caller runs STT externally).
    /// `chunk_duration_secs` is the audio duration of this chunk.
    /// `segments` are the sentence-level timestamp segments from STT for this chunk.
    pub fn add_chunk(
        &mut self,
        session_id: &str,
        raw_text: &str,
        chunk_duration_secs: f64,
        segments: Vec<TimestampedSegment>,
    ) -> Result<ChunkResult, CoreError> {
        let state = self.sessions.get_mut(session_id).ok_or_else(|| {
            CoreError::TranscriptionFailed(format!("Session not found: {session_id}"))
        })?;

        let chunk_index = state.chunk_count;
        let chunk_offset_secs = state.total_duration_secs;

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

        // Append to accumulated text with paragraph breaks between chunks.
        if !new_text.is_empty() {
            if !state.accumulated_text.is_empty() {
                state.accumulated_text.push_str("\n\n");
            }
            state.accumulated_text.push_str(&new_text);
        }

        // Accumulate segments with absolute timestamps (offset by chunk start).
        for seg in &segments {
            state.accumulated_segments.push(TimestampedSegment {
                text: seg.text.clone(),
                start_secs: chunk_offset_secs + seg.start_secs,
                end_secs: chunk_offset_secs + seg.end_secs,
            });
        }

        state.chunk_count += 1;
        state.total_duration_secs += chunk_duration_secs;

        Ok(ChunkResult {
            text: new_text,
            chunk_index,
            accumulated_text: state.accumulated_text.clone(),
            segments,
            chunk_offset_secs,
        })
    }

    /// Finish a session and return the full accumulated text + segments.
    /// Removes the session from the manager.
    pub fn finish(
        &mut self,
        session_id: &str,
    ) -> Result<(String, f64, Vec<TimestampedSegment>), CoreError> {
        let state = self.sessions.remove(session_id).ok_or_else(|| {
            CoreError::TranscriptionFailed(format!("Session not found: {session_id}"))
        })?;

        Ok((
            state.accumulated_text,
            state.total_duration_secs,
            state.accumulated_segments,
        ))
    }

    /// Cancel and remove a session without returning results.
    pub fn cancel(&mut self, session_id: &str) {
        self.sessions.remove(session_id);
    }

    /// Get the accumulated text for a session without consuming it.
    /// Use this instead of reading `accumulated_text` from `ChunkResult`
    /// to avoid cloning the full transcript on every chunk.
    pub fn get_session_text(&self, session_id: &str) -> Result<String, CoreError> {
        let state = self.sessions.get(session_id).ok_or_else(|| {
            CoreError::TranscriptionFailed(format!("Session not found: {session_id}"))
        })?;
        Ok(state.accumulated_text.clone())
    }

    /// Check if a session exists.
    pub fn has_session(&self, session_id: &str) -> bool {
        self.sessions.contains_key(session_id)
    }
}

/// Strip leading/trailing punctuation from a word for comparison purposes.
fn strip_punctuation(word: &str) -> &str {
    word.trim_matches(|c: char| c.is_ascii_punctuation())
}

/// Remove overlapping words between the end of the previous chunk and the
/// start of the current chunk's STT output.
///
/// Finds the longest suffix of `prev_trailing` that matches a prefix of
/// `current_text` (word-level, case-insensitive, punctuation-insensitive),
/// then strips that prefix.
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

        if suffix.iter().zip(prefix.iter()).all(|(a, b)| {
            strip_punctuation(a).to_lowercase() == strip_punctuation(b).to_lowercase()
        }) {
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
    fn test_deduplicate_overlap_with_punctuation() {
        let prev = vec!["the".into(), "quick".into(), "brown.".into()];
        let current = "brown jumps over";
        assert_eq!(deduplicate_overlap(&prev, current), "jumps over");
    }

    #[test]
    fn test_deduplicate_overlap_punctuation_both_sides() {
        let prev = vec!["hello,".into(), "world.".into()];
        let current = "hello, world! and more";
        assert_eq!(deduplicate_overlap(&prev, current), "and more");
    }

    #[test]
    fn test_session_lifecycle() {
        let mut mgr = SessionManager::new();

        mgr.start("test-1").unwrap();
        assert!(mgr.has_session("test-1"));

        // First chunk
        let r1 = mgr.add_chunk("test-1", "hello world this is chunk one", 30.0, vec![]).unwrap();
        assert_eq!(r1.chunk_index, 0);
        assert_eq!(r1.text, "hello world this is chunk one");
        assert!((r1.chunk_offset_secs - 0.0).abs() < 0.01);

        // Second chunk with overlap ("chunk one" repeated)
        let r2 = mgr.add_chunk("test-1", "chunk one and here is chunk two", 30.0, vec![]).unwrap();
        assert_eq!(r2.chunk_index, 1);
        assert_eq!(r2.text, "and here is chunk two");
        assert_eq!(
            r2.accumulated_text,
            "hello world this is chunk one\n\nand here is chunk two"
        );
        assert!((r2.chunk_offset_secs - 30.0).abs() < 0.01);

        // Finish
        let (text, duration, segments) = mgr.finish("test-1").unwrap();
        assert_eq!(text, "hello world this is chunk one\n\nand here is chunk two");
        assert!((duration - 60.0).abs() < 0.01);
        assert!(segments.is_empty()); // No segments passed in this test
        assert!(!mgr.has_session("test-1"));
    }

    #[test]
    fn test_session_cancel() {
        let mut mgr = SessionManager::new();
        mgr.start("cancel-me").unwrap();
        mgr.add_chunk("cancel-me", "some text", 10.0, vec![]).unwrap();
        mgr.cancel("cancel-me");
        assert!(!mgr.has_session("cancel-me"));
    }

    #[test]
    fn test_duplicate_session_id() {
        let mut mgr = SessionManager::new();
        mgr.start("dup").unwrap();
        assert!(mgr.start("dup").is_err());
    }

    #[test]
    fn test_many_chunks_long_recording() {
        // Simulates a long recording split into many overlapping chunks,
        // as done by processAudioChunked in AppState.swift (issue #6 fix).
        let mut mgr = SessionManager::new();
        mgr.start("long").unwrap();

        // Chunk 1: full new content
        let r1 = mgr.add_chunk("long", "the meeting started with introductions", 30.0, vec![]).unwrap();
        assert_eq!(r1.chunk_index, 0);
        assert_eq!(r1.text, "the meeting started with introductions");

        // Chunk 2: overlap on "with introductions"
        let r2 = mgr.add_chunk("long", "with introductions and then we discussed the budget", 30.0, vec![]).unwrap();
        assert_eq!(r2.chunk_index, 1);
        assert_eq!(r2.text, "and then we discussed the budget");

        // Chunk 3: overlap on "the budget"
        let r3 = mgr.add_chunk("long", "the budget was reviewed by the finance team", 30.0, vec![]).unwrap();
        assert_eq!(r3.chunk_index, 2);
        assert_eq!(r3.text, "was reviewed by the finance team");

        // Chunk 4: no overlap (clean boundary)
        let r4 = mgr.add_chunk("long", "next steps were assigned to everyone", 30.0, vec![]).unwrap();
        assert_eq!(r4.chunk_index, 3);
        assert_eq!(r4.text, "next steps were assigned to everyone");

        let (text, duration, _segments) = mgr.finish("long").unwrap();
        assert_eq!(
            text,
            "the meeting started with introductions\n\nand then we discussed the budget\n\nwas reviewed by the finance team\n\nnext steps were assigned to everyone"
        );
        assert!((duration - 120.0).abs() < 0.01);
    }

    #[test]
    fn test_segments_accumulated_with_absolute_timestamps() {
        use crate::TimestampedSegment;

        let mut mgr = SessionManager::new();
        mgr.start("seg-test").unwrap();

        // Chunk 1 at offset 0s: segment at 1.0-3.0s
        let seg1 = vec![TimestampedSegment {
            text: "hello world".into(),
            start_secs: 1.0,
            end_secs: 3.0,
        }];
        let r1 = mgr.add_chunk("seg-test", "hello world", 30.0, seg1).unwrap();
        assert!((r1.chunk_offset_secs - 0.0).abs() < 0.01);

        // Chunk 2 at offset 30s: segment at 2.0-5.0s relative to chunk
        let seg2 = vec![TimestampedSegment {
            text: "second sentence".into(),
            start_secs: 2.0,
            end_secs: 5.0,
        }];
        let r2 = mgr.add_chunk("seg-test", "second sentence", 30.0, seg2).unwrap();
        assert!((r2.chunk_offset_secs - 30.0).abs() < 0.01);

        let (_text, _dur, segments) = mgr.finish("seg-test").unwrap();
        assert_eq!(segments.len(), 2);

        // First segment: absolute 1.0-3.0s (chunk offset 0)
        assert_eq!(segments[0].text, "hello world");
        assert!((segments[0].start_secs - 1.0).abs() < 0.01);
        assert!((segments[0].end_secs - 3.0).abs() < 0.01);

        // Second segment: absolute 32.0-35.0s (chunk offset 30 + relative 2.0-5.0)
        assert_eq!(segments[1].text, "second sentence");
        assert!((segments[1].start_secs - 32.0).abs() < 0.01);
        assert!((segments[1].end_secs - 35.0).abs() < 0.01);
    }

    #[test]
    fn test_chunked_session_error_on_unknown_id() {
        let mut mgr = SessionManager::new();
        assert!(mgr.add_chunk("nonexistent", "text", 10.0, vec![]).is_err());
        assert!(mgr.finish("nonexistent").is_err());
    }
}
