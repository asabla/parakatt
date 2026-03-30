/// Core engine that orchestrates the full pipeline:
/// audio → preprocessing → STT → dictionary → LLM → result.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use crate::config::Config;
use crate::dictionary::Dictionary;
use crate::llm::{LlmProvider, LlmRequest};
use crate::modes;
use crate::models;
use crate::stt::SttProvider;
use crate::stt::parakeet::ParakeetProvider;
use crate::download::{DownloadProgress, DownloadState};
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
    download_progress: Arc<Mutex<DownloadProgress>>,
    download_cancel: Arc<AtomicBool>,
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
            download_progress: Arc::new(Mutex::new(DownloadProgress::idle())),
            download_cancel: Arc::new(AtomicBool::new(false)),
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
                // Skip LLM if transcription is empty
                if result.text.trim().is_empty() {
                    log::debug!("Skipping LLM: transcription is empty");
                    return Ok(result);
                }

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

    /// Fetch available LLM models from a provider's API.
    /// Returns a list of model name strings.
    pub fn list_llm_models(
        &self,
        provider: String,
        base_url: String,
        api_key: Option<String>,
    ) -> Result<Vec<String>, CoreError> {
        let client = reqwest::blocking::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .map_err(|e| CoreError::LlmError(format!("HTTP client error: {e}")))?;

        let url = base_url.trim_end_matches('/');

        match provider.as_str() {
            "ollama" => {
                let resp = client
                    .get(format!("{url}/api/tags"))
                    .send()
                    .map_err(|e| CoreError::LlmError(format!("Cannot reach Ollama at {url}: {e}")))?;

                let json: serde_json::Value = resp
                    .json()
                    .map_err(|e| CoreError::LlmError(format!("Invalid response: {e}")))?;

                let models = json["models"]
                    .as_array()
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|m| m["name"].as_str().map(|s| s.to_string()))
                            .collect()
                    })
                    .unwrap_or_default();

                Ok(models)
            }
            "lmstudio" | "openai" => {
                let models_url = format!("{url}/v1/models");
                let mut req = client.get(&models_url);
                if let Some(key) = &api_key {
                    req = req.header("Authorization", format!("Bearer {key}"));
                }

                let resp = req
                    .send()
                    .map_err(|e| CoreError::LlmError(format!("Cannot reach {provider} at {url}: {e}")))?;

                let json: serde_json::Value = resp
                    .json()
                    .map_err(|e| CoreError::LlmError(format!("Invalid response: {e}")))?;

                let models = json["data"]
                    .as_array()
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|m| m["id"].as_str().map(|s| s.to_string()))
                            .collect()
                    })
                    .unwrap_or_default();

                Ok(models)
            }
            _ => Err(CoreError::LlmError(format!("Unknown provider: {provider}"))),
        }
    }

    /// Start downloading a model in the background. Returns immediately.
    /// Poll `get_download_progress()` to track status.
    pub fn start_download(&self, model_id: String) -> Result<(), CoreError> {
        // Validate model exists in registry
        if models::model_file_set(&model_id).is_none() {
            return Err(CoreError::ModelNotFound(format!(
                "No download info for model: {model_id}"
            )));
        }

        // Check not already downloading
        {
            let p = self.download_progress.lock().unwrap();
            if p.state == DownloadState::Downloading {
                return Err(CoreError::IoError(
                    "A download is already in progress".into(),
                ));
            }
        }

        // Reset cancel flag
        self.download_cancel.store(false, Ordering::Relaxed);

        let models_dir = self.models_dir.clone();
        let progress = Arc::clone(&self.download_progress);
        let cancel = Arc::clone(&self.download_cancel);

        std::thread::spawn(move || {
            if let Err(e) = crate::download::download_model(&models_dir, &model_id, progress.clone(), cancel) {
                log::error!("Download failed: {e}");
                // Progress state is already set to Failed by download_model
            }
        });

        Ok(())
    }

    /// Cancel an in-progress download.
    pub fn cancel_download(&self) {
        self.download_cancel.store(true, Ordering::Relaxed);
    }

    /// Get current download progress. Poll this from Swift on a timer.
    pub fn get_download_progress(&self) -> DownloadProgress {
        self.download_progress.lock().unwrap().clone()
    }

    /// Delete a downloaded model's files.
    pub fn delete_model(&self, model_id: String) -> Result<(), CoreError> {
        let model_path = models::model_path(&self.models_dir, &model_id);

        if !model_path.exists() {
            return Ok(());
        }

        // Unload if this model is currently active
        {
            let config_guard = self.config.lock().map_err(|e| {
                CoreError::ConfigError(format!("Config lock poisoned: {e}"))
            })?;
            if config_guard.stt.active_model.as_deref() == Some(&model_id) {
                drop(config_guard);
                self.unload_model();
            }
        }

        std::fs::remove_dir_all(&model_path).map_err(|e| {
            CoreError::IoError(format!("Failed to delete model {model_id}: {e}"))
        })?;

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
