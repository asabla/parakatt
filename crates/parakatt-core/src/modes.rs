/// Built-in and custom processing modes.
///
/// Each mode configures the pipeline: which STT provider to use,
/// whether to run LLM post-processing, and with what system prompt.

use crate::ModeConfig;

/// Return the default set of built-in modes.
pub fn default_modes() -> Vec<ModeConfig> {
    vec![
        ModeConfig {
            name: "dictation".to_string(),
            stt_provider: None, // use engine default
            llm_provider: None, // no LLM processing
            system_prompt: None,
            dictionary_enabled: true,
        },
        ModeConfig {
            name: "clean".to_string(),
            stt_provider: None,
            llm_provider: None, // will use engine default when set
            system_prompt: Some(
                "Fix grammar, spelling, and punctuation. \
                 Keep the original meaning and tone. \
                 Do not add or remove content. \
                 Return only the corrected text."
                    .to_string(),
            ),
            dictionary_enabled: true,
        },
        ModeConfig {
            name: "email".to_string(),
            stt_provider: None,
            llm_provider: None,
            system_prompt: Some(
                "Format the following dictated text as a professional email. \
                 Fix grammar and punctuation. \
                 Add appropriate greeting and sign-off if not present. \
                 Return only the formatted email text."
                    .to_string(),
            ),
            dictionary_enabled: true,
        },
        ModeConfig {
            name: "code".to_string(),
            stt_provider: None,
            llm_provider: None,
            system_prompt: Some(
                "The user is dictating in a code editor. \
                 Preserve technical terms, function names, and identifiers exactly. \
                 Convert spoken descriptions to appropriate code-like text. \
                 Fix obvious transcription errors for programming terms. \
                 Return only the corrected text."
                    .to_string(),
            ),
            dictionary_enabled: true,
        },
    ]
}

/// Find a mode by name (case-insensitive).
pub fn find_mode<'a>(modes: &'a [ModeConfig], name: &str) -> Option<&'a ModeConfig> {
    modes.iter().find(|m| m.name.eq_ignore_ascii_case(name))
}
