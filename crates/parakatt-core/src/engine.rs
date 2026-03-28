/// Core engine that orchestrates the full pipeline:
/// audio → preprocessing → STT → dictionary → LLM → result.

use std::path::PathBuf;
use std::sync::Mutex;

use crate::config::Config;
use crate::dictionary::Dictionary;
use crate::llm::{LlmProvider, LlmRequest};
use crate::modes;
use crate::models;
use crate::stt::SttProvider;
use crate::stt::parakeet::ParakeetProvider;
use crate::{
    AppContext, CoreError, EngineConfig, ModelInfo, ModeConfig, ReplacementRule,
    TranscriptionResult,
};

/// The main engine exposed to Swift via UniFFI.
#[derive(uniffi::Object)]
pub struct Engine {
    models_dir: PathBuf,
    config_dir: PathBuf,
    config: Mutex<Config>,
    stt: Mutex<Option<Box<dyn SttProvider>>>,
    llm: Mutex<Option<Box<dyn LlmProvider>>>,
    dictionary: Mutex<Dictionary>,
}

#[uniffi::export]
impl Engine {
    /// Create a new engine with the given configuration.
    #[uniffi::constructor]
    pub fn new(engine_config: EngineConfig) -> Result<Self, CoreError> {
        let models_dir = PathBuf::from(&engine_config.models_dir);
        let config_dir = PathBuf::from(&engine_config.config_dir);

        // Create directories if they don't exist
        std::fs::create_dir_all(&models_dir)
            .map_err(|e| CoreError::IoError(format!("Failed to create models dir: {e}")))?;
        std::fs::create_dir_all(&config_dir)
            .map_err(|e| CoreError::IoError(format!("Failed to create config dir: {e}")))?;

        // Load or create config
        let mut config = Config::load(&config_dir)?;

        // Override with engine config if provided
        if let Some(model) = &engine_config.active_stt_model {
            config.stt.active_model = Some(model.clone());
        }
        if let Some(provider) = &engine_config.active_llm_provider {
            config.llm.active_provider = Some(provider.clone());
        }
        config.general.active_mode = engine_config.active_mode;

        // Set up dictionary from config
        let mut dictionary = Dictionary::new();
        dictionary.set_rules(config.dictionary.clone());

        let engine = Self {
            models_dir,
            config_dir,
            config: Mutex::new(config),
            stt: Mutex::new(None),
            llm: Mutex::new(None),
            dictionary: Mutex::new(dictionary),
        };

        // Don't auto-load the model in the constructor — model loading
        // involves Metal GPU init which can be slow and should be done
        // explicitly by the caller (allows async/background loading).
        // The caller should call load_model() after construction.

        // Set up LLM provider if configured
        engine.setup_llm_provider()?;

        Ok(engine)
    }

