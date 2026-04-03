/// Filler word removal for cleaner transcription output.
///
/// Strips common speech fillers ("uh", "um", "mmm", "ah", etc.)
/// that STT engines faithfully transcribe but users don't want
/// in their final text.
use regex::Regex;
use std::sync::LazyLock;

/// Regex matching standalone filler words (case-insensitive, word boundaries).
/// Matches: uh, um, uhm, umm, uh huh, mm, mmm, mhm, ah, eh, er, hmm, hm
/// Order matters: multi-word fillers first, then single-word.
static FILLER_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\b(uh\s+huh|u+h+m*|u+m+|m+h*m+|a+h+|e+h+|e+r+|h+m+m*|huh)\b").unwrap()
});

/// Regex for collapsing multiple spaces into one.
static MULTI_SPACE_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"  +").unwrap());

/// Remove filler words from transcribed text.
/// Preserves sentence structure and punctuation.
pub fn remove_fillers(text: &str) -> String {
    let cleaned = FILLER_RE.replace_all(text, "");
    let collapsed = MULTI_SPACE_RE.replace_all(&cleaned, " ");
    collapsed.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_remove_basic_fillers() {
        assert_eq!(
            remove_fillers("I uh think this is um good"),
            "I think this is good"
        );
    }

    #[test]
    fn test_remove_mmm_hmm() {
        assert_eq!(
            remove_fillers("mmm let me think hmm about that"),
            "let me think about that"
        );
    }

    #[test]
    fn test_remove_ah_eh() {
        assert_eq!(remove_fillers("ah well eh I guess so"), "well I guess so");
    }

    #[test]
    fn test_preserve_real_words() {
        // "um" inside "umbrella" should NOT be removed
        assert_eq!(
            remove_fillers("the umbrella is humid"),
            "the umbrella is humid"
        );
    }

    #[test]
    fn test_case_insensitive() {
        assert_eq!(remove_fillers("UH I mean UM yeah"), "I mean yeah");
    }

    #[test]
    fn test_empty_input() {
        assert_eq!(remove_fillers(""), "");
    }

    #[test]
    fn test_only_fillers() {
        assert_eq!(remove_fillers("uh um mmm"), "");
    }

    #[test]
    fn test_multiple_spaces_collapsed() {
        assert_eq!(remove_fillers("hello  uh  world"), "hello world");
    }

    #[test]
    fn test_uh_huh() {
        assert_eq!(remove_fillers("yeah uh huh that works"), "yeah that works");
    }
}
