/// Session-based chunked transcription for long-form audio (meetings, etc.).
///
/// Audio is processed in fixed-size chunks with overlap to avoid word splitting
/// at boundaries. Each chunk is independently transcribed via STT, then
/// overlap-deduplication stitches the results into a continuous transcript.
use std::collections::HashMap;

use crate::{ChunkSource, CoreError, TimestampedSegment};

/// Result of processing a single audio chunk.
///
/// `accumulated_text` is intentionally not included — cloning the full
/// transcript on every chunk was a measurable allocation hot path on
/// long meetings. Callers that need the running transcript should call
/// `Engine::get_session_text(session_id)` on demand, or maintain their
/// own accumulator by appending `text` after each chunk.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ChunkResult {
    /// New text from this chunk (after overlap dedup).
    pub text: String,
    /// Zero-based index of this chunk.
    pub chunk_index: u32,
    /// Sentence-level timestamp segments for this chunk.
    pub segments: Vec<TimestampedSegment>,
    /// Offset in seconds from session start for this chunk's timestamps.
    pub chunk_offset_secs: f64,
    /// If LLM post-processing failed for this chunk (after retries),
    /// this holds the last error message and `text` is the raw STT
    /// output. `None` means LLM either succeeded or wasn't configured.
    pub llm_error: Option<String>,
}

/// Number of sentences per paragraph in accumulated text.
const SENTENCES_PER_PARAGRAPH: usize = 3;

/// How many trailing segments / words from the previous chunk we keep
/// around for overlap deduplication of the next chunk. Eight is enough
/// for the typical 2–5s overlap with the chunk sizes we use today.
const OVERLAP_SEGMENT_COUNT: usize = 8;
const OVERLAP_WORD_COUNT: usize = 8;

/// Maximum age (seconds) before an idle session is eligible for eviction
/// by `cleanup_stale_sessions()`. 6 hours covers the longest realistic
/// meeting and avoids unbounded HashMap growth if a client forgets to
/// finish/cancel.
pub const SESSION_MAX_IDLE_SECS: u64 = 6 * 60 * 60;

/// Internal state for a running transcription session.
struct SessionState {
    /// Full accumulated transcript text.
    accumulated_text: String,
    /// Trailing words from the previous chunk, used as a fallback when
    /// segment-level dedup is unavailable (no STT segments).
    prev_trailing_words: Vec<String>,
    /// Normalized text of the last few segments from the previous chunk,
    /// used for segment-level overlap dedup.
    prev_trailing_segments: Vec<String>,
    /// Per-source trailing segments. Used by `add_chunk_with_source` so
    /// mic and system audio keep independent overlap tails — a system
    /// chunk's overlap must never dedup against a mic chunk and vice
    /// versa. `Mixed` uses `prev_trailing_segments` above.
    prev_trailing_by_source: HashMap<ChunkSource, Vec<String>>,
    /// Number of chunks processed so far.
    chunk_count: u32,
    /// Total audio duration processed (seconds).
    total_duration_secs: f64,
    /// Offsets for slices already seen by at least one source. When the
    /// second source (mic vs. system) arrives for the same slice_index,
    /// we reuse the stored offset so segments line up by wall-clock time
    /// and `total_duration_secs` does not double-advance.
    known_slice_offsets: HashMap<u32, f64>,
    /// All segments accumulated across chunks, with absolute timestamps.
    accumulated_segments: Vec<TimestampedSegment>,
    /// Sentence count for paragraph breaking.
    sentence_count: usize,
    /// Wall-clock time of the last `add_chunk` call (or `start` for an
    /// empty session). Used by `cleanup_stale_sessions()`.
    last_active: std::time::Instant,
}

/// Manages multiple concurrent transcription sessions.
#[derive(Default)]
pub struct SessionManager {
    sessions: HashMap<String, SessionState>,
}