    /// Run the full transcription pipeline.
    pub fn transcribe(
        &self,
        audio_samples: Vec<f32>,
        sample_rate: u32,
        mode: String,
        context: Option<AppContext>,
    ) -> Result<TranscriptionResult, CoreError> {
        // 1. Preprocess audio
        let processed = crate::audio::preprocess(&audio_samples, sample_rate)?;

        // 2. Run STT
        let stt_guard = self
            .stt
            .lock()
            .map_err(|e| CoreError::TranscriptionFailed(format!("STT lock poisoned: {e}")))?;

        let stt = stt_guard
            .as_ref()
            .ok_or_else(|| CoreError::TranscriptionFailed("No STT model loaded".into()))?;

        let mut result = stt.transcribe(&processed, sample_rate)?;

        // 3. Apply dictionary replacements
        let ctx = context.unwrap_or_default();
        let dict_guard = self.dictionary.lock().map_err(|e| {
            CoreError::TranscriptionFailed(format!("Dictionary lock poisoned: {e}"))
        })?;
        result.text = dict_guard.apply(&result.text, &ctx, &mode);
        drop(dict_guard);

        // 4. LLM post-processing (if mode has a system prompt and LLM is configured)
        let config_guard = self.config.lock().map_err(|e| {
            CoreError::ConfigError(format!("Config lock poisoned: {e}"))
        })?;
        let all_modes = if config_guard.modes.is_empty() {
            modes::default_modes()
        } else {
            config_guard.modes.clone()
        };
        drop(config_guard);

        if let Some(mode_config) = modes::find_mode(&all_modes, &mode) {
            if let Some(base_prompt) = &mode_config.system_prompt {
                let llm_guard = self.llm.lock().map_err(|e| {
                    CoreError::LlmError(format!("LLM lock poisoned: {e}"))
                })?;

                if let Some(llm) = llm_guard.as_ref() {
                    // Inject domain words into the system prompt
                    let dict_guard = self.dictionary.lock().map_err(|e| {
                        CoreError::LlmError(format!("Dictionary lock poisoned: {e}"))
                    })?;
                    let domain_words: Vec<String> = dict_guard
                        .rules()
                        .iter()
                        .filter(|r| r.pattern == r.replacement && r.enabled)
                        .map(|r| r.pattern.clone())
                        .collect();
                    drop(dict_guard);

                    let mut system_prompt = base_prompt.clone();
                    if !domain_words.is_empty() {
                        system_prompt.push_str(&format!(
                            "\n\nDomain-specific vocabulary (use these exact spellings when the \
                             transcription contains similar-sounding words): {}",
                            domain_words.join(", ")
                        ));
                    }

                    let llm_request = LlmRequest {
                        text: result.text.clone(),
                        system_prompt,
                        context: Some(ctx),
                    };

                    match llm.process(&llm_request) {
                        Ok(processed_text) => {
                            result.text = processed_text;
                        }
                        Err(e) => {
                            log::warn!("LLM processing failed, using raw transcription: {e}");
                            // Fall through with the un-processed text
                        }
                    }
                } else {
                    log::debug!(
                        "Mode '{}' has a system prompt but no LLM provider is configured",
                        mode
                    );
                }
            }
        }

        Ok(result)
    }

    /// Load an STT model by ID.
    pub fn load_model(&self, model_id: &str) -> Result<(), CoreError> {
        let model_path = models::model_path(&self.models_dir, model_id);

        // model_path is a directory for Parakeet models
        let provider: Box<dyn SttProvider> = if model_id.starts_with("parakeet-") {
            Box::new(ParakeetProvider::load(&model_path, model_id)?)
        } else {
            return Err(CoreError::ModelNotFound(format!(
                "Unknown model type: {model_id}"
            )));
        };

        let mut stt_guard = self.stt.lock().map_err(|e| {
            CoreError::ModelLoadFailed(format!("STT lock poisoned: {e}"))
        })?;
        *stt_guard = Some(provider);

        // Update config
        let mut config_guard = self.config.lock().map_err(|e| {
            CoreError::ConfigError(format!("Config lock poisoned: {e}"))
        })?;
        config_guard.stt.active_model = Some(model_id.to_string());
        let _ = config_guard.save(&self.config_dir);

        Ok(())
    }

    /// Unload the current STT model to free resources.
    pub fn unload_model(&self) {
        if let Ok(mut guard) = self.stt.lock() {
            *guard = None;
        }
    }

    /// Check if an STT model is currently loaded.
    pub fn is_model_loaded(&self) -> bool {
        self.stt
            .lock()
            .map(|guard| guard.is_some())
            .unwrap_or(false)
    }

    /// List available models with their download status.
    pub fn list_models(&self) -> Vec<ModelInfo> {
        models::list_models_with_status(&self.models_dir)
    }

    /// List all configured modes.
    pub fn list_modes(&self) -> Vec<ModeConfig> {
        self.config
            .lock()
            .map(|c| {
                if c.modes.is_empty() {
                    modes::default_modes()
                } else {
                    c.modes.clone()
                }
            })
            .unwrap_or_else(|_| modes::default_modes())
    }

    /// Update the dictionary rules.
    pub fn set_dictionary_rules(&self, rules: Vec<ReplacementRule>) -> Result<(), CoreError> {
        let mut dict_guard = self.dictionary.lock().map_err(|e| {
            CoreError::ConfigError(format!("Dictionary lock poisoned: {e}"))
        })?;
        dict_guard.set_rules(rules.clone());

        // Persist to config
        let mut config_guard = self.config.lock().map_err(|e| {
            CoreError::ConfigError(format!("Config lock poisoned: {e}"))
        })?;
        config_guard.dictionary = rules;
        let _ = config_guard.save(&self.config_dir);

        Ok(())
    }

