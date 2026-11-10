use parakatt_core::{
    config::Config, dictionary::Dictionary, AppContext, ChunkSource, ReplacementRule,
};
use std::sync::Once;

// Evaluate log arguments, including rejected-pattern diagnostics, without retaining input data.
struct QuietLogger;
impl log::Log for QuietLogger {
    fn enabled(&self, _: &log::Metadata<'_>) -> bool {
        true
    }
    fn log(&self, _: &log::Record<'_>) {}
    fn flush(&self) {}
}
static LOGGER: QuietLogger = QuietLogger;
static INIT: Once = Once::new();

pub fn check(data: &[u8]) {
    INIT.call_once(|| {
        let _ = log::set_logger(&LOGGER);
        log::set_max_level(log::LevelFilter::Trace);
    });
    let text = String::from_utf8_lossy(data).into_owned();
    let mut dictionary = Dictionary::new();
    let rule = ReplacementRule {
        pattern: text.clone(),
        replacement: "replacement".into(),
        context_type: "always".into(),
        context_value: None,
        enabled: false,
    };
    dictionary.set_rules(vec![rule.clone()]);
    assert_eq!(
        dictionary.apply(&text, &AppContext::default(), "dictation"),
        text
    );
    assert_eq!(
        serde_json::to_value(dictionary.rules()).unwrap(),
        serde_json::to_value(vec![rule.clone()]).unwrap()
    );
    dictionary.set_rules(vec![ReplacementRule {
        enabled: true,
        ..rule
    }]);
    let _ = dictionary.apply(&text, &AppContext::default(), "dictation");
    dictionary.set_rules(vec![ReplacementRule {
        pattern: "token".into(),
        replacement: text.clone(),
        context_type: "always".into(),
        context_value: None,
        enabled: true,
    }]);
    assert_eq!(
        dictionary.apply("token", &AppContext::default(), "dictation"),
        text
    );

    let parts: Vec<String> = text.split('|').map(str::to_owned).collect();
    let expected: String = parts
        .iter()
        .flat_map(|part| part.chars())
        .filter(|c| !c.is_whitespace())
        .collect();
    let sources = (0..parts.len())
        .map(|i| {
            if i % 2 == 0 {
                ChunkSource::Mic
            } else {
                ChunkSource::System
            }
        })
        .collect();
    let assembled = parakatt_core::text_assembly::assemble_transcript_parts(parts, sources);
    assert_eq!(
        assembled
            .chars()
            .filter(|c| !c.is_whitespace())
            .collect::<String>(),
        expected
    );

    for provider in [
        parakatt_core::transcript_import::TranscriptProvider::Teams,
        parakatt_core::transcript_import::TranscriptProvider::Slack,
    ] {
        let request = parakatt_core::transcript_import::TranscriptImportRequest {
            provider,
            source_id: None,
            title: "Fuzzed meeting".into(),
            content: text.to_string(),
        };
        if let Ok(utterances) = parakatt_core::transcript_import::parse_transcript(&request) {
            assert!(!utterances.is_empty());
            for utterance in utterances {
                if let (Some(start), Some(end)) = (utterance.start_secs, utterance.end_secs) {
                    assert!(start.is_finite() && end.is_finite() && start >= 0.0 && end > start);
                } else {
                    assert!(utterance.start_secs.is_none() && utterance.end_secs.is_none());
                }
            }
        }
    }

    if let Ok(config) = toml::from_str::<Config>(&text) {
        let serialized = toml::to_string(&config).unwrap();
        let restored: Config = toml::from_str(&serialized).unwrap();
        assert_eq!(
            serde_json::to_value(config).unwrap(),
            serde_json::to_value(restored).unwrap()
        );
    }
}
