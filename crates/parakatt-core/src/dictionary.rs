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
}
