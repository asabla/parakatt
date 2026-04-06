/// LocalAgreement-2 commit policy for streaming ASR.
///
/// Background: when you re-run an offline ASR model on a growing audio
/// buffer every few hundred milliseconds, the model's output for the
/// "tail" of the buffer flickers between alternates as more context
/// arrives. The user sees text changing under their cursor, which
/// looks like a bug.
///
/// LocalAgreement-2 (Macháček et al., 2023, "Turning Whisper into
/// Real-Time Transcription System", arXiv 2307.14743) is the
/// canonical fix:
///
/// 1. Keep the previous hypothesis (token sequence) around.
/// 2. When a new hypothesis arrives, find the longest common token
///    prefix between previous and current.
/// 3. Everything in that common prefix is "committed" — it appeared
///    in two consecutive passes, so we believe it.
/// 4. Everything after the divergence is "tentative" — it's still
///    the model's current best guess but expected to flicker.
/// 5. The UI shows committed in normal weight and tentative in
///    lighter style.
///
/// On a confirmed sentence boundary the caller can `advance_committed`
/// to bake the committed text into permanent storage and reset the
/// LA-2 state, so the buffer never grows unbounded.
///
/// This module is intentionally STT-agnostic: it operates on `Token`s
/// (text + timing) and knows nothing about Parakeet, Whisper, etc.
use crate::TimestampedSegment;

/// One token from an STT pass — text plus the time it occupies in the
/// audio buffer. Granularity (subword / word / sentence) is whatever
/// the upstream STT provides; LA-2 doesn't care as long as the same
/// granularity is used across passes.
#[derive(Debug, Clone, PartialEq)]
pub struct Token {
    pub text: String,
    pub start_secs: f64,
    pub end_secs: f64,
}

impl From<&TimestampedSegment> for Token {
    fn from(seg: &TimestampedSegment) -> Self {
        Token {
            text: seg.text.clone(),
            start_secs: seg.start_secs,
            end_secs: seg.end_secs,
        }
    }
}

/// Result of feeding a new hypothesis to a [`LocalAgreement2`] state.
#[derive(Debug, Clone, Default)]
pub struct AgreementResult {
    /// Tokens that are NEWLY committed by this pass — i.e. tokens
    /// that just transitioned from "tentative" to "committed". The
    /// caller can append these to the running display text without
    /// worrying about duplicates.
    pub newly_committed: Vec<Token>,
    /// The full current "tentative" tail — tokens past the
    /// agreement point. The caller should re-render this part on
    /// every update because it can change.
    pub tentative: Vec<Token>,
}

/// LocalAgreement-2 state machine.
///
/// Lifecycle:
///   - `LocalAgreement2::new()` to start
///   - `update(current_hypothesis)` on every preview pass
///   - `committed_text()` for the stable text accumulated so far
///   - `advance()` after a confirmed sentence boundary to bake
///     committed tokens into permanent storage and reset the
///     window watermark
#[derive(Debug, Clone, Default)]
pub struct LocalAgreement2 {
    /// Previous pass's full hypothesis (still in the window).
    prev_hypothesis: Vec<Token>,
    /// Tokens already committed (longest stable prefix).
    committed: Vec<Token>,
    /// Cumulative committed text (cached so we don't rebuild it
    /// from `committed` on every read).
    committed_text: String,
}

impl LocalAgreement2 {
    pub fn new() -> Self {
        Self::default()
    }

    /// Feed a new hypothesis from the streaming ASR. Returns the
    /// newly-committed tokens (caller appends to display) and the
    /// current tentative tail (caller renders below the committed
    /// text in lighter style).
    pub fn update(&mut self, current: Vec<Token>) -> AgreementResult {
        // The stable agreement is the longest common prefix between
        // the previous hypothesis and the current one — measured AFTER
        // the part we already committed. We never un-commit.
        let already_committed = self.committed.len();
        let prev_tail = self.prev_hypothesis.get(already_committed..).unwrap_or(&[]);
        let curr_tail = current.get(already_committed..).unwrap_or(&[]);

        let stable_len = longest_common_prefix(prev_tail, curr_tail);
        let stable: &[Token] = &curr_tail[..stable_len];

        // Append the newly-stable slice to the committed history.
        let mut newly_committed = Vec::with_capacity(stable.len());
        for tok in stable {
            self.append_committed(tok.clone());
            newly_committed.push(tok.clone());
        }

        // Tentative tail = everything in the current hypothesis past
        // what we now consider committed.
        let new_committed_count = self.committed.len();
        let tentative: Vec<Token> = current.iter().skip(new_committed_count).cloned().collect();

        // Remember this hypothesis so the next update can find the
        // common prefix with it.
        self.prev_hypothesis = current;

        AgreementResult {
            newly_committed,
            tentative,
        }
    }

