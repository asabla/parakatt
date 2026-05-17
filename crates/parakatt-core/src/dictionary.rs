/// Custom dictionary for domain-specific word replacement.
///
/// Operates as a post-processing step after STT, before LLM processing.
/// Rules are applied in order; patterns are matched case-insensitively
/// as whole words by default, or as regex if the pattern starts with "re:".
use crate::{AppContext, ReplacementRule};
use regex::Regex;

/// The dictionary engine that applies replacement rules to transcribed text.
#[derive(Debug, Default)]
pub struct Dictionary {
    rules: Vec<CompiledRule>,
}

#[derive(Debug)]
struct CompiledRule {
    source: ReplacementRule,
    regex: Regex,
}

impl Dictionary {
    pub fn new() -> Self {
        Self { rules: Vec::new() }
    }

    /// Replace the entire rule set, compiling patterns into regexes.
    pub fn set_rules(&mut self, rules: Vec<ReplacementRule>) {
        self.rules = rules
            .into_iter()
            .filter_map(|rule| {
                if !rule.enabled {
                    return None;
                }
                let regex = compile_pattern(&rule.pattern)?;
                Some(CompiledRule {
                    source: rule,
                    regex,
                })
            })
            .collect();
    }

    /// Get the current rules (source form, for serialization/UI).
    pub fn rules(&self) -> Vec<ReplacementRule> {
        self.rules.iter().map(|r| r.source.clone()).collect()
    }

    /// Apply all matching rules to the input text, respecting context.
    pub fn apply(&self, text: &str, context: &AppContext, mode: &str) -> String {
        let mut result = text.to_string();

        for rule in &self.rules {
            if !matches_context(&rule.source, context, mode) {
                continue;
            }
            result = rule
                .regex
                .replace_all(&result, rule.source.replacement.as_str())
                .into_owned();
        }

        result
    }
}

/// Maximum length for regex patterns to prevent excessive compilation time
/// or memory usage from adversarially large patterns.
const MAX_PATTERN_LENGTH: usize = 500;

/// Compile a pattern string into a Regex.
/// Patterns starting with "re:" are treated as raw regex.
/// Otherwise, the pattern is treated as a case-insensitive whole-word match.
fn compile_pattern(pattern: &str) -> Option<Regex> {
    if pattern.len() > MAX_PATTERN_LENGTH {
        log::warn!(
            "Dictionary pattern too long ({} chars, max {}): '{}'",
            pattern.len(),
            MAX_PATTERN_LENGTH,
            &pattern[..50]
        );
        return None;
    }

    let regex_str = if let Some(raw) = pattern.strip_prefix("re:") {
        raw.to_string()
    } else {
        // Whole-word, case-insensitive match
        format!(r"(?i)\b{}\b", regex::escape(pattern))
    };

    match Regex::new(&regex_str) {
        Ok(r) => Some(r),
        Err(e) => {
            log::warn!("Invalid dictionary pattern '{}': {}", pattern, e);
            None
        }
    }
}

