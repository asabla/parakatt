//! Processing boundaries are not paragraph boundaries. Preserve explicit paragraphs
//! within model output, and separate different audio sources without guessing words.
use crate::ChunkSource;

#[uniffi::export]
pub fn assemble_transcript_parts(parts: Vec<String>, sources: Vec<ChunkSource>) -> String {
    if parts.len() == 1 {
        return parts[0].clone();
    }
    let mut result = String::new();
    let mut previous_source = None;
    let mut explicit_break = false;
    for (index, part) in parts.iter().enumerate() {
        let text = part.trim();
        if text.is_empty() {
            continue;
        }
        let source = sources.get(index).copied().unwrap_or(ChunkSource::Mixed);
        if !result.is_empty() {
            if previous_source != Some(source) || explicit_break || part.starts_with("\n\n") {
                result.push_str("\n\n");
            } else if !text.starts_with(['.', ',', '!', '?', ':', ';']) {
                result.push(' ');
            }
        }
        result.push_str(text);
        previous_source = Some(source);
        explicit_break = part.ends_with("\n\n");
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn preserves_sentences_paragraphs_and_intentional_repetition() {
        for parts in [
            vec![
                "This sentence",
                "continues. Yes",
                "yes, this is deliberate.",
            ],
            vec![
                "Den här meningen",
                "fortsätter. Ja",
                "ja, det är avsiktligt.",
            ],
        ] {
            let owned = parts.iter().map(|s| s.to_string()).collect();
            assert_eq!(assemble_transcript_parts(owned, vec![]), parts.join(" "));
        }
        assert_eq!(
            assemble_transcript_parts(
                vec!["First paragraph.\n\nSecond".into(), "paragraph.".into()],
                vec![]
            ),
            "First paragraph.\n\nSecond paragraph."
        );
        assert_eq!(
            assemble_transcript_parts(vec!["Hello".into(), ", world.".into()], vec![]),
            "Hello, world."
        );
        assert_eq!(
            assemble_transcript_parts(
                vec!["Question?".into(), "Answer.".into()],
                vec![ChunkSource::Mic, ChunkSource::System]
            ),
            "Question?\n\nAnswer."
        );
    }
}