impl SessionManager {
    pub fn new() -> Self {
        Self::default()
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
                prev_trailing_segments: Vec::new(),
                prev_trailing_by_source: HashMap::new(),
                chunk_count: 0,
                total_duration_secs: 0.0,
                known_slice_offsets: HashMap::new(),
                accumulated_segments: Vec::new(),
                sentence_count: 0,
                last_active: std::time::Instant::now(),
            },
        );

        Ok(())
    }

    /// Drop sessions that have been idle longer than `SESSION_MAX_IDLE_SECS`.
    /// Returns the number of sessions evicted.
    pub fn cleanup_stale_sessions(&mut self) -> usize {
        let now = std::time::Instant::now();
        let before = self.sessions.len();
        self.sessions.retain(|_, state| {
            now.duration_since(state.last_active).as_secs() < SESSION_MAX_IDLE_SECS
        });
        before - self.sessions.len()
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
        // Default path: no overlap information from caller, fall back
        // to text-based segment dedup against the previous chunk's
        // trailing segments.
        self.add_chunk_with_overlap(session_id, raw_text, chunk_duration_secs, 0.0, segments)
    }

    /// Same as `add_chunk`, but the caller tells us the overlap region
    /// (in seconds) at the start of this chunk that re-encodes audio
    /// already covered by the previous chunk. When `chunk_overlap_secs`
    /// is positive we use **time-based** segment gating: any STT
    /// segment whose start falls inside `[0, chunk_overlap_secs)` is
    /// dropped, since the previous chunk already emitted it. This is
    /// the NeMo "middle-token merging" pattern adapted to our chunk
    /// shape — exact, no string-matching heuristics.
    ///
    /// When `chunk_overlap_secs == 0` (or the STT returned no
    /// segments) we fall back to the text-based dedup path.
    pub fn add_chunk_with_overlap(
        &mut self,
        session_id: &str,
        raw_text: &str,
        chunk_duration_secs: f64,
        chunk_overlap_secs: f64,
        segments: Vec<TimestampedSegment>,
    ) -> Result<ChunkResult, CoreError> {
        let state = self.sessions.get_mut(session_id).ok_or_else(|| {
            CoreError::TranscriptionFailed(format!("Session not found: {session_id}"))
        })?;

        let chunk_index = state.chunk_count;
        let chunk_offset_secs = state.total_duration_secs;
        state.last_active = std::time::Instant::now();

        // Three paths:
        //   1. Caller knows the overlap (chunk_overlap_secs > 0) AND
        //      we have STT segments → time-based gating, the
        //      authoritative middle-token merge. Drop segments whose
        //      start falls inside the overlap window. Cleanest, no
        //      string matching needed.
        //   2. We have segments but no overlap info → fall back to
        //      text-based segment dedup against trailing segments
        //      from the previous chunk.
        //   3. No segments at all → word-level text dedup as last resort.
        let surviving_segments: Vec<TimestampedSegment>;
        let new_text: String;

        if chunk_overlap_secs > 0.0 && !segments.is_empty() && chunk_index > 0 {
            // Path 1: time-based middle-token merge.
            surviving_segments = segments
                .iter()
                .filter(|s| s.start_secs >= chunk_overlap_secs)
                .cloned()
                .collect();

            new_text = surviving_segments
                .iter()
                .map(|s| s.text.trim())
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join(" ");

            // Refresh trailing-segments cache too so a later chunk
            // that DOESN'T pass overlap info can still fall back to
            // path 2 cleanly.
            let normalized: Vec<String> =
                segments.iter().map(|s| normalize_text(&s.text)).collect();
            state.prev_trailing_segments = normalized
                .iter()
                .rev()
                .take(OVERLAP_SEGMENT_COUNT)
                .rev()
                .cloned()
                .collect();
        } else if !segments.is_empty() {
            // Path 2: text-based segment-level dedup.
            let normalized: Vec<String> =
                segments.iter().map(|s| normalize_text(&s.text)).collect();
            let segments_to_skip = if chunk_index > 0 {
                longest_matching_overlap(&state.prev_trailing_segments, &normalized)
            } else {
                0
            };

            surviving_segments = segments.iter().skip(segments_to_skip).cloned().collect();

            // Build the chunk's text from surviving segments — this stays
            // perfectly in sync with what we push into accumulated_text.
            new_text = surviving_segments
                .iter()
                .map(|s| s.text.trim())
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join(" ");

            // Update trailing segments cache for the next chunk.
            // We use the *raw* normalized list (not the survivors) so the
            // next chunk can match against everything we just emitted.
            state.prev_trailing_segments = normalized
                .iter()
                .rev()
                .take(OVERLAP_SEGMENT_COUNT)
                .rev()
                .cloned()
                .collect();
        } else {
            // Fallback path: no segment information from STT.
            new_text = if chunk_index == 0 {
                raw_text.to_string()
            } else {
                deduplicate_overlap(&state.prev_trailing_words, raw_text)
            };
            surviving_segments = Vec::new();
        }

        // Word-level trailing cache stays maintained even on the segment
        // path so a session can mix segment and non-segment chunks safely.
        let all_words: Vec<&str> = raw_text.split_whitespace().collect();
        state.prev_trailing_words = all_words
            .iter()
            .rev()
            .take(OVERLAP_WORD_COUNT)
            .rev()
            .map(|w| w.to_string())
            .collect();

        // Append surviving segments (with absolute timestamps) and grow
        // accumulated_text with paragraph breaks at chunk boundaries.
        if !surviving_segments.is_empty() {
            let mut chunk_sentence_count: usize = 0;
            for seg in &surviving_segments {
                state.accumulated_segments.push(TimestampedSegment {
                    text: seg.text.clone(),
                    start_secs: chunk_offset_secs + seg.start_secs,
                    end_secs: chunk_offset_secs + seg.end_secs,
                    speaker: seg.speaker.clone(),
                });

                let trimmed = seg.text.trim();
                if trimmed.is_empty() {
                    continue;
                }

                if !state.accumulated_text.is_empty() {
                    // Paragraph break at chunk boundary (first sentence of
                    // new chunk) or every N sentences within a chunk.
                    if chunk_sentence_count == 0
                        || chunk_sentence_count.is_multiple_of(SENTENCES_PER_PARAGRAPH)
                    {
                        state.accumulated_text.push_str("\n\n");
                    } else {
                        state.accumulated_text.push(' ');
                    }
                }
                state.accumulated_text.push_str(trimmed);
                chunk_sentence_count += 1;
            }
            state.sentence_count += chunk_sentence_count;
        } else if !new_text.is_empty() {
            // Fallback: no segments available, append raw text with chunk break.
            if !state.accumulated_text.is_empty() {
                state.accumulated_text.push_str("\n\n");
            }
            state.accumulated_text.push_str(&new_text);
        }

        state.chunk_count += 1;
        state.total_duration_secs += chunk_duration_secs;

        Ok(ChunkResult {
            text: new_text,
            chunk_index,
            segments,
            chunk_offset_secs,
            llm_error: None,
        })
    }

    /// Add a chunk tagged with its audio source, for the speaker-labelled
    /// meeting pipeline. Mic and system audio are sent as separate chunks
    /// per slice so the mic stream can be deterministically labelled "Me".
    ///
    /// `slice_index` is shared across sources for the same wall-clock
    /// window — the first source to arrive with a given `slice_index`
    /// advances `total_duration_secs`; a second source with the same
    /// `slice_index` reuses the captured offset so segments line up by
    /// time and we don't double-count duration.
    ///
    /// Per-source trailing caches keep mic and system overlap dedup
    /// independent. `Mixed` delegates to `add_chunk_with_overlap` for
    /// full backward compatibility.
    #[allow(clippy::too_many_arguments)]
    pub fn add_chunk_with_source(
        &mut self,
        session_id: &str,
        source: ChunkSource,
        slice_index: u32,
        raw_text: &str,
        chunk_duration_secs: f64,
        chunk_overlap_secs: f64,
        mut segments: Vec<TimestampedSegment>,
    ) -> Result<ChunkResult, CoreError> {
        if source == ChunkSource::Mixed {
            return self.add_chunk_with_overlap(
                session_id,
                raw_text,
                chunk_duration_secs,
                chunk_overlap_secs,
                segments,
            );
        }

        // Tag segments with their speaker based on source. Mic is always
        // "Me". System is tagged as a single "Speaker 1" placeholder
        // until real multi-speaker diarization (pyannote-seg + embedding
        // clustering) lands — at which point this call site is where
        // individual Speaker 2/3/… labels get attached.
        let placeholder_label = match source {
            ChunkSource::Mic => Some("Me"),
            ChunkSource::System => Some("Speaker 1"),
            ChunkSource::Mixed => None,
        };
        if let Some(label) = placeholder_label {
            for seg in &mut segments {
                if seg.speaker.is_none() {
                    seg.speaker = Some(label.to_string());
                }
            }
        }

        let state = self.sessions.get_mut(session_id).ok_or_else(|| {
            CoreError::TranscriptionFailed(format!("Session not found: {session_id}"))
        })?;
        state.last_active = std::time::Instant::now();

        // Resolve the slice's absolute offset. First source to arrive for
        // a given slice_index advances time; a second source reuses the
        // captured offset.
        let chunk_offset_secs = if let Some(&offset) = state.known_slice_offsets.get(&slice_index) {
            offset
        } else {
            let offset = state.total_duration_secs;
            state.known_slice_offsets.insert(slice_index, offset);
            state.total_duration_secs += chunk_duration_secs;
            offset
        };

        // Pull per-source trailing cache; this source's dedup is independent.
        let trailing = state
            .prev_trailing_by_source
            .entry(source)
            .or_default()
            .clone();

        // Dedup paths mirror add_chunk_with_overlap but use the per-source
        // trailing cache. slice_index >= 1 gates overlap handling; slice 0
        // is the session's first slice for this source.
        let surviving_segments: Vec<TimestampedSegment>;
        let new_text: String;

        if chunk_overlap_secs > 0.0 && !segments.is_empty() && slice_index > 0 {
            surviving_segments = segments
                .iter()
                .filter(|s| s.start_secs >= chunk_overlap_secs)
                .cloned()
                .collect();
            new_text = surviving_segments
                .iter()
                .map(|s| s.text.trim())
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join(" ");
        } else if !segments.is_empty() {
            let normalized: Vec<String> =
                segments.iter().map(|s| normalize_text(&s.text)).collect();
            let segments_to_skip = if slice_index > 0 {
                longest_matching_overlap(&trailing, &normalized)
            } else {
                0
            };
            surviving_segments = segments.iter().skip(segments_to_skip).cloned().collect();
            new_text = surviving_segments
                .iter()
                .map(|s| s.text.trim())
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join(" ");
        } else {
            new_text = raw_text.to_string();
            surviving_segments = Vec::new();
        }

        // Refresh per-source trailing cache.
        if !segments.is_empty() {
            let normalized: Vec<String> =
                segments.iter().map(|s| normalize_text(&s.text)).collect();
            let tail: Vec<String> = normalized
                .iter()
                .rev()
                .take(OVERLAP_SEGMENT_COUNT)
                .rev()
                .cloned()
                .collect();
            state.prev_trailing_by_source.insert(source, tail);
        }

        // Accumulate segments with absolute timestamps, then re-sort the
        // running buffer chronologically. Mic and system are dispatched
        // per slice but can arrive at the engine out of order under load,
        // so without this sort the live preview text would interleave
        // sources in arrival order rather than wall-clock order.
        let mut added_sentences: usize = 0;
        for seg in &surviving_segments {
            state.accumulated_segments.push(TimestampedSegment {
                text: seg.text.clone(),
                start_secs: chunk_offset_secs + seg.start_secs,
                end_secs: chunk_offset_secs + seg.end_secs,
                speaker: seg.speaker.clone(),
            });
            if !seg.text.trim().is_empty() {
                added_sentences += 1;
            }
        }

        if added_sentences > 0 {
            state.accumulated_segments.sort_by(|a, b| {
                a.start_secs
                    .partial_cmp(&b.start_secs)
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
            state.accumulated_text = state
                .accumulated_segments
                .iter()
                .map(|s| s.text.trim())
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join(" ");
            state.sentence_count += added_sentences;
        }

        state.chunk_count += 1;

        Ok(ChunkResult {
            text: new_text,
            chunk_index: slice_index,
            segments: surviving_segments,
            chunk_offset_secs,
            llm_error: None,
        })
    }

    /// Finish a session and return the full accumulated text + segments.
    /// Removes the session from the manager.
    pub fn finish(
        &mut self,
        session_id: &str,
    ) -> Result<(String, f64, Vec<TimestampedSegment>), CoreError> {
        let mut state = self.sessions.remove(session_id).ok_or_else(|| {
            CoreError::TranscriptionFailed(format!("Session not found: {session_id}"))
        })?;

        // Dual-stream sessions interleave mic and system segments by
        // arrival order, so enforce chronological order on finish.
        state.accumulated_segments.sort_by(|a, b| {
            a.start_secs
                .partial_cmp(&b.start_secs)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

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

/// Normalize a segment's text for comparison: lowercase, collapse
/// whitespace, strip punctuation. Used by segment-level dedup so that
/// "Hello, world." and "hello world" compare equal.
fn normalize_text(text: &str) -> String {
    text.split_whitespace()
        .map(|w| strip_punctuation(w).to_lowercase())
        .filter(|w| !w.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

/// Find the longest suffix of `prev_tail` (slice of normalized strings)
/// that exactly matches a prefix of `current_head`. Returns the length
/// of the match — i.e. the number of leading entries in `current_head`
/// that should be skipped as overlap.
fn longest_matching_overlap(prev_tail: &[String], current_head: &[String]) -> usize {
    if prev_tail.is_empty() || current_head.is_empty() {
        return 0;
    }
    let max_check = prev_tail.len().min(current_head.len());
    for n in (1..=max_check).rev() {
        let suffix = &prev_tail[prev_tail.len() - n..];
        let prefix = &current_head[..n];
        if suffix == prefix {
            return n;
        }
    }
    0
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
        let prev = vec!["the".into(), "quick".into(), "brown".into(), "fox".into()];
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
        let r1 = mgr
            .add_chunk("test-1", "hello world this is chunk one", 30.0, vec![])
            .unwrap();
        assert_eq!(r1.chunk_index, 0);
        assert_eq!(r1.text, "hello world this is chunk one");
        assert!((r1.chunk_offset_secs - 0.0).abs() < 0.01);

        // Second chunk with overlap ("chunk one" repeated)
        let r2 = mgr
            .add_chunk("test-1", "chunk one and here is chunk two", 30.0, vec![])
            .unwrap();
        assert_eq!(r2.chunk_index, 1);
        assert_eq!(r2.text, "and here is chunk two");
        assert_eq!(
            mgr.get_session_text("test-1").unwrap(),
            "hello world this is chunk one\n\nand here is chunk two"
        );
        assert!((r2.chunk_offset_secs - 30.0).abs() < 0.01);

        // Finish
        let (text, duration, segments) = mgr.finish("test-1").unwrap();
        assert_eq!(
            text,
            "hello world this is chunk one\n\nand here is chunk two"
        );
        assert!((duration - 60.0).abs() < 0.01);
        assert!(segments.is_empty()); // No segments passed in this test
        assert!(!mgr.has_session("test-1"));
    }

    #[test]
    fn test_session_cancel() {
        let mut mgr = SessionManager::new();
        mgr.start("cancel-me").unwrap();
        mgr.add_chunk("cancel-me", "some text", 10.0, vec![])
            .unwrap();
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
        let r1 = mgr
            .add_chunk(
                "long",
                "the meeting started with introductions",
                30.0,
                vec![],
            )
            .unwrap();
        assert_eq!(r1.chunk_index, 0);
        assert_eq!(r1.text, "the meeting started with introductions");

        // Chunk 2: overlap on "with introductions"
        let r2 = mgr
            .add_chunk(
                "long",
                "with introductions and then we discussed the budget",
                30.0,
                vec![],
            )
            .unwrap();
        assert_eq!(r2.chunk_index, 1);
        assert_eq!(r2.text, "and then we discussed the budget");

        // Chunk 3: overlap on "the budget"
        let r3 = mgr
            .add_chunk(
                "long",
                "the budget was reviewed by the finance team",
                30.0,
                vec![],
            )
            .unwrap();
        assert_eq!(r3.chunk_index, 2);
        assert_eq!(r3.text, "was reviewed by the finance team");

        // Chunk 4: no overlap (clean boundary)
        let r4 = mgr
            .add_chunk("long", "next steps were assigned to everyone", 30.0, vec![])
            .unwrap();
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
            speaker: None,
        }];
        let r1 = mgr
            .add_chunk("seg-test", "hello world", 30.0, seg1)
            .unwrap();
        assert!((r1.chunk_offset_secs - 0.0).abs() < 0.01);

        // Chunk 2 at offset 30s: segment at 2.0-5.0s relative to chunk
        let seg2 = vec![TimestampedSegment {
            text: "second sentence".into(),
            start_secs: 2.0,
            end_secs: 5.0,
            speaker: None,
        }];
        let r2 = mgr
            .add_chunk("seg-test", "second sentence", 30.0, seg2)
            .unwrap();
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
    fn test_segments_overlap_dedup() {
        // Simulates the PTT bug: chunk 0 has "As you can see with the",
        // chunk 1 re-processes overlapping audio and gets the full sentence.
        // The overlapping segment should be skipped in accumulated text.
        use crate::TimestampedSegment;

        let mut mgr = SessionManager::new();
        mgr.start("dedup-seg").unwrap();

        let seg1 = vec![TimestampedSegment {
            text: "As you can see with the".into(),
            start_secs: 0.0,
            end_secs: 2.0,
            speaker: None,
        }];
        mgr.add_chunk("dedup-seg", "As you can see with the", 2.0, seg1)
            .unwrap();
        assert_eq!(
            mgr.get_session_text("dedup-seg").unwrap(),
            "As you can see with the"
        );

        // Chunk 2 overlaps: STT reproduces the overlap words plus new content.
        let seg2 = vec![
            TimestampedSegment {
                text: "As you can see with the".into(),
                start_secs: 0.0,
                end_secs: 2.0,
                speaker: None,
            },
            TimestampedSegment {
                text: "pasted text above there is a duplicate.".into(),
                start_secs: 2.0,
                end_secs: 5.0,
                speaker: None,
            },
        ];
        mgr.add_chunk(
            "dedup-seg",
            "As you can see with the pasted text above there is a duplicate.",
            5.0,
            seg2,
        )
        .unwrap();

        // The overlap segment should be skipped — no duplication.
        let acc = mgr.get_session_text("dedup-seg").unwrap();
        assert!(
            !acc.contains("As you can see with the\n\nAs you can see with the"),
            "Accumulated text should not contain duplicated overlap: {acc}"
        );
        assert!(acc.contains("pasted text above"));
    }

    #[test]
    fn test_normalize_text_strips_punctuation_and_case() {
        assert_eq!(normalize_text("Hello, World!"), "hello world");
        assert_eq!(normalize_text("  multiple   spaces  "), "multiple spaces");
        assert_eq!(normalize_text(""), "");
    }

    #[test]
    fn test_longest_matching_overlap_basic() {
        let prev = vec!["a".to_string(), "b".to_string(), "c".to_string()];
        let curr = vec!["b".to_string(), "c".to_string(), "d".to_string()];
        // Longest match: "b c" (length 2)
        assert_eq!(longest_matching_overlap(&prev, &curr), 2);

        let prev = vec!["x".to_string()];
        let curr = vec!["y".to_string()];
        assert_eq!(longest_matching_overlap(&prev, &curr), 0);

        assert_eq!(longest_matching_overlap(&[], &curr), 0);
        assert_eq!(longest_matching_overlap(&prev, &[]), 0);
    }

    #[test]
    fn test_segment_dedup_misaligned_word_boundaries() {
        // Regression test for the old word-counting heuristic which
        // miscounted when the overlap word boundary did not coincide
        // with a segment boundary.
        //
        // Chunk 1 has 4 segments: "five", "six", "seven", "eight".
        // Chunk 2 reproduces "seven", "eight" as the start (overlap)
        // followed by new segments "nine ten", "eleven twelve".
        // The first two segments of chunk 2 should be skipped.
        use crate::TimestampedSegment;

        let mut mgr = SessionManager::new();
        mgr.start("misaligned").unwrap();

        let seg1 = vec![
            TimestampedSegment {
                text: "five".into(),
                start_secs: 0.0,
                end_secs: 1.0,
                speaker: None,
            },
            TimestampedSegment {
                text: "six".into(),
                start_secs: 1.0,
                end_secs: 2.0,
                speaker: None,
            },
            TimestampedSegment {
                text: "seven".into(),
                start_secs: 2.0,
                end_secs: 3.0,
                speaker: None,
            },
            TimestampedSegment {
                text: "eight".into(),
                start_secs: 3.0,
                end_secs: 4.0,
                speaker: None,
            },
        ];
        mgr.add_chunk("misaligned", "five six seven eight", 4.0, seg1)
            .unwrap();

        let seg2 = vec![
            TimestampedSegment {
                text: "seven".into(),
                start_secs: 0.0,
                end_secs: 1.0,
                speaker: None,
            },
            TimestampedSegment {
                text: "eight".into(),
                start_secs: 1.0,
                end_secs: 2.0,
                speaker: None,
            },
            TimestampedSegment {
                text: "nine ten".into(),
                start_secs: 2.0,
                end_secs: 4.0,
                speaker: None,
            },
            TimestampedSegment {
                text: "eleven twelve".into(),
                start_secs: 4.0,
                end_secs: 6.0,
                speaker: None,
            },
        ];
        let r2 = mgr
            .add_chunk(
                "misaligned",
                "seven eight nine ten eleven twelve",
                6.0,
                seg2,
            )
            .unwrap();

        assert_eq!(r2.text, "nine ten eleven twelve");
        let acc = mgr.get_session_text("misaligned").unwrap();
        assert!(
            !acc.contains("five six seven eight\n\nseven"),
            "duplicated overlap leaked into transcript: {acc}"
        );
        assert!(acc.contains("nine ten"));
        let _ = r2;

        let (_text, _dur, segs) = mgr.finish("misaligned").unwrap();
        // 4 (chunk 1) + 2 surviving (chunk 2) = 6
        assert_eq!(segs.len(), 6);
    }

    #[test]
    fn test_time_based_overlap_gating() {
        // The "middle-token merging" path. Caller passes a 2 s
        // overlap, segments that start before 2.0 s into the chunk
        // are dropped — no string matching at all.
        use crate::TimestampedSegment;

        let mut mgr = SessionManager::new();
        mgr.start("time").unwrap();

        // Chunk 1 establishes the baseline.
        let seg1 = vec![TimestampedSegment {
            text: "first chunk content".into(),
            start_secs: 0.0,
            end_secs: 4.0,
            speaker: None,
        }];
        mgr.add_chunk_with_overlap("time", "first chunk content", 4.0, 0.0, seg1)
            .unwrap();

        // Chunk 2 has 2 s of overlap. The first segment starts at
        // 0.5 s (inside the overlap window) and should be dropped.
        // The second segment starts at 2.5 s (past the overlap) and
        // should survive.
        let seg2 = vec![
            TimestampedSegment {
                text: "this was already emitted".into(),
                start_secs: 0.5,
                end_secs: 2.0,
                speaker: None,
            },
            TimestampedSegment {
                text: "this is fresh content".into(),
                start_secs: 2.5,
                end_secs: 5.0,
                speaker: None,
            },
        ];
        let r2 = mgr
            .add_chunk_with_overlap(
                "time",
                "this was already emitted this is fresh content",
                5.0,
                2.0,
                seg2,
            )
            .unwrap();

        assert_eq!(r2.text, "this is fresh content");

        let acc = mgr.get_session_text("time").unwrap();
        assert!(
            !acc.contains("already emitted"),
            "overlap segment leaked into transcript: {acc}"
        );
        assert!(acc.contains("fresh content"));

        let (_text, _dur, segs) = mgr.finish("time").unwrap();
        assert_eq!(segs.len(), 2);
    }

    #[test]
    fn test_time_based_gating_zero_overlap_first_chunk() {
        // First chunk is never gated even when overlap is set,
        // because there is nothing to overlap with.
        use crate::TimestampedSegment;

        let mut mgr = SessionManager::new();
        mgr.start("first").unwrap();

        let seg = vec![TimestampedSegment {
            text: "early content".into(),
            start_secs: 0.5,
            end_secs: 2.0,
            speaker: None,
        }];
        let r = mgr
            .add_chunk_with_overlap("first", "early content", 4.0, 2.0, seg)
            .unwrap();

        assert_eq!(r.text, "early content");
    }

    #[test]
    fn test_segment_dedup_normalizes_punctuation() {
        // Chunk 2 has punctuation that the trailing chunk 1 segments
        // don't, but normalization should still match them.
        use crate::TimestampedSegment;

        let mut mgr = SessionManager::new();
        mgr.start("punct").unwrap();

        let seg1 = vec![TimestampedSegment {
            text: "Hello world".into(),
            start_secs: 0.0,
            end_secs: 1.0,
            speaker: None,
        }];
        mgr.add_chunk("punct", "Hello world", 1.0, seg1).unwrap();

        let seg2 = vec![
            TimestampedSegment {
                text: "hello, world!".into(),
                start_secs: 0.0,
                end_secs: 1.0,
                speaker: None,
            },
            TimestampedSegment {
                text: "and more".into(),
                start_secs: 1.0,
                end_secs: 2.0,
                speaker: None,
            },
        ];
        let r2 = mgr
            .add_chunk("punct", "hello, world! and more", 2.0, seg2)
            .unwrap();
        assert_eq!(r2.text, "and more");
    }

    #[test]
    fn test_dual_source_chunk_time_and_speaker_tagging() {
        use crate::{ChunkSource, TimestampedSegment};

        let mut mgr = SessionManager::new();
        mgr.start("dual").unwrap();

        // Slice 0: mic and system arrive with matching slice_index.
        let mic_seg = vec![TimestampedSegment {
            text: "hi there".into(),
            start_secs: 1.0,
            end_secs: 2.0,
            speaker: None,
        }];
        let sys_seg = vec![TimestampedSegment {
            text: "remote reply".into(),
            start_secs: 1.5,
            end_secs: 3.0,
            speaker: None,
        }];

        let r_mic = mgr
            .add_chunk_with_source("dual", ChunkSource::Mic, 0, "hi there", 30.0, 0.0, mic_seg)
            .unwrap();
        let r_sys = mgr
            .add_chunk_with_source(
                "dual",
                ChunkSource::System,
                0,
                "remote reply",
                30.0,
                0.0,
                sys_seg,
            )
            .unwrap();

        // Both sources share the same offset; time only advances once.
        assert_eq!(r_mic.chunk_offset_secs, 0.0);
        assert_eq!(r_sys.chunk_offset_secs, 0.0);

        // Slice 1: mic only — offset advances by the first slice's duration.
        let mic2 = vec![TimestampedSegment {
            text: "later".into(),
            start_secs: 0.5,
            end_secs: 1.5,
            speaker: None,
        }];
        let r_mic2 = mgr
            .add_chunk_with_source("dual", ChunkSource::Mic, 1, "later", 30.0, 0.0, mic2)
            .unwrap();
        assert_eq!(r_mic2.chunk_offset_secs, 30.0);

        let (_text, duration, segs) = mgr.finish("dual").unwrap();
        // Slice 0 + slice 1 = 60s, advanced once per slice regardless of
        // how many sources contributed to each slice.
        assert!((duration - 60.0).abs() < 0.001);

        // Mic segments carry "Me", system segments carry the "Speaker 1"
        // placeholder. Real multi-speaker splitting is a follow-up.
        let me_segs: Vec<_> = segs
            .iter()
            .filter(|s| s.speaker.as_deref() == Some("Me"))
            .collect();
        assert_eq!(me_segs.len(), 2);
        let sys_segs: Vec<_> = segs
            .iter()
            .filter(|s| s.speaker.as_deref() == Some("Speaker 1"))
            .collect();
        assert_eq!(sys_segs.len(), 1);

        // Segments must come back chronologically sorted — mic at 1.0,
        // system at 1.5, mic at 30.5.
        assert!(segs[0].start_secs < segs[1].start_secs);
        assert!(segs[1].start_secs < segs[2].start_secs);
    }

    #[test]
    fn test_cleanup_stale_sessions_no_op_when_fresh() {
        let mut mgr = SessionManager::new();
        mgr.start("fresh").unwrap();
        assert_eq!(mgr.cleanup_stale_sessions(), 0);
        assert!(mgr.has_session("fresh"));
    }

    #[test]
    fn test_chunked_session_error_on_unknown_id() {
        let mut mgr = SessionManager::new();
        assert!(mgr.add_chunk("nonexistent", "text", 10.0, vec![]).is_err());
        assert!(mgr.finish("nonexistent").is_err());
    }
}