/// Check if a rule's context constraint matches the current context.
fn matches_context(rule: &ReplacementRule, context: &AppContext, mode: &str) -> bool {
    match rule.context_type.as_str() {
        "always" => true,
        "in_app" => {
            if let (Some(target), Some(current)) = (&rule.context_value, &context.app_bundle_id) {
                target.eq_ignore_ascii_case(current)
            } else {
                false
            }
        }
        "when_mode" => {
            if let Some(target) = &rule.context_value {
                target.eq_ignore_ascii_case(mode)
            } else {
                false
            }
        }
        _ => true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_rule(pattern: &str, replacement: &str) -> ReplacementRule {
        ReplacementRule {
            pattern: pattern.to_string(),
            replacement: replacement.to_string(),
            context_type: "always".to_string(),
            context_value: None,
            enabled: true,
        }
    }

    fn default_ctx() -> AppContext {
        AppContext::default()
    }

    #[test]
    fn test_simple_replacement() {
        let mut dict = Dictionary::new();
        dict.set_rules(vec![make_rule("kubernetes", "Kubernetes")]);

        let result = dict.apply("deploy to kubernetes cluster", &default_ctx(), "dictation");
        assert_eq!(result, "deploy to Kubernetes cluster");
    }

    #[test]
    fn test_case_insensitive() {
        let mut dict = Dictionary::new();
        dict.set_rules(vec![make_rule("coodernettees", "Kubernetes")]);

        let result = dict.apply("Deploy to COODERNETTEES", &default_ctx(), "dictation");
        assert_eq!(result, "Deploy to Kubernetes");
    }

    #[test]
    fn test_whole_word_only() {
        let mut dict = Dictionary::new();
        dict.set_rules(vec![make_rule("is", "IS_REPLACED")]);

        // "is" inside "this" should NOT be replaced
        let result = dict.apply("this is a test", &default_ctx(), "dictation");
        assert_eq!(result, "this IS_REPLACED a test");
    }

    #[test]
    fn test_regex_pattern() {
        let mut dict = Dictionary::new();
        dict.set_rules(vec![make_rule("re:(?i)k8s|kates", "Kubernetes")]);

        assert_eq!(
            dict.apply("deploy k8s on kates", &default_ctx(), "dictation"),
            "deploy Kubernetes on Kubernetes"
        );
    }

    #[test]
    fn test_app_context() {
        let mut dict = Dictionary::new();
        dict.set_rules(vec![ReplacementRule {
            pattern: "pr".to_string(),
            replacement: "pull request".to_string(),
            context_type: "in_app".to_string(),
            context_value: Some("com.github.desktop".to_string()),
            enabled: true,
        }]);

        // Should NOT apply in a different app
        let ctx = AppContext {
            app_bundle_id: Some("com.apple.Notes".to_string()),
            ..Default::default()
        };
        assert_eq!(dict.apply("open a pr", &ctx, "dictation"), "open a pr");

        // Should apply in the target app
        let ctx = AppContext {
            app_bundle_id: Some("com.github.desktop".to_string()),
            ..Default::default()
        };
        assert_eq!(
            dict.apply("open a pr", &ctx, "dictation"),
            "open a pull request"
        );
    }

    #[test]
    fn test_disabled_rule() {
        let mut dict = Dictionary::new();
        dict.set_rules(vec![ReplacementRule {
            pattern: "foo".to_string(),
            replacement: "bar".to_string(),
            context_type: "always".to_string(),
            context_value: None,
            enabled: false,
        }]);

        assert_eq!(dict.apply("foo", &default_ctx(), "dictation"), "foo");
    }

    #[test]
    fn test_multiple_rules_applied_in_order() {
        let mut dict = Dictionary::new();
        dict.set_rules(vec![make_rule("eks", "EKS"), make_rule("aks", "AKS")]);

        let result = dict.apply("deploy to eks and aks", &default_ctx(), "dictation");
        assert_eq!(result, "deploy to EKS and AKS");
    }

    #[test]
    fn test_pattern_length_limit_drops_rule() {
        // ReDoS guard: patterns longer than MAX_PATTERN_LENGTH must be
        // dropped at compile time, not stored and matched at runtime.
        let mut dict = Dictionary::new();
        let huge = "a".repeat(MAX_PATTERN_LENGTH + 1);
        dict.set_rules(vec![make_rule(&huge, "X")]);

        // Rule was dropped — list of compiled rules is empty.
        assert_eq!(dict.rules().len(), 0);
        // And applying to text that *would* have matched is a no-op.
        let result = dict.apply(&format!("{} word", &huge), &default_ctx(), "dictation");
        assert!(result.contains(&huge));
    }

    #[test]
    fn test_invalid_regex_pattern_drops_rule_without_panicking() {
        // A malformed `re:` pattern must be ignored, not panic. Other
        // rules in the same set should still compile and apply.
        let mut dict = Dictionary::new();
        dict.set_rules(vec![
            make_rule("re:[unclosed", "BAD"),
            make_rule("hello", "HELLO"),
        ]);

        assert_eq!(dict.rules().len(), 1, "only the valid rule survives");
        assert_eq!(
            dict.apply("say hello there", &default_ctx(), "dictation"),
            "say HELLO there"
        );
    }

    #[test]
    fn test_literal_pattern_treats_dot_as_literal() {
        // Patterns without the "re:" prefix are literal — `.` must not
        // be interpreted as a regex any-char. A literal "c.js" pattern
        // must not match "ckjs" (which a raw regex `c.js` would).
        let mut dict = Dictionary::new();
        dict.set_rules(vec![make_rule("c.js", "C.js")]);

        assert_eq!(
            dict.apply("ckjs", &default_ctx(), "dictation"),
            "ckjs",
            "literal `.` must not act as regex any-char"
        );
        // The same pattern should still match the intended literal text.
        assert_eq!(
            dict.apply("learning c.js framework", &default_ctx(), "dictation"),
            "learning C.js framework"
        );
    }

    #[test]
    fn test_literal_pattern_ending_in_non_word_char_is_known_limitation() {
        // Documents a real limitation of the current implementation: the
        // literal-mode pattern wrapper `(?i)\b{pat}\b` relies on \b at the
        // tail, which only matches a word/non-word transition. A pattern
        // ending in a non-word character (e.g. "c++") therefore can't
        // match in this mode. Users hitting this need the `re:` prefix.
        // Pin the behaviour so any future fix announces itself by
        // breaking this test.
        let mut dict = Dictionary::new();
        dict.set_rules(vec![make_rule("c++", "C++")]);
        assert_eq!(
            dict.apply("learning c++ today", &default_ctx(), "dictation"),
            "learning c++ today",
            "literal patterns ending in non-word chars currently do not match"
        );
    }

    #[test]
    fn test_unicode_text_passes_through() {
        // Replacement must not corrupt unicode characters in surrounding
        // text. Without `(?i)\b...\b` handling unicode word boundaries
        // properly, a naive implementation might mangle accents.
        let mut dict = Dictionary::new();
        dict.set_rules(vec![make_rule("hej", "hi")]);

        let result = dict.apply("hej Åsa — håller på", &default_ctx(), "dictation");
        assert_eq!(result, "hi Åsa — håller på");
    }

    #[test]
    fn test_empty_input_is_noop() {
        let mut dict = Dictionary::new();
        dict.set_rules(vec![make_rule("anything", "everything")]);
        assert_eq!(dict.apply("", &default_ctx(), "dictation"), "");
    }

    #[test]
    fn test_when_mode_context_matching() {
        // Context_type "when_mode" should gate rules on the active mode
        // string, case-insensitively. The earlier test_app_context only
        // exercises `in_app` — this covers the other context flavor.
        let mut dict = Dictionary::new();
        dict.set_rules(vec![ReplacementRule {
            pattern: "todo".to_string(),
            replacement: "TODO".to_string(),
            context_type: "when_mode".to_string(),
            context_value: Some("code".to_string()),
            enabled: true,
        }]);

        // Not in code mode — no replacement.
        assert_eq!(
            dict.apply("add a todo", &default_ctx(), "dictation"),
            "add a todo"
        );
        // In code mode (case-insensitive) — replacement applies.
        assert_eq!(
            dict.apply("add a todo", &default_ctx(), "CODE"),
            "add a TODO"
        );
    }

    #[test]
    fn test_rule_order_chaining() {
        // Rules are applied sequentially over the *current* text, so
        // an earlier rule's output can be matched by a later rule.
        // Pin this behaviour because a future refactor that batched
        // all rules into a single pass would silently change it.
        let mut dict = Dictionary::new();
        dict.set_rules(vec![
            make_rule("k8s", "kubernetes"),
            make_rule("kubernetes", "Kubernetes"),
        ]);

        assert_eq!(
            dict.apply("deploy k8s", &default_ctx(), "dictation"),
            "deploy Kubernetes"
        );
    }

    #[test]
    fn test_replacement_does_not_recurse_infinitely() {
        // A self-replacing rule (replacement contains the pattern)
        // must not loop forever: `regex.replace_all` is a single pass.
        let mut dict = Dictionary::new();
        dict.set_rules(vec![make_rule("foo", "foo bar")]);

        assert_eq!(
            dict.apply("foo", &default_ctx(), "dictation"),
            "foo bar",
            "single-pass replace_all must not recurse"
        );
    }
}
