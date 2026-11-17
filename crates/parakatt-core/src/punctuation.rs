//! Conservative acceptance policy for optional Dictation punctuation cleanup.
//! Never use prompt compliance alone to decide whether a rewrite is safe.

pub(crate) const PROMPT: &str = "Correct only sentence punctuation, capitalization, and spacing in the transcribed text. Preserve every word in its original order, including fillers, repetitions, grammatical mistakes, spelling, names, and numbers. Do not correct spelling, add apostrophes to words, translate, summarize, explain, or format as Markdown. Preserve contractions, hyphens, identifiers, URLs, symbols, numeric punctuation, and existing line breaks. Return only the punctuated transcript, without quotation marks or commentary.";

#[derive(Clone, Copy, Default)]
pub(crate) enum OutputPolicy {
    #[default]
    Rewrite,
    PunctuationOnly,
}

impl OutputPolicy {
    pub fn for_mode(mode: &str) -> Self {
        if mode.eq_ignore_ascii_case("dictation") || mode.eq_ignore_ascii_case("punctuation") {
            Self::PunctuationOnly
        } else {
            Self::Rewrite
        }
    }
    pub fn validate(self, input: &str, output: &str) -> Result<(), crate::CoreError> {
        if matches!(self, Self::PunctuationOnly) && !preserves_words(input, output) {
            return Err(crate::CoreError::LlmError(
                "Punctuation cleanup skipped: wording changed. Original text was kept.".into(),
            ));
        }
        Ok(())
    }
}

fn sentence_punctuation(c: char) -> bool {
    matches!(
        c,
        '.' | ',' | '!' | '?' | ';' | ':' | '…' | '。' | '，' | '！' | '？' | '；' | '：'
    )
}

fn tokens(line: &str) -> Vec<String> {
    line.split_whitespace()
        .filter_map(|token| {
            // These spans are case-sensitive or use punctuation as data. Reject
            // even cosmetic edits rather than risk modifying a URL/identifier.
            let dotted_identifier = token.char_indices().any(|(index, c)| {
                c == '.'
                    && token
                        .get(..index)
                        .and_then(|s| s.chars().next_back())
                        .is_some_and(char::is_alphabetic)
                    && token
                        .get(index + 1..)
                        .and_then(|s| s.chars().next())
                        .is_some_and(char::is_alphabetic)
            });
            let numeric_start = token.trim_start_matches(sentence_punctuation);
            let numeric_prefix = numeric_start.len() != token.len()
                && numeric_start.chars().next().is_some_and(char::is_numeric);
            let protected = dotted_identifier
                || token.contains(['/', '\\', '@', '_', '`', '*', '=', '#'])
                || numeric_prefix;
            let normalized = if protected {
                token.to_string()
            } else {
                token.trim_matches(sentence_punctuation).to_lowercase()
            };
            (!normalized.is_empty()).then_some(normalized)
        })
        .collect()
}

fn preserves_words(input: &str, output: &str) -> bool {
    if input.trim().is_empty() || output.trim().is_empty() {
        return false;
    }
    // Preserve paragraph/line boundaries as well as word boundaries. Removing
    // all punctuation globally would incorrectly accept 42 -> 4.2 or don't -> dont.
    let original: Vec<_> = input.trim().lines().map(tokens).collect();
    let candidate: Vec<_> = output.trim().lines().map(tokens).collect();
    original.iter().any(|line| !line.is_empty()) && original == candidate
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_only_cosmetic_changes_and_keeps_unicode_words() {
        for (input, output) in [
            ("hello um how are you", "Hello, um, how are you?"),
            ("very very good", "Very, very good!"),
            ("talet är 42", "Talet är 42."),
            ("Åsa säger nej", "Åsa säger: nej."),
            ("don't re-enter", "Don't re-enter."),
            ("the value is 4.2", "The value is 4.2."),
            ("hello   world", "Hello, world!"),
            ("first line\nsecond line", "First line.\nSecond line."),
        ] {
            assert!(
                preserves_words(input, output),
                "rejected {input:?} -> {output:?}"
            );
        }
    }

    #[test]
    fn rejects_word_number_symbol_and_formatting_changes() {
        for (input, output) in [
            ("i dont know", "I don't know."),
            ("very very good", "Very good."),
            ("talet är 42", "The number is 42."),
            ("the value is 42", "The value is 4.2."),
            ("the value is 4.2", "The value is 42."),
            ("the value is 5", "The value is .5."),
            ("the value is 5", "The value is !.5."),
            ("the value is 5", "The value is :5."),
            ("the value is .5", "The value is 5."),
            ("cost is $5", "Cost is 5."),
            ("rate is 5%", "Rate is 5."),
            ("value is -5", "Value is 5."),
            ("import ant", "Important."),
            ("hello world", "Hello\nworld."),
            ("hello world", "- Hello world."),
            ("hello world", "\"Hello world.\""),
            ("hello world", "**Hello world.**"),
            ("hello world", "Corrected text: Hello world."),
            (
                "visit https://example.test/Path",
                "Visit https://example.test/path",
            ),
            ("use user_id", "Use user_ID."),
            ("open File.swift", "Open file.swift"),
            ("hello", ""),
            ("", "Hello."),
        ] {
            assert!(
                !preserves_words(input, output),
                "accepted {input:?} -> {output:?}"
            );
        }
        assert!(OutputPolicy::Rewrite.validate("words", "a rewrite").is_ok());
        assert!(OutputPolicy::PunctuationOnly
            .validate("words", "a rewrite")
            .is_err());
    }
}
