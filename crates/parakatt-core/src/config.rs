use std::io::Write;
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
    /// Internal migration version, not a user-facing processing preference.
    #[serde(default)]
    pub text_processing_version: u32,
    #[serde(default)]
    pub recovery_audio: bool,
    /// Legacy value retained for configuration/API compatibility. Context is automatic.
    #[serde(default)]
    pub llm_context_enabled: bool,
    /// Legacy flag migrated to the dedicated Punctuation mode on load.
    #[serde(default)]
    pub dictation_punctuation_enabled: bool,
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
    /// Chunk duration in seconds for meeting transcription (default: 30).
    #[serde(default = "default_chunk_duration")]
    pub chunk_duration_secs: u32,
    /// Maximum word count to send to LLM per chunk (default: 4000).
    #[serde(default = "default_llm_max_words")]
    pub llm_max_words: u32,
    /// Enable verbose debug logging.
    #[serde(default)]
    pub debug_mode: bool,
    /// Per-app mode defaults: maps bundle ID to mode name.
    /// e.g., {"com.microsoft.VSCode": "code", "com.apple.mail": "email"}
    #[serde(default)]
    pub app_mode_defaults: std::collections::HashMap<String, String>,
    /// Whether the cache-aware streaming live preview is enabled
    /// for this user. Defaults to true so English speakers get the
    /// fast preview by default; users who don't want the extra ~1.2 GB
    /// model can flip this off and the preview falls back to the
    /// buffered v3 + LA-2 path. Streaming preview is also auto-disabled
    /// at runtime when no Nemotron model is downloaded — this flag
    /// is the user's expressed preference, not a hard gate.
    #[serde(default = "default_true")]
    pub streaming_preview_enabled: bool,
    /// Whether to label meeting segments by audio source. The microphone is
    /// tagged "Me" and all system audio is tagged "Speaker 1". Off by default;
    /// individual speakers are not identified and no extra model is downloaded.
    #[serde(default)]
    pub speaker_labels_enabled: bool,
}

fn default_chunk_duration() -> u32 {
    30
}

fn default_llm_max_words() -> u32 {
    4000
}