    /// Get current dictionary rules.
    pub fn get_dictionary_rules(&self) -> Vec<ReplacementRule> {
        self.dictionary
            .lock()
            .map(|d| d.rules())
            .unwrap_or_default()
    }

    /// Configure the LLM provider at runtime.
    /// provider: "ollama", "lmstudio", "openai", or "" to disable.
    /// base_url: server URL (e.g. "http://localhost:11434").
    /// model: model name (e.g. "llama3.2", "gpt-4o-mini").
    /// api_key: API key (only for openai).
    pub fn configure_llm(
        &self,
        provider: String,
        base_url: String,
        model: String,
        api_key: Option<String>,
    ) -> Result<(), CoreError> {
        let llm: Option<Box<dyn LlmProvider>> = match provider.as_str() {
            "ollama" => Some(Box::new(crate::llm::ollama::OllamaProvider::new(
                &base_url, &model,
            ))),
            "lmstudio" => Some(Box::new(
                crate::llm::openai::OpenAiCompatibleProvider::lmstudio(&base_url, &model),
            )),
            "openai" => {
                let key = api_key.clone().ok_or_else(|| {
                    CoreError::ConfigError("OpenAI requires an API key".into())
                })?;
                Some(Box::new(
                    crate::llm::openai::OpenAiCompatibleProvider::openai(&key, &model),
                ))
            }
            "" | "none" => None,
            other => {
                return Err(CoreError::ConfigError(format!(
                    "Unknown LLM provider: {other}"
                )));
            }
        };

        // Update runtime state
        let mut llm_guard = self.llm.lock().map_err(|e| {
            CoreError::ConfigError(format!("LLM lock poisoned: {e}"))
        })?;
        *llm_guard = llm;

        // Persist to config
        let mut config_guard = self.config.lock().map_err(|e| {
            CoreError::ConfigError(format!("Config lock poisoned: {e}"))
        })?;
        config_guard.llm.active_provider = if provider.is_empty() || provider == "none" {
            None
        } else {
            Some(provider.clone())
        };
        match provider.as_str() {
            "ollama" => {
                config_guard.llm.ollama.base_url = base_url;
                config_guard.llm.ollama.model = model;
            }
            "lmstudio" => {
                config_guard.llm.lmstudio.base_url = base_url;
                config_guard.llm.lmstudio.model = Some(model);
            }
            "openai" => {
                config_guard.llm.openai.api_key = api_key;
                config_guard.llm.openai.model = Some(model);
            }
            _ => {}
        }
        let _ = config_guard.save(&self.config_dir);

        Ok(())
    }

}

impl Engine {
    /// Set up the LLM provider based on current config.
    fn setup_llm_provider(&self) -> Result<(), CoreError> {
        let config_guard = self.config.lock().map_err(|e| {
            CoreError::ConfigError(format!("Config lock poisoned: {e}"))
        })?;

        let provider: Option<Box<dyn LlmProvider>> = match config_guard
            .llm
            .active_provider
            .as_deref()
        {
            Some("ollama") => Some(Box::new(crate::llm::ollama::OllamaProvider::new(
                &config_guard.llm.ollama.base_url,
                &config_guard.llm.ollama.model,
            ))),
            Some("lmstudio") => {
                let model = config_guard
                    .llm
                    .lmstudio
                    .model
                    .as_deref()
                    .unwrap_or("default");
                Some(Box::new(
                    crate::llm::openai::OpenAiCompatibleProvider::lmstudio(
                        &config_guard.llm.lmstudio.base_url,
                        model,
                    ),
                ))
            }
            Some("openai") => {
                if let Some(key) = &config_guard.llm.openai.api_key {
                    let model = config_guard
                        .llm
                        .openai
                        .model
                        .as_deref()
                        .unwrap_or("gpt-4o-mini");
                    Some(Box::new(
                        crate::llm::openai::OpenAiCompatibleProvider::openai(key, model),
                    ))
                } else {
                    log::warn!("OpenAI provider selected but no API key configured");
                    None
                }
            }
            Some(other) => {
                log::warn!("Unknown LLM provider: {other}");
                None
            }
            None => None,
        };

        drop(config_guard);

        let mut llm_guard = self.llm.lock().map_err(|e| {
            CoreError::ConfigError(format!("LLM lock poisoned: {e}"))
        })?;
        *llm_guard = provider;

        Ok(())
    }
}