    /// The committed text accumulated so far. Stable, never revised.
    pub fn committed_text(&self) -> &str {
        &self.committed_text
    }

    /// All committed tokens (with timing).
    pub fn committed_tokens(&self) -> &[Token] {
        &self.committed
    }

    /// Drop committed tokens from internal state — call this after
    /// you've persisted them downstream so future passes don't have
    /// to walk an unbounded committed list. The committed_text
    /// cache is also cleared, since the caller should now own that
    /// text in its own accumulator.
    pub fn advance(&mut self) {
        // Capture the committed count BEFORE clearing so we can
        // strip the same prefix from prev_hypothesis.
        let committed_count = self.committed.len();
        self.committed.clear();
        self.committed_text.clear();
        // Drop the committed prefix from prev_hypothesis, keep the
        // unstable tail so the next update() can still find
        // common-prefix matches against it.
        if committed_count > 0 && committed_count <= self.prev_hypothesis.len() {
            self.prev_hypothesis.drain(..committed_count);
        }
    }

    /// Reset everything — call when starting a fresh session.
    pub fn reset(&mut self) {
        self.prev_hypothesis.clear();
        self.committed.clear();
        self.committed_text.clear();
    }

    /// True when no committed text has been produced yet AND no
    /// previous hypothesis exists. Used by callers that want to
    /// know whether the LA-2 state is in its initial state.
    pub fn is_empty(&self) -> bool {
        self.committed.is_empty() && self.prev_hypothesis.is_empty()
    }

    fn append_committed(&mut self, tok: Token) {
        if !self.committed_text.is_empty() {
            // Insert a single space between tokens unless the new
            // token is a standalone punctuation mark, in which case
            // we attach it to the previous token without a space.
            let attaches = matches!(tok.text.as_str(), "." | "," | "!" | "?" | ";" | ":" | ")");
            if !attaches {
                self.committed_text.push(' ');
            }
        }
        self.committed_text.push_str(tok.text.trim());
        self.committed.push(tok);
    }
}

/// Longest common prefix length over two token slices, comparing
/// tokens by their normalized text (case- and whitespace-insensitive,
/// punctuation-stripped). Timing is ignored — two model passes will
/// rarely produce identical timing for the same word, but if the
/// text matches we still want LA-2 to commit.
fn longest_common_prefix(a: &[Token], b: &[Token]) -> usize {
    let max = a.len().min(b.len());
    let mut n = 0;
    while n < max && tokens_match(&a[n], &b[n]) {
        n += 1;
    }
    n
}

fn tokens_match(a: &Token, b: &Token) -> bool {
    normalize(&a.text) == normalize(&b.text)
}

