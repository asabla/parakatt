/// Core engine that orchestrates the full pipeline:
/// audio → preprocessing → STT → dictionary → LLM → result.
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use crate::config::Config;
use crate::dictionary::Dictionary;
use crate::download::{DownloadProgress, DownloadState};
use crate::llm::{LlmProvider, LlmRequest};
use crate::local_agreement::{LocalAgreement2, Token};
use crate::models;
use crate::modes;
use crate::session::{ChunkResult, SessionManager};
use crate::storage::{Storage, StoredTranscription, TranscriptionQuery};
use crate::stt::nemotron::NemotronProvider;
use crate::stt::parakeet::ParakeetProvider;
use crate::stt::streaming::{StreamingProvider, StreamingSession};
use crate::stt::SttProvider;
use crate::{
    AppContext, CoreError, EngineConfig, HotkeyConfig, ModeConfig, ModelInfo, ReplacementRule,
    StreamingChunkResult, TimestampedSegment, TranscriptionResult,
};

/// Per-session bundle: the underlying streaming model state PLUS
/// the LocalAgreement-2 commit policy that converts the model's
/// flickering hypotheses into committed + tentative text. This
/// keeps the LA-2 state co-located with the streaming session so
/// resetting one resets the other automatically.
struct StreamingPreviewSession {
    inner: Box<dyn StreamingSession>,
    la2: LocalAgreement2,
}

/// The main engine exposed to Swift via UniFFI.
///
/// ## Lock ordering
///
/// When acquiring multiple Mutexes, always follow this order to prevent deadlocks:
///   1. `config`
///   2. `stt`
///   3. `streaming`
///   4. `streaming_sessions`
///   5. `llm`
///   6. `dictionary`
///   7. `sessions`
///   8. `storage`
///   9. `download_progress`
///
/// Drop locks as soon as possible — especially before network I/O (e.g., `llm`).
#[derive(uniffi::Object)]
pub struct Engine {
    models_dir: PathBuf,
    config_dir: PathBuf,
    config: Mutex<Config>,
    /// Offline / commit-path STT (currently Parakeet TDT v3).
    stt: Mutex<Option<Box<dyn SttProvider>>>,
    /// Cache-aware streaming STT used for the live preview path
    /// (currently Nemotron). Independent of `stt` — both can be
    /// loaded at the same time, neither is required.
    streaming: Mutex<Option<Box<dyn StreamingProvider>>>,
    /// Active streaming sessions keyed by Swift-supplied session id.
    /// Each session owns its own per-recording cache state plus a
    /// LocalAgreement-2 commit policy.
    streaming_sessions: Mutex<std::collections::HashMap<String, StreamingPreviewSession>>,
    /// Per-session LocalAgreement-2 buffers for the **buffered**
    /// preview path (used when Nemotron isn't installed). The
    /// buffered path re-runs Parakeet TDT on a growing audio tail
    /// every few hundred milliseconds; LA-2 here is what suppresses
    /// the flicker that would otherwise show in the UI.
    buffered_preview_la2: Mutex<std::collections::HashMap<String, LocalAgreement2>>,
    llm: Mutex<Option<Arc<dyn LlmProvider>>>,
    dictionary: Mutex<Dictionary>,
    download_progress: Arc<Mutex<DownloadProgress>>,
    download_cancel: Arc<AtomicBool>,
    sessions: Mutex<SessionManager>,
    storage: Mutex<Storage>,
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
            config_dir: config_dir.clone(),
            config: Mutex::new(config),
            stt: Mutex::new(None),
            streaming: Mutex::new(None),
            streaming_sessions: Mutex::new(std::collections::HashMap::new()),
            buffered_preview_la2: Mutex::new(std::collections::HashMap::new()),
            llm: Mutex::new(None),
            dictionary: Mutex::new(dictionary),
            download_progress: Arc::new(Mutex::new(DownloadProgress::idle())),
            download_cancel: Arc::new(AtomicBool::new(false)),
            sessions: Mutex::new(SessionManager::new()),
            storage: Mutex::new(Storage::open(&config_dir)?),
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
        // 1. Preprocess audio (validate sample rate, trim leading/trailing silence)
        let processed = crate::audio::preprocess(&audio_samples, sample_rate)?;
        let leading_trim_secs = processed.leading_trim_secs;

        // 2. Run STT
        let stt_guard = self
            .stt
            .lock()
            .map_err(|e| CoreError::TranscriptionFailed(format!("STT lock poisoned: {e}")))?;

        let stt = stt_guard
            .as_ref()
            .ok_or_else(|| CoreError::TranscriptionFailed("No STT model loaded".into()))?;

        let mut result = stt.transcribe(&processed.samples, sample_rate)?;

        // Shift segment timestamps so they reference the start of the
        // *original* (un-trimmed) buffer rather than the trimmed waveform
        // we actually fed into the model.
        if leading_trim_secs > 0.0 {
            for seg in result.segments.iter_mut() {
                seg.start_secs += leading_trim_secs;
                seg.end_secs += leading_trim_secs;
            }
        }

        // 3. Remove filler words (uh, um, mmm, etc.)
        result.text = crate::filler::remove_fillers(&result.text);

        // 4. Apply dictionary replacements
        let ctx = context.unwrap_or_default();
        let dict_guard = self.dictionary.lock().map_err(|e| {
            CoreError::TranscriptionFailed(format!("Dictionary lock poisoned: {e}"))
        })?;
        result.text = dict_guard.apply(&result.text, &ctx, &mode);
        drop(dict_guard);

        // 4. LLM post-processing (if mode has a system prompt and LLM is configured)
        result.llm_error = self.apply_llm(&mut result.text, &mode, &ctx)?;

        // Auto-save to history.
        self.auto_save_transcription(&result, "push_to_talk", &mode, "mic", &ctx);

