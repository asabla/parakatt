/// Configuration management.
///
/// Settings are stored in TOML format in the app's config directory.
/// The config file holds user preferences, active model selection,
/// LLM provider settings, and dictionary rules.

use std::path::{Path, PathBuf};

use crate::{CoreError, ModeConfig, ReplacementRule};

/// Persistent application configuration.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Config {
    #[serde(default)]
    pub general: GeneralConfig,
    #[serde(default)]
    pub stt: SttConfig,
    #[serde(default)]
    pub llm: LlmConfig,
    #[serde(default)]
    pub dictionary: Vec<ReplacementRule>,
    #[serde(default)]
    pub modes: Vec<ModeConfig>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct GeneralConfig {
    #[serde(default = "default_mode")]
    pub active_mode: String,
    #[serde(default = "default_true")]
    pub auto_paste: bool,
    #[serde(default = "default_true")]
    pub show_overlay: bool,
    /// Hotkey key name (e.g. "space", "r", "f1"). Default: "space".
    #[serde(default = "default_hotkey_key")]
    pub hotkey_key: String,
    /// Hotkey modifier names (e.g. ["option"], ["command", "shift"]). Default: ["option"].
    #[serde(default = "default_hotkey_modifiers")]
    pub hotkey_modifiers: Vec<String>,
    /// Hotkey mode: "hold" (release modifier to stop) or "toggle" (press again to stop). Default: "hold".
    #[serde(default = "default_hotkey_mode")]
    pub hotkey_mode: String,
    /// Preferred bundle ID for meeting audio source capture (e.g. "com.microsoft.teams2").
    #[serde(default)]
    pub preferred_audio_source_bundle_id: Option<String>,
    /// Auto-delete transcriptions older than this many days (0 = disabled).
    #[serde(default)]
    pub retention_days: u32,
}

impl Default for GeneralConfig {
    fn default() -> Self {
        Self {
            active_mode: default_mode(),
            auto_paste: true,
            show_overlay: true,
            hotkey_key: default_hotkey_key(),
            hotkey_modifiers: default_hotkey_modifiers(),
            hotkey_mode: default_hotkey_mode(),
            preferred_audio_source_bundle_id: None,
            retention_days: 0,
        }
    }
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct SttConfig {
    /// Model ID to use, e.g. "whisper-base.en"
    pub active_model: Option<String>,
}

impl Default for SttConfig {
    fn default() -> Self {
        Self {
            active_model: Some("parakeet-tdt-0.6b-v2".to_string()),
        }
    }
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct LlmConfig {
    /// Which LLM provider to use: "ollama", "lmstudio", "openai", "anthropic"
    pub active_provider: Option<String>,
    #[serde(default)]
    pub ollama: OllamaConfig,
    #[serde(default)]
    pub lmstudio: LmStudioConfig,
    #[serde(default)]
    pub openai: OpenAiConfig,
    #[serde(default)]
    pub anthropic: AnthropicConfig,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct OllamaConfig {
    #[serde(default = "default_ollama_url")]
    pub base_url: String,
    #[serde(default = "default_ollama_model")]
    pub model: String,
}

impl Default for OllamaConfig {
    fn default() -> Self {
        Self {
            base_url: default_ollama_url(),
            model: default_ollama_model(),
        }
    }
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct LmStudioConfig {
    #[serde(default = "default_lmstudio_url")]
    pub base_url: String,
    pub model: Option<String>,
}

impl Default for LmStudioConfig {
    fn default() -> Self {
        Self {
            base_url: default_lmstudio_url(),
            model: None,
        }
    }
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct OpenAiConfig {
    pub api_key: Option<String>,
    pub model: Option<String>,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct AnthropicConfig {
    pub api_key: Option<String>,
    pub model: Option<String>,
}

fn default_mode() -> String {
    "dictation".to_string()
}

fn default_true() -> bool {
    true
}

fn default_ollama_url() -> String {
    "http://localhost:11434".to_string()
}

fn default_ollama_model() -> String {
    "llama3.2".to_string()
}

fn default_lmstudio_url() -> String {
    "http://localhost:1234".to_string()
}

fn default_hotkey_key() -> String {
    "space".to_string()
}

fn default_hotkey_modifiers() -> Vec<String> {
    vec!["option".to_string()]
}

fn default_hotkey_mode() -> String {
    "hold".to_string()
}

impl Config {
    /// Load config from a TOML file, or return defaults if not found.
    pub fn load(config_dir: &Path) -> Result<Self, CoreError> {
        let path = config_path(config_dir);
        if path.exists() {
            let content = std::fs::read_to_string(&path)
                .map_err(|e| CoreError::ConfigError(format!("Failed to read config: {e}")))?;
            toml::from_str(&content)
                .map_err(|e| CoreError::ConfigError(format!("Failed to parse config: {e}")))
        } else {
            Ok(Self::default())
        }
    }

    /// Save config to a TOML file.
    pub fn save(&self, config_dir: &Path) -> Result<(), CoreError> {
        std::fs::create_dir_all(config_dir)
            .map_err(|e| CoreError::IoError(format!("Failed to create config dir: {e}")))?;

        let content = toml::to_string_pretty(self)
            .map_err(|e| CoreError::ConfigError(format!("Failed to serialize config: {e}")))?;

        let path = config_path(config_dir);
        std::fs::write(&path, content)
            .map_err(|e| CoreError::IoError(format!("Failed to write config: {e}")))?;

        Ok(())
    }
}

impl Default for Config {
    fn default() -> Self {
        Self {
            general: GeneralConfig::default(),
            stt: SttConfig::default(),
            llm: LlmConfig::default(),
            dictionary: Vec::new(),
            modes: crate::modes::default_modes(),
        }
    }
}

fn config_path(config_dir: &Path) -> PathBuf {
    config_dir.join("config.toml")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_config_roundtrip() {
        let config = Config::default();
        let serialized = toml::to_string_pretty(&config).unwrap();
        let deserialized: Config = toml::from_str(&serialized).unwrap();
        assert_eq!(deserialized.general.active_mode, "dictation");
        assert_eq!(deserialized.stt.active_model, Some("parakeet-tdt-0.6b-v2".to_string()));
    }

    #[test]
    fn test_load_missing_file() {
        let config = Config::load(Path::new("/tmp/parakatt-test-nonexistent")).unwrap();
        assert_eq!(config.general.active_mode, "dictation");
    }
}