fn normalize(s: &str) -> String {
    s.chars()
        .filter(|c| c.is_alphanumeric() || c.is_whitespace())
        .flat_map(|c| c.to_lowercase())
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tok(text: &str) -> Token {
        Token {
            text: text.to_string(),
            start_secs: 0.0,
            end_secs: 0.0,
        }
    }

    fn tokens(words: &[&str]) -> Vec<Token> {
        words.iter().map(|w| tok(w)).collect()
    }

    #[test]
    fn first_update_commits_nothing() {
        // With no previous hypothesis there's nothing to agree
        // with — everything in the first pass is tentative.
        let mut la = LocalAgreement2::new();
        let r = la.update(tokens(&["hello", "world"]));
        assert!(r.newly_committed.is_empty());
        assert_eq!(r.tentative.len(), 2);
        assert_eq!(la.committed_text(), "");
    }

    #[test]
    fn second_update_commits_common_prefix() {
        let mut la = LocalAgreement2::new();
        la.update(tokens(&["hello", "world"]));
        // Pass 2 keeps "hello world" stable but extends with "and".
        // The "and" is now in the prev hypothesis, but since pass 2
        // is the FIRST time we see it, we shouldn't commit it yet.
        let r = la.update(tokens(&["hello", "world", "and"]));

        assert_eq!(r.newly_committed.len(), 2);
        assert_eq!(r.newly_committed[0].text, "hello");
        assert_eq!(r.newly_committed[1].text, "world");
        assert_eq!(r.tentative.len(), 1);
        assert_eq!(r.tentative[0].text, "and");
        assert_eq!(la.committed_text(), "hello world");
    }

    #[test]
    fn third_update_commits_more_after_agreement() {
        let mut la = LocalAgreement2::new();
        la.update(tokens(&["hello", "world"]));
        la.update(tokens(&["hello", "world", "and"]));
        // Pass 3: "and" appears again → now committed.
        let r = la.update(tokens(&["hello", "world", "and", "more"]));
        assert_eq!(r.newly_committed.len(), 1);
        assert_eq!(r.newly_committed[0].text, "and");
        assert_eq!(r.tentative.len(), 1);
        assert_eq!(r.tentative[0].text, "more");
        assert_eq!(la.committed_text(), "hello world and");
    }

    #[test]
    fn flicker_only_in_diverging_token_is_left_tentative() {
        // The classic STT flicker: pass 1 decoded "good warning",
        // pass 2 decoded "good morning". The flicker is on the LAST
        // word — "good" is shared. LA-2 should commit through "good"
        // and only leave the diverging final word as tentative.
        let mut la = LocalAgreement2::new();
        la.update(tokens(&["welcome", "everyone", "good", "warning"]));
        let r = la.update(tokens(&["welcome", "everyone", "good", "morning"]));
        assert_eq!(r.newly_committed.len(), 3);
        assert_eq!(r.newly_committed[0].text, "welcome");
        assert_eq!(r.newly_committed[1].text, "everyone");
        assert_eq!(r.newly_committed[2].text, "good");
        assert_eq!(la.committed_text(), "welcome everyone good");
        // Only the diverging final word is tentative.
        assert_eq!(r.tentative.len(), 1);
        assert_eq!(r.tentative[0].text, "morning");
    }

    #[test]
    fn flicker_inside_phrase_keeps_only_stable_prefix() {
        // Diverging at the third token — "warning" vs "morning"
        // mid-phrase. LA-2 should commit only "welcome everyone".
        let mut la = LocalAgreement2::new();
        la.update(tokens(&["welcome", "everyone", "warning", "tail"]));
        let r = la.update(tokens(&["welcome", "everyone", "morning", "different"]));
        assert_eq!(r.newly_committed.len(), 2);
        assert_eq!(la.committed_text(), "welcome everyone");
        assert_eq!(r.tentative.len(), 2);
    }

    #[test]
    fn casing_and_punctuation_are_normalized() {
        // Pass 1: lowercase, no punct.
        // Pass 2: capitalized + punctuation. Should still match.
        let mut la = LocalAgreement2::new();
        la.update(tokens(&["hello", "world"]));
        let r = la.update(vec![tok("Hello,"), tok("World!"), tok("more")]);
        // Hello, and World! match by normalized form, so they commit.
        assert_eq!(r.newly_committed.len(), 2);
        // The committed text uses the casing from the LATER (more
        // confident) pass.
        assert_eq!(la.committed_text(), "Hello, World!");
    }

    #[test]
    fn punctuation_attaches_without_space() {
        let mut la = LocalAgreement2::new();
        la.update(tokens(&["hello", ",", "world"]));
        la.update(tokens(&["hello", ",", "world"]));
        // committed_text should be "hello, world", not "hello , world".
        assert_eq!(la.committed_text(), "hello, world");
    }

    #[test]
    fn advance_clears_committed_for_caller_to_persist() {
        let mut la = LocalAgreement2::new();
        la.update(tokens(&["hello", "world"]));
        la.update(tokens(&["hello", "world", "next"]));
        assert_eq!(la.committed_text(), "hello world");

        // Caller persisted "hello world"; tell LA-2 to drop it.
        la.advance();
        assert_eq!(la.committed_text(), "");
        assert!(la.committed_tokens().is_empty());

        // The next pass should still be able to commit "next" because
        // the previous hypothesis included it.
        let r = la.update(tokens(&["next", "thing"]));
        assert_eq!(r.newly_committed.len(), 1);
        assert_eq!(r.newly_committed[0].text, "next");
    }

    #[test]
    fn empty_input_yields_empty_result() {
        let mut la = LocalAgreement2::new();
        let r = la.update(vec![]);
        assert!(r.newly_committed.is_empty());
        assert!(r.tentative.is_empty());
    }

    #[test]
    fn shrinking_hypothesis_after_buffer_chunk_gets_stuck_without_reset() {
        // Regression test: this is the "stuck after ~2 sentences"
        // bug. The buffered preview LA-2 sees a long hypothesis,
        // then the chunk pipeline consumes most of the audio
        // leaving a much shorter buffer, and the next preview
        // hypothesis is way shorter than the committed length.
        // Without reset() between, LA-2 commits NOTHING new and
        // the user appears stuck.
        let mut la = LocalAgreement2::new();
        // Pass 1+2 establish the long committed prefix.
        la.update(tokens(&["the", "quick", "brown", "fox", "jumps", "over"]));
        let r2 = la.update(tokens(&["the", "quick", "brown", "fox", "jumps", "over"]));
        assert_eq!(
            r2.newly_committed.len(),
            6,
            "first round should commit all 6"
        );
        assert_eq!(la.committed_text(), "the quick brown fox jumps over");

        // Now the chunk fires, consumes most audio, leaves overlap.
        // The next preview pass on the short buffer says "jumps over"
        // (the overlap region only). Without reset, LA-2 still has
        // 6 tokens committed and won't budge until the new
        // hypothesis grows past 6 tokens.
        let r3 = la.update(tokens(&["jumps", "over"]));
        assert!(
            r3.newly_committed.is_empty(),
            "should not commit anything new on shrunk hypothesis"
        );
        assert!(
            r3.tentative.is_empty(),
            "tentative is empty because curr is shorter than committed"
        );
        // LA-2 is now stuck — committed_text is still the old
        // long prefix and the new hypothesis can't add anything.
        // The user would see the old committed text frozen.
        assert_eq!(la.committed_text(), "the quick brown fox jumps over");

        // Even adding more new audio doesn't help until we exceed
        // the committed length:
        let r4 = la.update(tokens(&["jumps", "over", "lazy"]));
        assert!(
            r4.newly_committed.is_empty(),
            "still stuck — 3 new tokens < 6 committed"
        );
        assert!(r4.tentative.is_empty());
    }

    #[test]
    fn reset_unsticks_a_shrunk_hypothesis_session() {
        // The fix: caller must reset() when the underlying audio
        // window changes (e.g. after a chunk consumes audio).
        let mut la = LocalAgreement2::new();
        la.update(tokens(&["one", "two", "three", "four"]));
        la.update(tokens(&["one", "two", "three", "four"]));
        assert_eq!(la.committed_text(), "one two three four");

        // Caller knows the buffer just shrank → reset.
        la.reset();
        assert_eq!(la.committed_text(), "");

        // Now LA-2 starts fresh on the new short hypothesis.
        let r1 = la.update(tokens(&["three", "four"]));
        assert!(
            r1.newly_committed.is_empty(),
            "first pass after reset commits nothing"
        );
        assert_eq!(r1.tentative.len(), 2);

        let r2 = la.update(tokens(&["three", "four", "five"]));
        assert_eq!(r2.newly_committed.len(), 2);
        assert_eq!(la.committed_text(), "three four");
    }

    #[test]
    fn shrinking_hypothesis_does_not_panic() {
        // Pathological: pass 2 returns FEWER tokens than pass 1.
        // (Can happen if the buffer head was advanced.) The committed
        // history is fixed; tentative is just whatever's left.
        let mut la = LocalAgreement2::new();
        la.update(tokens(&["one", "two", "three"]));
        la.update(tokens(&["one", "two", "three"]));
        // Now committed_text = "one two three"
        let r = la.update(tokens(&["one"]));
        // Nothing new committed (already at 3); tentative is empty
        // because the current hypothesis only has 1 token and the
        // committed prefix is already 3.
        assert!(r.newly_committed.is_empty());
        assert!(r.tentative.is_empty());
    }

    #[test]
    fn reset_returns_to_initial_state() {
        let mut la = LocalAgreement2::new();
        la.update(tokens(&["a", "b"]));
        la.update(tokens(&["a", "b", "c"]));
        assert!(!la.is_empty());
        la.reset();
        assert!(la.is_empty());
        assert_eq!(la.committed_text(), "");
    }

    #[test]
    fn from_timestamped_segment_round_trip() {
        let seg = TimestampedSegment {
            text: "hello".into(),
            start_secs: 1.5,
            end_secs: 2.0,
        };
        let t: Token = (&seg).into();
        assert_eq!(t.text, "hello");
        assert_eq!(t.start_secs, 1.5);
        assert_eq!(t.end_secs, 2.0);
    }
}