        Ok(result)
    }

    /// Load an STT model by ID.
    ///
    /// Routes to the right provider type based on the model id:
    ///   - `parakeet-*` → offline TDT, sets `self.stt`
    ///   - `nemotron-*` → cache-aware streaming, sets `self.streaming`
    ///
    /// Both can be loaded simultaneously — the engine uses `stt` for
    /// the commit path and `streaming` for the live preview path.
    pub fn load_model(&self, model_id: &str) -> Result<(), CoreError> {
        let model_path = models::model_path(&self.models_dir, model_id);

        if model_id.starts_with("nemotron-") {
            let provider = NemotronProvider::new(&model_path, model_id)?;
            let mut streaming_guard = self
                .streaming
                .lock()
                .map_err(|e| CoreError::ModelLoadFailed(format!("Streaming lock poisoned: {e}")))?;
            *streaming_guard = Some(Box::new(provider));
            log::info!("Streaming provider registered: {}", model_id);
            return Ok(());
        }

        // model_path is a directory for Parakeet models
        let provider: Box<dyn SttProvider> = if model_id.starts_with("parakeet-") {
            Box::new(ParakeetProvider::load(&model_path, model_id)?)
        } else {
            return Err(CoreError::ModelNotFound(format!(
                "Unknown model type: {model_id}"
            )));
        };

        let mut stt_guard = self
            .stt
            .lock()
            .map_err(|e| CoreError::ModelLoadFailed(format!("STT lock poisoned: {e}")))?;
        *stt_guard = Some(provider);

        // Update config
        let mut config_guard = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
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

    /// Whether a cache-aware streaming model (e.g. Nemotron) is
    /// loaded. The Swift side uses this to decide whether to spawn
    /// the live-preview worker thread. Independent of the user's
    /// streaming-preview opt-in flag — call
    /// [`should_use_streaming_preview`] for the combined check.
    pub fn is_streaming_model_loaded(&self) -> bool {
        self.streaming
            .lock()
            .map(|g| g.as_ref().is_some_and(|p| p.is_loaded()) || g.is_some())
            .unwrap_or(false)
    }

    /// Combined check: streaming model is loaded AND the user has
    /// opted into the streaming preview path. The Swift side uses
    /// this to decide whether to call `start_streaming_session` for
    /// each PTT recording.
    pub fn should_use_streaming_preview(&self) -> bool {
        if !self.is_streaming_model_loaded() {
            return false;
        }
        self.config
            .lock()
            .map(|c| c.general.streaming_preview_enabled)
            .unwrap_or(true)
    }

    /// Native chunk size in samples for the loaded streaming model,
    /// or 0 if no streaming model is loaded.
    pub fn streaming_native_chunk_samples(&self) -> u32 {
        self.streaming
            .lock()
            .map(|g| {
                g.as_ref()
                    .map(|p| p.native_chunk_samples() as u32)
                    .unwrap_or(0)
            })
            .unwrap_or(0)
    }

    // ----- Streaming session API (live preview path) -----

    /// Open a new streaming preview session for the given session id.
    /// Caller should pair this with [`finish_streaming_session`] or
    /// [`cancel_streaming_session`] to release model state.
    pub fn start_streaming_session(&self, session_id: String) -> Result<(), CoreError> {
        let streaming_guard = self
            .streaming
            .lock()
            .map_err(|e| CoreError::TranscriptionFailed(format!("Streaming lock poisoned: {e}")))?;
        let provider = streaming_guard
            .as_ref()
            .ok_or_else(|| CoreError::TranscriptionFailed("No streaming model loaded".into()))?;
        let session = provider.start_session()?;
        drop(streaming_guard);

        let mut sessions_guard = self.streaming_sessions.lock().map_err(|e| {
            CoreError::TranscriptionFailed(format!("Streaming sessions lock poisoned: {e}"))
        })?;
        if sessions_guard.contains_key(&session_id) {
            return Err(CoreError::TranscriptionFailed(format!(
                "Streaming session already exists: {session_id}"
            )));
        }
        sessions_guard.insert(
            session_id,
            StreamingPreviewSession {
                inner: session,
                la2: LocalAgreement2::new(),
            },
        );
        Ok(())
    }

    /// Feed a chunk of 16 kHz mono audio to a streaming session.
    ///
    /// The Rust side runs LocalAgreement-2 internally so the Swift
    /// caller gets pre-baked committed/tentative slices and doesn't
    /// have to re-implement LA-2.
    pub fn feed_streaming_chunk(
        &self,
        session_id: String,
        audio_samples: Vec<f32>,
    ) -> Result<StreamingChunkResult, CoreError> {
        let mut sessions_guard = self.streaming_sessions.lock().map_err(|e| {
            CoreError::TranscriptionFailed(format!("Streaming sessions lock poisoned: {e}"))
        })?;
        let session = sessions_guard.get_mut(&session_id).ok_or_else(|| {
            CoreError::TranscriptionFailed(format!("Streaming session not found: {session_id}"))
        })?;
        session.inner.feed_chunk(&audio_samples)?;

        // Tokenize the model's running transcript on whitespace and
        // hand it to LA-2 as a fresh hypothesis. We don't have
        // per-token timing from the streaming model — that's fine,
        // LA-2's commit policy works on text-only tokens.
        let full = session.inner.current_transcript();
        let hypothesis: Vec<Token> = full
            .split_whitespace()
            .map(|w| Token {
                text: w.to_string(),
                start_secs: 0.0,
                end_secs: 0.0,
            })
            .collect();
        let agreement = session.la2.update(hypothesis);

        let newly_committed_text = agreement
            .newly_committed
            .iter()
            .map(|t| t.text.as_str())
            .collect::<Vec<_>>()
            .join(" ");
        let tentative_text = agreement
            .tentative
            .iter()
            .map(|t| t.text.as_str())
            .collect::<Vec<_>>()
            .join(" ");

        Ok(StreamingChunkResult {
            committed_text: session.la2.committed_text().to_string(),
            tentative_text,
            newly_committed_text,
        })
    }

    /// Reset a streaming session in place (new utterance, same handle).
    /// Both the model state AND the LocalAgreement-2 buffer are reset.
    pub fn reset_streaming_session(&self, session_id: String) -> Result<(), CoreError> {
        let mut sessions_guard = self.streaming_sessions.lock().map_err(|e| {
            CoreError::TranscriptionFailed(format!("Streaming sessions lock poisoned: {e}"))
        })?;
        let session = sessions_guard.get_mut(&session_id).ok_or_else(|| {
            CoreError::TranscriptionFailed(format!("Streaming session not found: {session_id}"))
        })?;
        session.inner.reset();
        session.la2.reset();
        Ok(())
    }

    /// Close and discard a streaming session, returning the final
    /// committed transcript (LocalAgreement-2 stable prefix).
    pub fn finish_streaming_session(&self, session_id: String) -> Result<String, CoreError> {
        let mut sessions_guard = self.streaming_sessions.lock().map_err(|e| {
            CoreError::TranscriptionFailed(format!("Streaming sessions lock poisoned: {e}"))
        })?;
        let session = sessions_guard.remove(&session_id).ok_or_else(|| {
            CoreError::TranscriptionFailed(format!("Streaming session not found: {session_id}"))
        })?;
        // On finish we accept the model's full running transcript as
        // the final answer (everything that was tentative now becomes
        // canonical, since there will be no more passes).
        let full = session.inner.current_transcript();
        Ok(if full.is_empty() {
            session.la2.committed_text().to_string()
        } else {
            full
        })
    }

    /// Cancel a streaming session without returning text.
    pub fn cancel_streaming_session(&self, session_id: String) {
        if let Ok(mut g) = self.streaming_sessions.lock() {
            g.remove(&session_id);
        }
    }

    // ----- Buffered preview API (fallback when Nemotron is absent) -----
    //
    // The Swift side uses these when the streaming model isn't loaded.
    // Each preview pass runs Parakeet TDT on the current audio tail
    // and pipes the result through LocalAgreement-2 so the user sees
    // committed/tentative slices instead of a flickering raw transcript.

    /// Open a buffered preview session for the given id. Pair with
    /// [`buffered_preview_finish`] or [`buffered_preview_cancel`].
    pub fn buffered_preview_start(&self, session_id: String) -> Result<(), CoreError> {
        let mut g = self.buffered_preview_la2.lock().map_err(|e| {
            CoreError::TranscriptionFailed(format!("Buffered preview lock poisoned: {e}"))
        })?;
        if g.contains_key(&session_id) {
            return Err(CoreError::TranscriptionFailed(format!(
                "Buffered preview session already exists: {session_id}"
            )));
        }
        g.insert(session_id, LocalAgreement2::new());
        Ok(())
    }

    /// Run one preview pass: transcribe the audio with the loaded
    /// commit-path STT model, fold the result into the session's
    /// LocalAgreement-2 state, and return the committed/tentative
    /// slices. NO dictionary or LLM is applied — this is a raw
    /// preview, not a commit.
    pub fn buffered_preview_update(
        &self,
        session_id: String,
        audio_samples: Vec<f32>,
        sample_rate: u32,
    ) -> Result<StreamingChunkResult, CoreError> {
        // 1. Preprocess + run Parakeet on the audio.
        let processed = crate::audio::preprocess(&audio_samples, sample_rate)?;
        let leading_trim_secs = processed.leading_trim_secs;

        let stt_guard = self
            .stt
            .lock()
            .map_err(|e| CoreError::TranscriptionFailed(format!("STT lock poisoned: {e}")))?;
        let stt = stt_guard
            .as_ref()
            .ok_or_else(|| CoreError::TranscriptionFailed("No STT model loaded".into()))?;
        let mut result = stt.transcribe(&processed.samples, sample_rate)?;
        drop(stt_guard);

        // Shift segment timestamps so they refer to the original
        // (un-trimmed) chunk's time base. Important if the caller
        // ever inspects them.
        if leading_trim_secs > 0.0 {
            for seg in result.segments.iter_mut() {
                seg.start_secs += leading_trim_secs;
                seg.end_secs += leading_trim_secs;
            }
        }

        // 2. Tokenize the transcript text on whitespace and feed
        // to LA-2. We use whitespace tokens because the buffered
        // path doesn't have token-level alignment (Parakeet TDT
        // gives us sentence-level segments, but LA-2's job is
        // word-level).
        let hypothesis: Vec<Token> = result
            .text
            .split_whitespace()
            .map(|w| Token {
                text: w.to_string(),
                start_secs: 0.0,
                end_secs: 0.0,
            })
            .collect();

        let mut g = self.buffered_preview_la2.lock().map_err(|e| {
            CoreError::TranscriptionFailed(format!("Buffered preview lock poisoned: {e}"))
        })?;
        let la2 = g.get_mut(&session_id).ok_or_else(|| {
            CoreError::TranscriptionFailed(format!(
                "Buffered preview session not found: {session_id}"
            ))
        })?;
        let agreement = la2.update(hypothesis);

        let newly_committed_text = agreement
            .newly_committed
            .iter()
            .map(|t| t.text.as_str())
            .collect::<Vec<_>>()
            .join(" ");
        let tentative_text = agreement
            .tentative
            .iter()
            .map(|t| t.text.as_str())
            .collect::<Vec<_>>()
            .join(" ");
        let committed_text = la2.committed_text().to_string();

        Ok(StreamingChunkResult {
            committed_text,
            tentative_text,
            newly_committed_text,
        })
    }

    /// Close a buffered preview session and return the committed
    /// text. The caller is then responsible for any final commit
    /// pass via the regular session API.
    pub fn buffered_preview_finish(&self, session_id: String) -> Result<String, CoreError> {
        let mut g = self.buffered_preview_la2.lock().map_err(|e| {
            CoreError::TranscriptionFailed(format!("Buffered preview lock poisoned: {e}"))
        })?;
        let la2 = g.remove(&session_id).ok_or_else(|| {
            CoreError::TranscriptionFailed(format!(
                "Buffered preview session not found: {session_id}"
            ))
        })?;
        Ok(la2.committed_text().to_string())
    }

    /// Reset a buffered preview session in place (clears LA-2 buffer).
    pub fn buffered_preview_reset(&self, session_id: String) -> Result<(), CoreError> {
        let mut g = self.buffered_preview_la2.lock().map_err(|e| {
            CoreError::TranscriptionFailed(format!("Buffered preview lock poisoned: {e}"))
        })?;
        let la2 = g.get_mut(&session_id).ok_or_else(|| {
            CoreError::TranscriptionFailed(format!(
                "Buffered preview session not found: {session_id}"
            ))
        })?;
        la2.reset();
        Ok(())
    }

    /// Cancel a buffered preview session without returning text.
    pub fn buffered_preview_cancel(&self, session_id: String) {
        if let Ok(mut g) = self.buffered_preview_la2.lock() {
            g.remove(&session_id);
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

    /// Save a custom mode (add or update by name). Built-in modes are preserved.
    pub fn save_mode(&self, mode: ModeConfig) -> Result<(), CoreError> {
        let mut cfg = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;

        // Initialize from defaults if modes list is empty
        if cfg.modes.is_empty() {
            cfg.modes = modes::default_modes();
        }

        // Update existing or add new
        if let Some(existing) = cfg.modes.iter_mut().find(|m| m.name == mode.name) {
            *existing = mode;
        } else {
            cfg.modes.push(mode);
        }

        cfg.save(&self.config_dir)
    }

    /// Delete a custom mode by name. Built-in modes (dictation, clean, email, code) cannot be deleted.
    pub fn delete_mode(&self, name: String) -> Result<(), CoreError> {
        let builtin = ["dictation", "clean", "email", "code"];
        if builtin.contains(&name.to_lowercase().as_str()) {
            return Err(CoreError::ConfigError(format!(
                "Cannot delete built-in mode: {name}"
            )));
        }

        let mut cfg = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;

        if cfg.modes.is_empty() {
            cfg.modes = modes::default_modes();
        }

        cfg.modes.retain(|m| m.name != name);
        cfg.save(&self.config_dir)
    }

    /// Get per-app mode defaults as a list of [bundle_id, mode_name] pairs.
    pub fn get_app_mode_defaults(&self) -> Result<Vec<Vec<String>>, CoreError> {
        let config = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
        Ok(config
            .general
            .app_mode_defaults
            .iter()
            .map(|(k, v)| vec![k.clone(), v.clone()])
            .collect())
    }

    /// Set a per-app mode default. Pass empty mode to remove.
    pub fn set_app_mode_default(&self, bundle_id: String, mode: String) -> Result<(), CoreError> {
        let mut cfg = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
        if mode.is_empty() {
            cfg.general.app_mode_defaults.remove(&bundle_id);
        } else {
            cfg.general.app_mode_defaults.insert(bundle_id, mode);
        }
        cfg.save(&self.config_dir)
    }

    /// Resolve which mode to use given an app context.
    /// Returns the per-app default if one exists, otherwise the active mode.
    pub fn resolve_mode_for_app(&self, bundle_id: Option<String>) -> Result<String, CoreError> {
        let config = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
        if let Some(bid) = &bundle_id {
            if let Some(mode) = config.general.app_mode_defaults.get(bid) {
                return Ok(mode.clone());
            }
        }
        Ok(config.general.active_mode.clone())
    }

    /// Update the dictionary rules.
    pub fn set_dictionary_rules(&self, rules: Vec<ReplacementRule>) -> Result<(), CoreError> {
        let mut dict_guard = self
            .dictionary
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Dictionary lock poisoned: {e}")))?;
        dict_guard.set_rules(rules.clone());

        // Persist to config
        let mut config_guard = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
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

    // --- Profile management ---

    /// List available profile names.
    pub fn list_profiles(&self) -> Vec<String> {
        Config::list_profiles(&self.config_dir)
    }

    /// Save the current config as a named profile.
    pub fn save_profile(&self, name: String) -> Result<(), CoreError> {
        let config = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
        config.save_profile(&self.config_dir, &name)
    }

    /// Load a named profile, replacing the current config and reconfiguring the engine.
    pub fn load_profile(&self, name: String) -> Result<(), CoreError> {
        let new_config = Config::load_profile(&self.config_dir, &name)?;

        // Update dictionary
        {
            let mut dict_guard = self
                .dictionary
                .lock()
                .map_err(|e| CoreError::ConfigError(format!("Dictionary lock poisoned: {e}")))?;
            dict_guard.set_rules(new_config.dictionary.clone());
        }

        // Save as active config and update state
        new_config.save(&self.config_dir)?;
        let mut cfg = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
        *cfg = new_config;

        log::info!("Loaded profile: {name}");
        Ok(())
    }

    /// Delete a named profile.
    pub fn delete_profile(&self, name: String) -> Result<(), CoreError> {
        Config::delete_profile(&self.config_dir, &name)
    }

    /// Validate a dictionary pattern without saving it.
    /// Returns an error message if the pattern is invalid, or empty string if valid.
    pub fn validate_dictionary_pattern(&self, pattern: String) -> String {
        if pattern.len() > 500 {
            return format!("Pattern too long ({} chars, max 500)", pattern.len());
        }
        let regex_str = if let Some(raw) = pattern.strip_prefix("re:") {
            raw.to_string()
        } else {
            format!(r"(?i)\b{}\b", regex::escape(&pattern))
        };
        match regex::Regex::new(&regex_str) {
            Ok(_) => String::new(),
            Err(e) => format!("Invalid regex: {e}"),
        }
    }

    /// Get current hotkey configuration.
    pub fn get_hotkey_config(&self) -> Result<HotkeyConfig, CoreError> {
        let config = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
        Ok(HotkeyConfig {
            key: config.general.hotkey_key.clone(),
            modifiers: config.general.hotkey_modifiers.clone(),
            mode: config.general.hotkey_mode.clone(),
        })
    }

    /// Set and persist hotkey configuration.
    pub fn set_hotkey_config(&self, config: HotkeyConfig) -> Result<(), CoreError> {
        let mut cfg = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
        cfg.general.hotkey_key = config.key;
        cfg.general.hotkey_modifiers = config.modifiers;
        cfg.general.hotkey_mode = config.mode;
        cfg.save(&self.config_dir)
    }

    /// Get whether auto-paste is enabled.
    pub fn get_auto_paste(&self) -> Result<bool, CoreError> {
        let config = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
        Ok(config.general.auto_paste)
    }

    /// Set and persist auto-paste setting.
    pub fn set_auto_paste(&self, enabled: bool) -> Result<(), CoreError> {
        let mut cfg = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
        cfg.general.auto_paste = enabled;
        cfg.save(&self.config_dir)
    }

    /// Get whether the recording overlay is shown.
    pub fn get_show_overlay(&self) -> Result<bool, CoreError> {
        let config = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
        Ok(config.general.show_overlay)
    }

    /// Set and persist the recording overlay setting.
    pub fn set_show_overlay(&self, enabled: bool) -> Result<(), CoreError> {
        let mut cfg = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
        cfg.general.show_overlay = enabled;
        cfg.save(&self.config_dir)
    }

    /// Get whether the cache-aware streaming live preview is enabled.
    pub fn get_streaming_preview_enabled(&self) -> Result<bool, CoreError> {
        let config = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
        Ok(config.general.streaming_preview_enabled)
    }

    /// Set and persist the streaming-preview opt-in flag.
    pub fn set_streaming_preview_enabled(&self, enabled: bool) -> Result<(), CoreError> {
        let mut cfg = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
        cfg.general.streaming_preview_enabled = enabled;
        cfg.save(&self.config_dir)
    }

    /// Get the preferred audio source bundle ID for meeting capture.
    pub fn get_preferred_audio_source(&self) -> Result<Option<String>, CoreError> {
        let config = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
        Ok(config.general.preferred_audio_source_bundle_id.clone())
    }

    /// Set and persist the preferred audio source bundle ID.
    pub fn set_preferred_audio_source(&self, bundle_id: Option<String>) -> Result<(), CoreError> {
        let mut cfg = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
        cfg.general.preferred_audio_source_bundle_id = bundle_id;
        cfg.save(&self.config_dir)
    }

    /// Get the chunk duration in seconds for meeting transcription.
    pub fn get_chunk_duration(&self) -> Result<u32, CoreError> {
        let config = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
        Ok(config.general.chunk_duration_secs)
    }

    /// Set and persist the chunk duration in seconds (10-120).
    pub fn set_chunk_duration(&self, secs: u32) -> Result<(), CoreError> {
        let clamped = secs.clamp(10, 120);
        let mut cfg = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
        cfg.general.chunk_duration_secs = clamped;
        cfg.save(&self.config_dir)
    }

    /// Get the maximum word count for LLM processing.
    pub fn get_llm_max_words(&self) -> Result<u32, CoreError> {
        let config = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
        Ok(config.general.llm_max_words)
    }

    /// Set and persist the maximum word count for LLM processing (500-10000).
    pub fn set_llm_max_words(&self, words: u32) -> Result<(), CoreError> {
        let clamped = words.clamp(500, 10000);
        let mut cfg = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
        cfg.general.llm_max_words = clamped;
        cfg.save(&self.config_dir)
    }

    /// Get whether debug mode is enabled.
    pub fn get_debug_mode(&self) -> Result<bool, CoreError> {
        let config = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
        Ok(config.general.debug_mode)
    }

    /// Set and persist debug mode.
    pub fn set_debug_mode(&self, enabled: bool) -> Result<(), CoreError> {
        let mut cfg = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
        cfg.general.debug_mode = enabled;
        cfg.save(&self.config_dir)
    }

    /// Get the retention period in days (0 = disabled).
    pub fn get_retention_days(&self) -> Result<u32, CoreError> {
        let config = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
        Ok(config.general.retention_days)
    }

    /// Set and persist the retention period in days (0 = disabled).
    pub fn set_retention_days(&self, days: u32) -> Result<(), CoreError> {
        let mut cfg = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
        cfg.general.retention_days = days;
        cfg.save(&self.config_dir)
    }

    /// Run retention cleanup: delete transcriptions older than the configured period.
    /// Returns the number of deleted transcriptions, or 0 if retention is disabled.
    pub fn run_retention_cleanup(&self) -> Result<u32, CoreError> {
        let days = {
            let config = self
                .config
                .lock()
                .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
            config.general.retention_days
        };

        if days == 0 {
            return Ok(0);
        }

        let storage = self
            .storage
            .lock()
            .map_err(|e| CoreError::IoError(format!("Storage lock poisoned: {e}")))?;
        let count = storage.delete_older_than(days)?;
        if count > 0 {
            log::info!(
                "Retention cleanup: deleted {} transcriptions older than {} days",
                count,
                days
            );
        }
        Ok(count)
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
        let llm: Option<Arc<dyn LlmProvider>> = match provider.as_str() {
            "ollama" => Some(Arc::new(crate::llm::ollama::OllamaProvider::new(
                &base_url, &model,
            ))),
            "lmstudio" => Some(Arc::new(
                crate::llm::openai::OpenAiCompatibleProvider::lmstudio(&base_url, &model),
            )),
            "openai" => {
                let key = api_key
                    .clone()
                    .ok_or_else(|| CoreError::ConfigError("OpenAI requires an API key".into()))?;
                Some(Arc::new(
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
        let mut llm_guard = self
            .llm
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("LLM lock poisoned: {e}")))?;
        *llm_guard = llm;

        // Persist to config
        let mut config_guard = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
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
                let resp = client.get(format!("{url}/api/tags")).send().map_err(|e| {
                    CoreError::LlmError(format!("Cannot reach Ollama at {url}: {e}"))
                })?;

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

                let resp = req.send().map_err(|e| {
                    CoreError::LlmError(format!("Cannot reach {provider} at {url}: {e}"))
                })?;

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

    /// Test the currently configured LLM connection. Returns the provider name
    /// on success or an error message on failure.
    pub fn test_llm_connection(&self) -> Result<String, CoreError> {
        let llm_guard = self
            .llm
            .lock()
            .map_err(|e| CoreError::LlmError(format!("LLM lock poisoned: {e}")))?;
        let llm = llm_guard
            .as_ref()
            .ok_or_else(|| CoreError::LlmError("No LLM provider configured".into()))?;

        if llm.is_available() {
            Ok(format!("{} is reachable", llm.name()))
        } else {
            Err(CoreError::LlmError(format!(
                "Cannot reach {} — check that the server is running",
                llm.name()
            )))
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
            let p = self
                .download_progress
                .lock()
                .map_err(|e| CoreError::IoError(format!("Download progress lock poisoned: {e}")))?;
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
            if let Err(e) =
                crate::download::download_model(&models_dir, &model_id, progress.clone(), cancel)
            {
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
    pub fn get_download_progress(&self) -> Result<DownloadProgress, CoreError> {
        let p = self
            .download_progress
            .lock()
            .map_err(|e| CoreError::IoError(format!("Download progress lock poisoned: {e}")))?;
        Ok(p.clone())
    }

    /// Delete a downloaded model's files.
    pub fn delete_model(&self, model_id: String) -> Result<(), CoreError> {
        let model_path = models::model_path(&self.models_dir, &model_id);

        if !model_path.exists() {
            return Ok(());
        }

        // Unload if this model is currently active
        {
            let config_guard = self
                .config
                .lock()
                .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
            if config_guard.stt.active_model.as_deref() == Some(&model_id) {
                drop(config_guard);
                self.unload_model();
            }
        }

        std::fs::remove_dir_all(&model_path)
            .map_err(|e| CoreError::IoError(format!("Failed to delete model {model_id}: {e}")))?;

        Ok(())
    }

    // --- Session-based chunked transcription (for meetings / long-form audio) ---

    /// Start a new chunked transcription session.
    pub fn start_session(&self, session_id: String) -> Result<(), CoreError> {
        let mut mgr = self
            .sessions
            .lock()
            .map_err(|e| CoreError::TranscriptionFailed(format!("Session lock poisoned: {e}")))?;
        mgr.start(&session_id)
    }

    /// Process one audio chunk within a session.
    ///
    /// The audio is preprocessed, transcribed via STT, dictionary + LLM
    /// processed per-chunk, then stitched into the session's accumulated
    /// transcript with overlap deduplication.
    ///
    /// `chunk_overlap_secs` tells the dedup pipeline how many seconds
    /// at the start of `audio_samples` are a re-encoding of audio the
    /// previous chunk already covered. When > 0 the session uses
    /// time-based segment gating (NeMo middle-token merging style)
    /// instead of text matching. Pass 0 if the caller doesn't know.
    pub fn process_chunk(
        &self,
        session_id: String,
        audio_samples: Vec<f32>,
        sample_rate: u32,
        _chunk_index: u32,
        mode: String,
        context: Option<AppContext>,
    ) -> Result<ChunkResult, CoreError> {
        self.process_chunk_with_overlap(
            session_id,
            audio_samples,
            sample_rate,
            _chunk_index,
            0.0,
            mode,
            context,
        )
    }

    /// Variant of `process_chunk` that takes an explicit overlap
    /// region. See [`SessionManager::add_chunk_with_overlap`].
    /// (8 args is over clippy's default 7 limit; allowed because
    /// these all map directly to the FFI surface and bundling
    /// them into a struct would churn the Swift caller for no
    /// functional gain.)
    #[allow(clippy::too_many_arguments)]
    pub fn process_chunk_with_overlap(
        &self,
        session_id: String,
        audio_samples: Vec<f32>,
        sample_rate: u32,
        _chunk_index: u32,
        chunk_overlap_secs: f64,
        mode: String,
        context: Option<AppContext>,
    ) -> Result<ChunkResult, CoreError> {
        // Preprocess audio (validate sample rate, trim leading/trailing silence).
        // The full original chunk duration is what advances the session
        // timeline; the trimmed offset is how much we have to add back to
        // STT-returned timestamps so they refer to the chunk's real time
        // base instead of the trimmed buffer's time base.
        let chunk_duration_secs = audio_samples.len() as f64 / sample_rate as f64;
        let processed = crate::audio::preprocess(&audio_samples, sample_rate)?;
        let leading_trim_secs = processed.leading_trim_secs;

        // Run STT on this chunk.
        let stt_guard = self
            .stt
            .lock()
            .map_err(|e| CoreError::TranscriptionFailed(format!("STT lock poisoned: {e}")))?;
        let stt = stt_guard
            .as_ref()
            .ok_or_else(|| CoreError::TranscriptionFailed("No STT model loaded".into()))?;
        let mut stt_result = stt.transcribe(&processed.samples, sample_rate)?;
        drop(stt_guard);

        // Shift segment timestamps so they reference the start of the
        // *original* (un-trimmed) chunk, not the trimmed waveform that
        // was actually fed into the model.
        if leading_trim_secs > 0.0 {
            for seg in stt_result.segments.iter_mut() {
                seg.start_secs += leading_trim_secs;
                seg.end_secs += leading_trim_secs;
            }
        }

        // Remove filler words and apply dictionary replacements per-chunk.
        let ctx = context.unwrap_or_default();
        let mut chunk_text = crate::filler::remove_fillers(&stt_result.text);
        let dict_guard = self.dictionary.lock().map_err(|e| {
            CoreError::TranscriptionFailed(format!("Dictionary lock poisoned: {e}"))
        })?;
        chunk_text = dict_guard.apply(&chunk_text, &ctx, &mode);
        drop(dict_guard);

        // Apply LLM post-processing per-chunk to avoid accumulating
        // a huge transcript that overwhelms the LLM at session end.
        let llm_error = self.apply_llm(&mut chunk_text, &mode, &ctx)?;

        // Stitch into session with overlap dedup.
        let mut mgr = self
            .sessions
            .lock()
            .map_err(|e| CoreError::TranscriptionFailed(format!("Session lock poisoned: {e}")))?;
        let mut chunk_result = mgr.add_chunk_with_overlap(
            &session_id,
            &chunk_text,
            chunk_duration_secs,
            chunk_overlap_secs,
            stt_result.segments,
        )?;
        chunk_result.llm_error = llm_error;
        Ok(chunk_result)
    }

    /// Finish a session and return the final result.
    ///
    /// Dictionary and LLM processing are already applied per-chunk in
    /// `process_chunk()`, so this just extracts the accumulated text
    /// and persists the result.
    pub fn finish_session(
        &self,
        session_id: String,
        mode: String,
        context: Option<AppContext>,
        source: Option<String>,
    ) -> Result<TranscriptionResult, CoreError> {
        // Extract accumulated text, duration, and segments from the session.
        let mut mgr = self
            .sessions
            .lock()
            .map_err(|e| CoreError::TranscriptionFailed(format!("Session lock poisoned: {e}")))?;
        let (text, duration_secs, segments) = mgr.finish(&session_id)?;
        drop(mgr);

        let result = TranscriptionResult {
            text,
            duration_secs,
            provider_name: "parakeet".to_string(),
            segments,
            llm_error: None,
        };

        let ctx = context.unwrap_or_default();
        let src = source.as_deref().unwrap_or("meeting");
        let input = if src == "push_to_talk" {
            "mic"
        } else {
            "mixed"
        };
        self.auto_save_transcription(&result, src, &mode, input, &ctx);

        Ok(result)
    }

    /// Get the accumulated text for a session on demand, without the per-chunk
    /// cloning overhead of `ChunkResult.accumulated_text`.
    pub fn get_session_text(&self, session_id: String) -> Result<String, CoreError> {
        let mgr = self
            .sessions
            .lock()
            .map_err(|e| CoreError::TranscriptionFailed(format!("Session lock poisoned: {e}")))?;
        mgr.get_session_text(&session_id)
    }

    /// Cancel and discard a session.
    pub fn cancel_session(&self, session_id: String) {
        if let Ok(mut mgr) = self.sessions.lock() {
            mgr.cancel(&session_id);
        }
    }

    // --- Transcription history CRUD ---

    /// Save a transcription to history (for external callers).
    pub fn save_transcription(
        &self,
        transcription: StoredTranscription,
    ) -> Result<String, CoreError> {
        let storage = self
            .storage
            .lock()
            .map_err(|e| CoreError::IoError(format!("Storage lock poisoned: {e}")))?;
        storage.save(&transcription)
    }

    /// Get usage statistics as key-value pairs.
    pub fn get_statistics(&self) -> Result<Vec<Vec<String>>, CoreError> {
        let storage = self
            .storage
            .lock()
            .map_err(|e| CoreError::IoError(format!("Storage lock poisoned: {e}")))?;
        let stats = storage.get_statistics()?;
        Ok(stats.into_iter().map(|(k, v)| vec![k, v]).collect())
    }

    /// List transcriptions with optional filtering and search.
    pub fn list_transcriptions(
        &self,
        query: TranscriptionQuery,
    ) -> Result<Vec<StoredTranscription>, CoreError> {
        let storage = self
            .storage
            .lock()
            .map_err(|e| CoreError::IoError(format!("Storage lock poisoned: {e}")))?;
        storage.list(&query)
    }

    /// Search transcriptions using full-text search.
    pub fn search_transcriptions(
        &self,
        search_text: String,
    ) -> Result<Vec<StoredTranscription>, CoreError> {
        let query = TranscriptionQuery {
            search_text: Some(search_text),
            source_filter: None,
            limit: 50,
            offset: 0,
        };
        let storage = self
            .storage
            .lock()
            .map_err(|e| CoreError::IoError(format!("Storage lock poisoned: {e}")))?;
        storage.list(&query)
    }

    /// Get a single transcription by ID.
    pub fn get_transcription(&self, id: String) -> Result<StoredTranscription, CoreError> {
        let storage = self
            .storage
            .lock()
            .map_err(|e| CoreError::IoError(format!("Storage lock poisoned: {e}")))?;
        storage.get(&id)
    }

    /// Update the title of a transcription.
    pub fn update_transcription_title(&self, id: String, title: String) -> Result<(), CoreError> {
        let storage = self
            .storage
            .lock()
            .map_err(|e| CoreError::IoError(format!("Storage lock poisoned: {e}")))?;
        storage.update_title(&id, &title)
    }

    /// Delete a transcription from history.
    pub fn delete_transcription(&self, id: String) -> Result<(), CoreError> {
        let storage = self
            .storage
            .lock()
            .map_err(|e| CoreError::IoError(format!("Storage lock poisoned: {e}")))?;
        storage.delete(&id)
    }

    /// Delete multiple transcriptions by IDs. Returns the number deleted.
    pub fn delete_transcriptions(&self, ids: Vec<String>) -> Result<u32, CoreError> {
        let storage = self
            .storage
            .lock()
            .map_err(|e| CoreError::IoError(format!("Storage lock poisoned: {e}")))?;
        storage.delete_many(&ids)
    }

    /// Get timestamp segments for a transcription (for timeline display).
    pub fn get_transcription_segments(
        &self,
        id: String,
    ) -> Result<Vec<TimestampedSegment>, CoreError> {
        let storage = self
            .storage
            .lock()
            .map_err(|e| CoreError::IoError(format!("Storage lock poisoned: {e}")))?;
        storage.get_segments(&id)
    }

    /// Export (backup) the database to the given file path.
    pub fn export_database(&self, dest_path: String) -> Result<(), CoreError> {
        let db_path = self.config_dir.join("transcriptions.db");
        if !db_path.exists() {
            return Err(CoreError::IoError("Database file not found".into()));
        }
        // Checkpoint WAL to ensure all data is in the main file before copying.
        {
            let storage = self
                .storage
                .lock()
                .map_err(|e| CoreError::IoError(format!("Storage lock poisoned: {e}")))?;
            let _ = storage.checkpoint();
        }
        std::fs::copy(&db_path, &dest_path)
            .map_err(|e| CoreError::IoError(format!("Failed to export database: {e}")))?;
        log::info!("Database exported to {}", dest_path);
        Ok(())
    }

    /// Import (restore) a database from the given file path.
    /// Replaces the current database — existing data will be lost.
    pub fn import_database(&self, source_path: String) -> Result<(), CoreError> {
        let source = std::path::Path::new(&source_path);
        if !source.exists() {
            return Err(CoreError::IoError(format!(
                "Import file not found: {source_path}"
            )));
        }
        let db_path = self.config_dir.join("transcriptions.db");
        // Close current storage connection by replacing it.
        {
            let mut storage = self
                .storage
                .lock()
                .map_err(|e| CoreError::IoError(format!("Storage lock poisoned: {e}")))?;
            // Copy import file over the database
            std::fs::copy(source, &db_path)
                .map_err(|e| CoreError::IoError(format!("Failed to import database: {e}")))?;
            // Reopen the storage with the new database
            *storage = Storage::open(&self.config_dir)?;
        }
        log::info!("Database imported from {}", source_path);
        Ok(())
    }
}

impl Engine {
    /// Test / integration hook: install a streaming provider directly
    /// without going through `load_model`. Lets integration tests
    /// inject a `ScriptedStreamingProvider` (or any other
    /// `StreamingProvider`) to drive the streaming session pipeline
    /// deterministically. NOT exported via UniFFI — Rust-only API.
    pub fn install_streaming_provider(
        &self,
        provider: Box<dyn StreamingProvider>,
    ) -> Result<(), CoreError> {
        let mut g = self
            .streaming
            .lock()
            .map_err(|e| CoreError::ModelLoadFailed(format!("Streaming lock poisoned: {e}")))?;
        *g = Some(provider);
        Ok(())
    }

    /// Apply LLM post-processing to text if the mode has a system prompt and
    /// an LLM provider is configured. Includes a token guard to prevent
    /// sending excessively long text to the LLM.
    ///
    /// Returns:
    /// - `Ok(None)` on success, or when LLM is not configured / not needed.
    /// - `Ok(Some(msg))` if LLM was configured for this mode but all
    ///   retries failed; `text` is left unchanged so the caller can
    ///   surface the raw STT output to the user along with a warning.
    /// - `Err(_)` only for unrecoverable internal errors (poisoned locks).
    fn apply_llm(
        &self,
        text: &mut String,
        mode: &str,
        ctx: &AppContext,
    ) -> Result<Option<String>, CoreError> {
        if text.trim().is_empty() {
            return Ok(None);
        }

        let config_guard = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;
        let all_modes = if config_guard.modes.is_empty() {
            modes::default_modes()
        } else {
            config_guard.modes.clone()
        };
        let max_words = config_guard.general.llm_max_words as usize;
        drop(config_guard);

        let mode_config = match modes::find_mode(&all_modes, mode) {
            Some(m) => m,
            None => return Ok(None),
        };

        let base_prompt = match &mode_config.system_prompt {
            Some(p) => p.clone(),
            None => return Ok(None),
        };

        let llm = {
            let llm_guard = self
                .llm
                .lock()
                .map_err(|e| CoreError::LlmError(format!("LLM lock poisoned: {e}")))?;
            match llm_guard.as_ref() {
                Some(l) => Arc::clone(l),
                None => {
                    log::debug!(
                        "Mode '{}' has a system prompt but no LLM provider is configured",
                        mode
                    );
                    return Ok(None);
                }
            }
        };

        // Token guard: truncate excessively long text to avoid LLM timeouts.
        // Truncates at the last sentence boundary within the word limit
        // to avoid cutting mid-sentence.
        let word_count = text.split_whitespace().count();
        let llm_text = if word_count > max_words {
            log::warn!(
                "Text has {} words, truncating to ~{} for LLM processing",
                word_count,
                max_words
            );
            let rough_cut: String = text
                .split_whitespace()
                .take(max_words)
                .collect::<Vec<_>>()
                .join(" ");
            // Find the last sentence-ending punctuation to avoid mid-sentence cuts.
            if let Some(pos) = rough_cut.rfind(['.', '!', '?']) {
                rough_cut[..=pos].to_string()
            } else {
                rough_cut
            }
        } else {
            text.clone()
        };

        // Inject domain words into the system prompt.
        let dict_guard = self
            .dictionary
            .lock()
            .map_err(|e| CoreError::LlmError(format!("Dictionary lock poisoned: {e}")))?;
        let domain_words: Vec<String> = dict_guard
            .rules()
            .iter()
            .filter(|r| r.pattern == r.replacement && r.enabled)
            .map(|r| r.pattern.clone())
            .collect();
        drop(dict_guard);

        let mut system_prompt = base_prompt;
        if !domain_words.is_empty() {
            system_prompt.push_str(&format!(
                "\n\nDomain-specific vocabulary (use these exact spellings when the \
                 transcription contains similar-sounding words): {}",
                domain_words.join(", ")
            ));
        }

        let llm_request = LlmRequest {
            text: llm_text,
            system_prompt,
            context: Some(ctx.clone()),
        };

        // Retry only transient failures (timeout, connection) with backoff.
        // Non-transient errors (bad API key, model not found) fail immediately.
        let max_retries = 2;
        let mut last_error = None;
        for attempt in 0..=max_retries {
            match llm.process(&llm_request) {
                Ok(processed_text) => {
                    *text = processed_text;
                    last_error = None;
                    break;
                }
                Err(e) => {
                    let msg = e.to_string();
                    let is_transient = msg.contains("timed out")
                        || msg.contains("connect")
                        || msg.contains("Connection")
                        || msg.contains("stream");

                    if is_transient && attempt < max_retries {
                        let delay = std::time::Duration::from_millis(500 * (1 << attempt));
                        log::warn!(
                            "LLM attempt {} failed (transient), retrying in {}ms: {e}",
                            attempt + 1,
                            delay.as_millis()
                        );
                        last_error = Some(e);
                        std::thread::sleep(delay);
                    } else {
                        // Non-transient error or final attempt — don't retry
                        last_error = Some(e);
                        break;
                    }
                }
            }
        }
        if let Some(e) = last_error {
            log::warn!("LLM processing failed, using raw transcription: {e}");
            return Ok(Some(e.to_string()));
        }

        Ok(None)
    }

    /// Auto-save a transcription result to storage. Failures are logged, not propagated.
    fn auto_save_transcription(
        &self,
        result: &TranscriptionResult,
        source: &str,
        mode: &str,
        audio_source: &str,
        context: &AppContext,
    ) {
        if result.text.trim().is_empty() {
            return;
        }

        let now = chrono::Utc::now().to_rfc3339();
        let title = format!(
            "{} {}",
            if source == "meeting" {
                "Meeting"
            } else {
                "Note"
            },
            chrono::Utc::now().format("%Y-%m-%d %H:%M")
        );

        let app_context_json = serde_json::to_string(context).ok();

        let transcription = StoredTranscription {
            id: uuid::Uuid::new_v4().to_string(),
            created_at: now,
            duration_secs: result.duration_secs,
            source: source.to_string(),
            mode: mode.to_string(),
            audio_source: Some(audio_source.to_string()),
            app_context: app_context_json,
            title: Some(title),
            text: result.text.clone(),
        };

        if let Ok(storage) = self.storage.lock() {
            if let Err(e) = storage.save(&transcription) {
                log::warn!("Failed to auto-save transcription: {e}");
            } else {
                log::info!(
                    "Saved transcription '{}' with {} segments",
                    transcription.id,
                    result.segments.len()
                );
                if !result.segments.is_empty() {
                    if let Err(e) = storage.save_segments(&transcription.id, &result.segments, None)
                    {
                        log::warn!("Failed to save segments: {e}");
                    }
                }
            }
        }
    }

    /// Set up the LLM provider based on current config.
    fn setup_llm_provider(&self) -> Result<(), CoreError> {
        let config_guard = self
            .config
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("Config lock poisoned: {e}")))?;

        let provider: Option<Arc<dyn LlmProvider>> =
            match config_guard.llm.active_provider.as_deref() {
                Some("ollama") => Some(Arc::new(crate::llm::ollama::OllamaProvider::new(
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
                    Some(Arc::new(
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
                        Some(Arc::new(
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

        let mut llm_guard = self
            .llm
            .lock()
            .map_err(|e| CoreError::ConfigError(format!("LLM lock poisoned: {e}")))?;
        *llm_guard = provider;

        Ok(())
    }
}