impl Default for GeneralConfig {
    fn default() -> Self {
        Self {
            text_processing_version: 1,
            recovery_audio: false,
            llm_context_enabled: false,
            dictation_punctuation_enabled: false,
            active_mode: default_mode(),
            auto_paste: true,
            show_overlay: true,
            hotkey_key: default_hotkey_key(),
            hotkey_modifiers: default_hotkey_modifiers(),
            hotkey_mode: default_hotkey_mode(),
            preferred_audio_source_bundle_id: None,
            retention_days: 0,
            chunk_duration_secs: default_chunk_duration(),
            llm_max_words: default_llm_max_words(),
            debug_mode: false,
            app_mode_defaults: std::collections::HashMap::new(),
            streaming_preview_enabled: true,
            speaker_labels_enabled: false,
        }
    }
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct SttConfig {
    /// Model ID to use, e.g. "whisper-base.en"
    pub active_model: Option<String>,
    #[serde(default)]
    pub settings: crate::speech::SpeechSettings,
}

impl Default for SttConfig {
    fn default() -> Self {
        Self {
            active_model: Some("parakeet-tdt-0.6b-v3".to_string()),
            settings: Default::default(),
        }
    }
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct LlmConfig {
    #[serde(default)]
    pub generation: crate::llm::GenerationSettings,
    /// Which LLM provider to use: "ollama", "lmstudio", "openai", "chatgpt", "anthropic"
    pub active_provider: Option<String>,
    #[serde(default)]
    pub ollama: OllamaConfig,
    #[serde(default)]
    pub lmstudio: LmStudioConfig,
    #[serde(default)]
    pub openai: OpenAiConfig,
    #[serde(default)]
    pub chatgpt: ChatGptConfig,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub credential_account: Option<String>,
    pub api_key: Option<String>,
    pub model: Option<String>,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct ChatGptConfig {
    pub account_id: Option<String>,
    pub model: Option<String>,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct AnthropicConfig {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub credential_account: Option<String>,
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
            toml::from_str::<Self>(&content)
                .map(Self::migrate_processing)
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
        atomic_write(&path, content.as_bytes())?;

        Ok(())
    }

    // --- Profile management ---

    /// Save the current config as a named profile.
    pub fn save_profile(&self, config_dir: &Path, name: &str) -> Result<(), CoreError> {
        validate_profile_name(name)?;
        if self.llm.openai.api_key.is_some() || self.llm.anthropic.api_key.is_some() {
            return Err(CoreError::ConfigError(
                "Complete credential migration before saving a profile".into(),
            ));
        }
        let profiles_dir = config_dir.join("profiles");
        std::fs::create_dir_all(&profiles_dir)
            .map_err(|e| CoreError::IoError(format!("Failed to create profiles dir: {e}")))?;

        let mut profile = self.clone();
        profile.llm.openai.api_key = None;
        profile.llm.anthropic.api_key = None;
        let content = toml::to_string_pretty(&profile)
            .map_err(|e| CoreError::ConfigError(format!("Failed to serialize profile: {e}")))?;

        let path = profiles_dir.join(format!("{name}.toml"));
        atomic_write(&path, content.as_bytes())?;

        log::info!("Saved profile: {name}");
        Ok(())
    }

    /// Used only after the corresponding Keychain storage succeeds. Other
    /// providers' unmigrated credentials must remain in the source file.
    pub(crate) fn write_migrated_profile(
        &self,
        config_dir: &Path,
        name: &str,
    ) -> Result<(), CoreError> {
        validate_profile_name(name)?;
        let directory = config_dir.join("profiles");
        std::fs::create_dir_all(&directory).map_err(|e| CoreError::IoError(e.to_string()))?;
        let text =
            toml::to_string_pretty(self).map_err(|e| CoreError::ConfigError(e.to_string()))?;
        atomic_write(&directory.join(format!("{name}.toml")), text.as_bytes())
    }

    /// Load a named profile, replacing the current config.
    pub fn load_profile(config_dir: &Path, name: &str) -> Result<Self, CoreError> {
        validate_profile_name(name)?;
        let path = config_dir.join("profiles").join(format!("{name}.toml"));
        if !path.exists() {
            return Err(CoreError::ConfigError(format!("Profile not found: {name}")));
        }
        let content = std::fs::read_to_string(&path)
            .map_err(|e| CoreError::ConfigError(format!("Failed to read profile: {e}")))?;
        toml::from_str::<Self>(&content)
            .map(Self::migrate_processing)
            .map_err(|e| CoreError::ConfigError(format!("Failed to parse profile: {e}")))
    }

    /// Collapse the old Dictation + punctuation switch into a real mode.
    /// This is an in-memory migration until the next successful configuration save.
    fn migrate_processing(mut self) -> Self {
        // A user could previously create a custom mode with this name. Keep
        // its prompt and references instead of turning it into punctuation-only.
        if let Some(index) = self.modes.iter().position(|m| {
            self.general.text_processing_version == 0
                && m.name.eq_ignore_ascii_case("punctuation")
                && m.system_prompt.as_deref() != Some(crate::punctuation::PROMPT)
        }) {
            let mut name = "punctuation (custom)".to_string();
            let mut suffix = 2;
            while self
                .modes
                .iter()
                .any(|m| m.name.eq_ignore_ascii_case(&name))
            {
                name = format!("punctuation (custom {suffix})");
                suffix += 1;
            }
            if let Some(mode) = self.modes.get_mut(index) {
                mode.name = name.clone();
            }
            if self.general.active_mode.eq_ignore_ascii_case("punctuation") {
                self.general.active_mode = name.clone();
            }
            for mode in self.general.app_mode_defaults.values_mut() {
                if mode.eq_ignore_ascii_case("punctuation") {
                    *mode = name.clone();
                }
            }
        }
        if !self.modes.is_empty()
            && !self
                .modes
                .iter()
                .any(|m| m.name.eq_ignore_ascii_case("punctuation"))
        {
            if let Some(mode) = crate::modes::default_modes()
                .into_iter()
                .find(|m| m.name == "punctuation")
            {
                self.modes.push(mode);
            }
        }
        if self.general.dictation_punctuation_enabled {
            if self.general.active_mode.eq_ignore_ascii_case("dictation") {
                self.general.active_mode = "punctuation".into();
            }
            for mode in self.general.app_mode_defaults.values_mut() {
                if mode.eq_ignore_ascii_case("dictation") {
                    *mode = "punctuation".into();
                }
            }
            self.general.dictation_punctuation_enabled = false;
        }
        self.general.text_processing_version = self.general.text_processing_version.max(1);
        self
    }

    /// List available profile names.
    pub fn list_profiles(config_dir: &Path) -> Vec<String> {
        let profiles_dir = config_dir.join("profiles");
        let Ok(entries) = std::fs::read_dir(profiles_dir) else {
            return Vec::new();
        };
        entries
            .flatten()
            .filter_map(|e| {
                let path = e.path();
                if path.extension().and_then(|s| s.to_str()) == Some("toml") {
                    path.file_stem()
                        .and_then(|s| s.to_str())
                        .map(|s| s.to_string())
                } else {
                    None
                }
            })
            .collect()
    }

    /// Delete a named profile.
    pub fn delete_profile(config_dir: &Path, name: &str) -> Result<(), CoreError> {
        validate_profile_name(name)?;
        let path = config_dir.join("profiles").join(format!("{name}.toml"));
        if path.exists() {
            std::fs::remove_file(&path)
                .map_err(|e| CoreError::IoError(format!("Failed to delete profile: {e}")))?;
        }
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

fn validate_profile_name(name: &str) -> Result<(), CoreError> {
    if name.trim().is_empty()
        || name.contains(['/', '\\'])
        || name.chars().any(char::is_control)
        || name == "."
        || name == ".."
    {
        return Err(CoreError::ConfigError("Invalid profile name".into()));
    }
    Ok(())
}

fn config_path(config_dir: &Path) -> PathBuf {
    config_dir.join("config.toml")
}

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), CoreError> {
    let temporary = path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| -> std::io::Result<()> {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        std::fs::rename(&temporary, path)
    })();
    if result.is_err() {
        if let Err(cleanup) = std::fs::remove_file(&temporary) {
            if cleanup.kind() != std::io::ErrorKind::NotFound {
                log::warn!("Could not remove temporary configuration: {cleanup}");
            }
        }
    }
    result.map_err(|e| CoreError::IoError(format!("Failed to replace configuration: {e}")))
}

#[cfg(test)]
mod tests {
    #[test]
    fn processing_migration_preserves_existing_choices_without_enabling_a_provider() {
        for active in ["dictation", "clean", "email", "code", "custom"] {
            let mut legacy = super::Config::default();
            legacy.general.text_processing_version = 0;
            legacy.modes.retain(|m| m.name != "punctuation");
            legacy.general.active_mode = active.into();
            legacy.general.dictation_punctuation_enabled = true;
            legacy
                .general
                .app_mode_defaults
                .insert("app.raw".into(), "dictation".into());
            legacy
                .general
                .app_mode_defaults
                .insert("app.clean".into(), "clean".into());
            let directory = tempfile::tempdir().unwrap();
            legacy.save(directory.path()).unwrap();
            let original = std::fs::read(directory.path().join("config.toml")).unwrap();
            let migrated = super::Config::load(directory.path()).unwrap();
            assert_eq!(
                migrated.general.active_mode,
                if active == "dictation" {
                    "punctuation"
                } else {
                    active
                }
            );
            assert_eq!(migrated.general.app_mode_defaults["app.raw"], "punctuation");
            assert_eq!(migrated.general.app_mode_defaults["app.clean"], "clean");
            assert!(!migrated.general.dictation_punctuation_enabled);
            assert!(migrated.llm.active_provider.is_none());
            assert_eq!(
                migrated
                    .modes
                    .iter()
                    .filter(|m| m.name == "punctuation")
                    .count(),
                1
            );
            assert_eq!(
                original,
                std::fs::read(directory.path().join("config.toml")).unwrap()
            );
            migrated.save(directory.path()).unwrap();
            assert_eq!(
                super::Config::load(directory.path())
                    .unwrap()
                    .general
                    .active_mode,
                migrated.general.active_mode
            );
        }
        let mut off = super::Config::default();
        off.modes.retain(|m| m.name != "punctuation");
        let off = off.migrate_processing();
        assert_eq!(off.general.active_mode, "dictation");
        assert!(!off.general.dictation_punctuation_enabled);
    }
    #[test]
    fn punctuation_name_collision_preserves_custom_prompt_and_references() {
        let mut config = super::Config::default();
        config.general.text_processing_version = 0;
        let custom = config
            .modes
            .iter_mut()
            .find(|m| m.name == "punctuation")
            .unwrap();
        custom.system_prompt = Some("My existing custom instructions".into());
        config.general.active_mode = "punctuation".into();
        config
            .general
            .app_mode_defaults
            .insert("editor".into(), "punctuation".into());
        let migrated = config.migrate_processing();
        assert_eq!(migrated.general.active_mode, "punctuation (custom)");
        assert_eq!(
            migrated.general.app_mode_defaults["editor"],
            "punctuation (custom)"
        );
        assert_eq!(
            migrated
                .modes
                .iter()
                .find(|m| m.name == "punctuation (custom)")
                .unwrap()
                .system_prompt
                .as_deref(),
            Some("My existing custom instructions")
        );
        assert!(migrated.modes.iter().any(|m| m.name == "punctuation"
            && m.system_prompt.as_deref() == Some(crate::punctuation::PROMPT)));
        let mut modern = migrated;
        modern.general.active_mode = "punctuation".into();
        modern
            .modes
            .iter_mut()
            .find(|m| m.name == "punctuation")
            .unwrap()
            .system_prompt = Some("Previous built-in prompt revision".into());
        assert_eq!(modern.migrate_processing().general.active_mode, "punctuation", "A future prompt revision must not turn the guarded built-in into an unguarded custom mode");
    }
    #[test]
    fn atomic_configuration_failures_leave_no_temporary_files() {
        let dir = tempfile::tempdir().unwrap();
        let missing_parent = dir.path().join("missing/config.toml");
        assert!(super::atomic_write(&missing_parent, b"value").is_err());
        std::fs::write(dir.path().join("file"), b"original").unwrap();
        assert!(super::atomic_write(&dir.path().join("file/config.toml"), b"value").is_err());
        let target_directory = dir.path().join("config.toml");
        std::fs::create_dir(&target_directory).unwrap();
        assert!(super::atomic_write(&target_directory, b"value").is_err());
        let mut names = std::fs::read_dir(dir.path())
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect::<Vec<_>>();
        names.sort();
        assert_eq!(
            names,
            vec![
                std::ffi::OsString::from("config.toml"),
                std::ffi::OsString::from("file")
            ]
        );
        assert_eq!(std::fs::read(dir.path().join("file")).unwrap(), b"original");
    }
    use super::*;

    #[test]
    fn profile_paths_cannot_escape_the_profiles_directory() {
        let directory = tempfile::tempdir().unwrap();
        let config = Config::default();
        config.save(directory.path()).unwrap();
        let original = std::fs::read(directory.path().join("config.toml")).unwrap();
        for name in [
            "",
            " ",
            ".",
            "..",
            "../config",
            "..\\config",
            "/tmp/profile",
            "a/b",
            "a\n",
        ] {
            assert!(
                config.save_profile(directory.path(), name).is_err(),
                "{name:?}"
            );
            assert!(
                Config::load_profile(directory.path(), name).is_err(),
                "{name:?}"
            );
            assert!(
                Config::delete_profile(directory.path(), name).is_err(),
                "{name:?}"
            );
            assert!(
                config
                    .write_migrated_profile(directory.path(), name)
                    .is_err(),
                "{name:?}"
            );
            assert_eq!(
                std::fs::read(directory.path().join("config.toml")).unwrap(),
                original
            );
        }
        config
            .save_profile(directory.path(), "Svenska möten.1")
            .unwrap();
        Config::load_profile(directory.path(), "Svenska möten.1").unwrap();
        Config::delete_profile(directory.path(), "Svenska möten.1").unwrap();
        assert_eq!(
            std::fs::read(directory.path().join("config.toml")).unwrap(),
            original
        );
    }

    #[test]
    fn test_default_config_roundtrip() {
        let config = Config::default();
        let serialized = toml::to_string_pretty(&config).unwrap();
        let deserialized: Config = toml::from_str(&serialized).unwrap();
        assert_eq!(deserialized.general.active_mode, "dictation");
        assert_eq!(
            deserialized.stt.active_model,
            Some("parakeet-tdt-0.6b-v3".to_string())
        );
    }

    #[test]
    fn test_load_missing_file() {
        let config = Config::load(Path::new("/tmp/parakatt-test-nonexistent")).unwrap();
        assert_eq!(config.general.active_mode, "dictation");
    }
    #[test]
    fn legacy_settings_keep_explicit_selections_and_credentials_until_acknowledged() {
        let mut config = Config::default();
        config.general.streaming_preview_enabled = false;
        config.llm.openai.model = Some("configured-model-id".into());
        config.llm.openai.api_key = Some("mock-legacy-key".into());
        let encoded = toml::to_string(&config).unwrap();
        let decoded: Config = toml::from_str(&encoded).unwrap();
        assert!(!decoded.general.streaming_preview_enabled);
        assert_eq!(
            decoded.llm.openai.model.as_deref(),
            Some("configured-model-id")
        );
        assert_eq!(
            decoded.llm.openai.api_key.as_deref(),
            Some("mock-legacy-key")
        );
        let dir = tempfile::tempdir().unwrap();
        assert!(decoded.save_profile(dir.path(), "example").is_err());
        let credential = crate::credentials::pending(&decoded, dir.path()).remove(0);
        let migrated = crate::credentials::migrate(&decoded, &credential).unwrap();
        migrated.save_profile(dir.path(), "example").unwrap();
        let profile = std::fs::read_to_string(dir.path().join("profiles/example.toml")).unwrap();
        assert!(!profile.contains("mock-legacy-key"));
    }
}
