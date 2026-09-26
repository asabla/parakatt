mod history;

/// Core engine that orchestrates the full pipeline:
/// audio → preprocessing → STT → dictionary → LLM → result.
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
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
    AppContext, ChunkSource, CoreError, EngineConfig, HotkeyConfig, ModeConfig, ModelInfo,
    ReplacementRule, StreamingChunkResult, TimestampedSegment, TranscriptionResult,
};

/// Per-session bundle: the underlying streaming model state PLUS
/// the LocalAgreement-2 commit policy that converts the model's
/// flickering hypotheses into committed + tentative text. This
/// keeps the LA-2 state co-located with the streaming session so
/// resetting one resets the other automatically.
type ProcessingJob = (Arc<dyn LlmProvider>, LlmRequest);

struct StreamingPreviewSession {
    inner: Box<dyn StreamingSession>,
    la2: LocalAgreement2,
}

/// The main engine exposed to Swift via UniFFI.
///
/// ## Lock ordering
///
/// When acquiring multiple Mutexes, always follow this order to prevent
/// deadlocks. There is no compile-time enforcement — review every site
/// that takes more than one lock against this list:
///   1. `config`
///   2. `stt`
///   3. `streaming`
///   4. `streaming_sessions`
///   5. `buffered_preview_la2`
///   6. `llm`
///   7. `dictionary`
///   8. `sessions`
///   9. `storage`
///   10. `download_progress`
///
/// Drop locks as soon as possible — especially before network I/O
/// (e.g., `llm`). Scope guards with explicit blocks or `drop()` rather
/// than relying on end-of-function drop order.
///
/// Acquire every lock via [`crate::util::lock_named`] so that any
/// poison failure is logged with a consistent breadcrumb and mapped
/// to the appropriate `CoreError` variant.
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
    streaming_readiness: Mutex<crate::speech::ModelReadiness>,
    model_generation: AtomicU64,
    offline_generation: AtomicU64,
    model_lifecycle: Mutex<()>,
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
    capturing: Mutex<std::collections::HashSet<String>>,
    processing: Mutex<std::collections::HashMap<String, Arc<crate::processing::ProcessingSession>>>,
    completed_events:
        Mutex<std::collections::VecDeque<(String, Vec<crate::processing::TranscriptionEvent>)>>,
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
            streaming_readiness: Mutex::new(crate::speech::ModelReadiness::Unavailable),
            model_generation: AtomicU64::new(0),
            offline_generation: AtomicU64::new(0),
            model_lifecycle: Mutex::new(()),
            streaming_sessions: Mutex::new(std::collections::HashMap::new()),
            buffered_preview_la2: Mutex::new(std::collections::HashMap::new()),
            llm: Mutex::new(None),
            dictionary: Mutex::new(dictionary),
            download_progress: Arc::new(Mutex::new(DownloadProgress::idle())),
            download_cancel: Arc::new(AtomicBool::new(false)),
            sessions: Mutex::new(SessionManager::new()),
            capturing: Mutex::new(std::collections::HashSet::new()),
            processing: Mutex::new(std::collections::HashMap::new()),
            completed_events: Mutex::new(std::collections::VecDeque::new()),
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
        if sample_rate != crate::audio::TARGET_SAMPLE_RATE
            || audio_samples.iter().any(|v| !v.is_finite())
        {
            return Err(CoreError::AudioError(
                "Expected finite 16 kHz mono audio".into(),
            ));
        }
        if audio_samples.is_empty() || audio_samples.iter().all(|v| *v == 0.0) {
            return Err(CoreError::AudioError("Audio contains only silence".into()));
        }
        // Keep the synchronous API as an adapter to the same path Swift uses.
        // An energy threshold must not reject quiet speech before recognition.
        let provider_name = self
            .stt
            .lock()
            .unwrap()
            .as_ref()
            .ok_or_else(|| CoreError::TranscriptionFailed("No STT model loaded".into()))?
            .name()
            .to_string();
        let id = uuid::Uuid::new_v4().to_string();
        self.start_session(id.clone())?;
        let result = (|| {
            self.process_chunk(
                id.clone(),
                audio_samples,
                sample_rate,
                0,
                mode.clone(),
                context.clone(),
            )?;
            let mut result =
                self.finish_session(id.clone(), mode, context, Some("push_to_talk".into()))?;
            result.provider_name = provider_name;
            Ok(result)
        })();
        self.cancel_session(id);
        result
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
            let lifecycle = self.model_lifecycle.lock().unwrap();
            let generation = self.model_generation.fetch_add(1, Ordering::SeqCst) + 1;
            *self.streaming_readiness.lock().unwrap() = crate::speech::ModelReadiness::Loading;
            let settings = self.config.lock().unwrap().stt.settings.clone();
            drop(lifecycle);
            let loaded = (|| {
                let manifest = models::model_file_set(model_id)
                    .ok_or_else(|| CoreError::ModelNotFound(model_id.into()))?;
                models::verify_model(&model_path, manifest)?;
                NemotronProvider::load(
                    &model_path,
                    model_id,
                    settings.language,
                    settings.cpu_threads,
                )
            })();
            let _lifecycle = self.model_lifecycle.lock().unwrap();
            if generation != self.model_generation.load(Ordering::SeqCst) {
                return Err(CoreError::ModelLoadFailed(
                    "Model selection changed during loading".into(),
                ));
            }
            let provider = match loaded {
                Ok(provider) => provider,
                Err(error) => {
                    *self.streaming_readiness.lock().unwrap() =
                        crate::speech::ModelReadiness::Failed {
                            message: error.to_string(),
                        };
                    return Err(error);
                }
            };
            let mut streaming_guard =
                crate::util::lock_named(&self.streaming, "Streaming", CoreError::ModelLoadFailed)?;
            *streaming_guard = Some(Box::new(provider));
            *self.streaming_readiness.lock().unwrap() = crate::speech::ModelReadiness::Ready;
            log::info!("Streaming provider registered: {}", model_id);
            return Ok(());
        }

        let generation = {
            let _lifecycle = self.model_lifecycle.lock().unwrap();
            self.offline_generation.fetch_add(1, Ordering::SeqCst) + 1
        };
        // model_path is a directory for Parakeet models
        let provider: Box<dyn SttProvider> = if model_id.starts_with("parakeet-") {
            {
                let manifest = models::model_file_set(model_id)
                    .ok_or_else(|| CoreError::ModelNotFound(model_id.into()))?;
                models::verify_model(&model_path, manifest)?;
                let settings = self.get_speech_settings();
                Box::new(ParakeetProvider::load_with_backend(
                    &model_path,
                    model_id,
                    crate::speech::validated_backend(&settings),
                    settings.cpu_threads,
                    true,
                )?)
            }
        } else {
            return Err(CoreError::ModelNotFound(format!(
                "Unknown model type: {model_id}"
            )));
        };

        let _lifecycle = self.model_lifecycle.lock().unwrap();
        if generation != self.offline_generation.load(Ordering::SeqCst) {
            return Err(CoreError::ModelLoadFailed(
                "Model selection changed during loading".into(),
            ));
        }
        let mut stt_guard = crate::util::lock_named(&self.stt, "STT", CoreError::ModelLoadFailed)?;
        *stt_guard = Some(provider);
        drop(stt_guard);

        // Update config
        let mut config_guard =
            crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
        config_guard.stt.active_model = Some(model_id.to_string());
        if let Err(e) = config_guard.save(&self.config_dir) {
            log::warn!("Failed to persist active STT model to config: {e}");
        }

        Ok(())
    }

    pub fn get_speech_settings(&self) -> crate::speech::SpeechSettings {
        self.config.lock().unwrap().stt.settings.clone()
    }

    pub fn set_speech_settings(
        &self,
        settings: crate::speech::SpeechSettings,
    ) -> Result<(), CoreError> {
        settings.validate()?;
        let _lifecycle = self.model_lifecycle.lock().unwrap();
        if !self.streaming_sessions.lock().unwrap().is_empty() {
            return Err(CoreError::ConfigError(
                "Stop recording before changing speech settings".into(),
            ));
        }
        let mut config = self.config.lock().unwrap();
        let mut updated = config.clone();
        updated.stt.settings = settings;
        updated.save(&self.config_dir)?;
        *config = updated;
        drop(config);
        self.model_generation.fetch_add(1, Ordering::SeqCst);
        self.offline_generation.fetch_add(1, Ordering::SeqCst);
        *self.streaming.lock().unwrap() = None;
        *self.streaming_readiness.lock().unwrap() = crate::speech::ModelReadiness::Unavailable;
        Ok(())
    }

    pub fn speech_runtime_status(&self) -> crate::speech::SpeechRuntimeStatus {
        let settings = self.get_speech_settings();
        let actual_backend = self
            .stt
            .lock()
            .unwrap()
            .as_ref()
            .map(|p| p.backend())
            .unwrap_or(crate::speech::SpeechBackend::Cpu);
        crate::speech::SpeechRuntimeStatus {
            readiness: self.streaming_readiness.lock().unwrap().clone(),
            requested_backend: settings.backend,
            actual_backend,
            message: (settings.backend == crate::speech::SpeechBackend::WebGpu && actual_backend != crate::speech::SpeechBackend::WebGpu).then(|| {
                "WebGPU is unavailable or has not passed release validation on this system; using CPU".into()
            }),
        }
    }

    /// Unload the current STT model to free resources.
    pub fn unload_model(&self) {
        let _lifecycle = self.model_lifecycle.lock().unwrap();
        self.offline_generation.fetch_add(1, Ordering::SeqCst);
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
        if !matches!(
            *self.streaming_readiness.lock().unwrap(),
            crate::speech::ModelReadiness::Ready
        ) {
            return false;
        }
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
        let _lifecycle = self.model_lifecycle.lock().unwrap();
        let streaming_guard =
            crate::util::lock_named(&self.streaming, "Streaming", CoreError::TranscriptionFailed)?;
        let provider = streaming_guard
            .as_ref()
            .ok_or_else(|| CoreError::TranscriptionFailed("No streaming model loaded".into()))?;
        let session = provider.start_session()?;
        drop(streaming_guard);

        let mut sessions_guard = crate::util::lock_named(
            &self.streaming_sessions,
            "Streaming sessions",
            CoreError::TranscriptionFailed,
        )?;
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
        let mut sessions_guard = crate::util::lock_named(
            &self.streaming_sessions,
            "Streaming sessions",
            CoreError::TranscriptionFailed,
        )?;
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
        let mut sessions_guard = crate::util::lock_named(
            &self.streaming_sessions,
            "Streaming sessions",
            CoreError::TranscriptionFailed,
        )?;
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
        let mut sessions_guard = crate::util::lock_named(
            &self.streaming_sessions,
            "Streaming sessions",
            CoreError::TranscriptionFailed,
        )?;
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
        let mut g = crate::util::lock_named(
            &self.buffered_preview_la2,
            "Buffered preview",
            CoreError::TranscriptionFailed,
        )?;
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

        let stt_guard = crate::util::lock_named(&self.stt, "STT", CoreError::TranscriptionFailed)?;
        let stt = stt_guard
            .as_ref()
            .ok_or_else(|| CoreError::TranscriptionFailed("No STT model loaded".into()))?;
        let mut result = stt.transcribe(&processed.samples, sample_rate)?;
        drop(stt_guard);
        result.duration_secs = audio_samples.len() as f64 / sample_rate as f64;

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

        let mut g = crate::util::lock_named(
            &self.buffered_preview_la2,
            "Buffered preview",
            CoreError::TranscriptionFailed,
        )?;
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
        let mut g = crate::util::lock_named(
            &self.buffered_preview_la2,
            "Buffered preview",
            CoreError::TranscriptionFailed,
        )?;
        let la2 = g.remove(&session_id).ok_or_else(|| {
            CoreError::TranscriptionFailed(format!(
                "Buffered preview session not found: {session_id}"
            ))
        })?;
        Ok(la2.committed_text().to_string())
    }

    /// Reset a buffered preview session in place (clears LA-2 buffer).
    pub fn buffered_preview_reset(&self, session_id: String) -> Result<(), CoreError> {
        let mut g = crate::util::lock_named(
            &self.buffered_preview_la2,
            "Buffered preview",
            CoreError::TranscriptionFailed,
        )?;
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
        let mut cfg = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;

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

        let mut cfg = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;

        if cfg.modes.is_empty() {
            cfg.modes = modes::default_modes();
        }

        cfg.modes.retain(|m| m.name != name);
        cfg.save(&self.config_dir)
    }

    /// Get per-app mode defaults as a list of [bundle_id, mode_name] pairs.
    pub fn get_app_mode_defaults(&self) -> Result<Vec<Vec<String>>, CoreError> {
        let config = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
        Ok(config
            .general
            .app_mode_defaults
            .iter()
            .map(|(k, v)| vec![k.clone(), v.clone()])
            .collect())
    }

    /// Set a per-app mode default. Pass empty mode to remove.
    pub fn set_app_mode_default(&self, bundle_id: String, mode: String) -> Result<(), CoreError> {
        let mut cfg = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
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
        let config = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
        if let Some(bid) = &bundle_id {
            if let Some(mode) = config.general.app_mode_defaults.get(bid) {
                return Ok(mode.clone());
            }
        }
        Ok(config.general.active_mode.clone())
    }

    /// Update the dictionary rules.
    pub fn set_dictionary_rules(&self, rules: Vec<ReplacementRule>) -> Result<(), CoreError> {
        let mut dict_guard =
            crate::util::lock_named(&self.dictionary, "Dictionary", CoreError::ConfigError)?;
        dict_guard.set_rules(rules.clone());

        // Persist to config
        let mut config_guard =
            crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
        config_guard.dictionary = rules;
        if let Err(e) = config_guard.save(&self.config_dir) {
            log::warn!("Failed to persist dictionary rules to config: {e}");
        }

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
        let config = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
        config.save_profile(&self.config_dir, &name)
    }

    /// Load a named profile, replacing the current config and reconfiguring the engine.
    pub fn load_profile(&self, name: String) -> Result<(), CoreError> {
        let new_config = Config::load_profile(&self.config_dir, &name)?;
        new_config.stt.settings.validate()?;
        let _lifecycle = self.model_lifecycle.lock().unwrap();
        if !self.streaming_sessions.lock().unwrap().is_empty()
            || !self.processing.lock().unwrap().is_empty()
        {
            return Err(CoreError::ConfigError(
                "Stop recording and processing before loading a profile".into(),
            ));
        }
        new_config.save(&self.config_dir)?;
        self.dictionary
            .lock()
            .unwrap()
            .set_rules(new_config.dictionary.clone());
        *self.config.lock().unwrap() = new_config;
        *self.llm.lock().unwrap() = None;
        self.model_generation.fetch_add(1, Ordering::SeqCst);
        self.offline_generation.fetch_add(1, Ordering::SeqCst);
        *self.streaming.lock().unwrap() = None;
        *self.streaming_readiness.lock().unwrap() = crate::speech::ModelReadiness::Unavailable;
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
        let config = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
        Ok(HotkeyConfig {
            key: config.general.hotkey_key.clone(),
            modifiers: config.general.hotkey_modifiers.clone(),
            mode: config.general.hotkey_mode.clone(),
        })
    }

    /// Set and persist hotkey configuration.
    pub fn set_hotkey_config(&self, config: HotkeyConfig) -> Result<(), CoreError> {
        let mut cfg = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
        cfg.general.hotkey_key = config.key;
        cfg.general.hotkey_modifiers = config.modifiers;
        cfg.general.hotkey_mode = config.mode;
        cfg.save(&self.config_dir)
    }

    /// Get whether auto-paste is enabled.
    pub fn get_auto_paste(&self) -> Result<bool, CoreError> {
        let config = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
        Ok(config.general.auto_paste)
    }

    /// Set and persist auto-paste setting.
    pub fn set_auto_paste(&self, enabled: bool) -> Result<(), CoreError> {
        let mut cfg = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
        cfg.general.auto_paste = enabled;
        cfg.save(&self.config_dir)
    }

    /// Get whether the recording overlay is shown.
    pub fn get_show_overlay(&self) -> Result<bool, CoreError> {
        let config = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
        Ok(config.general.show_overlay)
    }

    /// Set and persist the recording overlay setting.
    pub fn set_show_overlay(&self, enabled: bool) -> Result<(), CoreError> {
        let mut cfg = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
        cfg.general.show_overlay = enabled;
        cfg.save(&self.config_dir)
    }

    /// Get whether the cache-aware streaming live preview is enabled.
    pub fn get_streaming_preview_enabled(&self) -> Result<bool, CoreError> {
        let config = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
        Ok(config.general.streaming_preview_enabled)
    }

    /// Set and persist the streaming-preview opt-in flag.
    pub fn set_streaming_preview_enabled(&self, enabled: bool) -> Result<(), CoreError> {
        let mut cfg = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
        cfg.general.streaming_preview_enabled = enabled;
        cfg.save(&self.config_dir)
    }

    /// Get whether speaker labels are enabled for meeting transcripts.
    pub fn get_speaker_labels_enabled(&self) -> Result<bool, CoreError> {
        let config = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
        Ok(config.general.speaker_labels_enabled)
    }

    /// Set and persist the speaker-labels opt-in flag.
    pub fn set_speaker_labels_enabled(&self, enabled: bool) -> Result<(), CoreError> {
        let mut cfg = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
        cfg.general.speaker_labels_enabled = enabled;
        cfg.save(&self.config_dir)
    }

    /// Get the preferred audio source bundle ID for meeting capture.
    pub fn get_preferred_audio_source(&self) -> Result<Option<String>, CoreError> {
        let config = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
        Ok(config.general.preferred_audio_source_bundle_id.clone())
    }

    /// Set and persist the preferred audio source bundle ID.
    pub fn set_preferred_audio_source(&self, bundle_id: Option<String>) -> Result<(), CoreError> {
        let mut cfg = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
        cfg.general.preferred_audio_source_bundle_id = bundle_id;
        cfg.save(&self.config_dir)
    }

    /// Get the chunk duration in seconds for meeting transcription.
    pub fn get_chunk_duration(&self) -> Result<u32, CoreError> {
        let config = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
        Ok(config.general.chunk_duration_secs)
    }

    /// Set and persist the chunk duration in seconds (10-120).
    pub fn set_chunk_duration(&self, secs: u32) -> Result<(), CoreError> {
        let clamped = secs.clamp(10, 120);
        let mut cfg = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
        cfg.general.chunk_duration_secs = clamped;
        cfg.save(&self.config_dir)
    }

    /// Get the maximum word count for LLM processing.
    pub fn get_llm_max_words(&self) -> Result<u32, CoreError> {
        let config = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
        Ok(config.general.llm_max_words)
    }

    /// Set and persist the maximum word count for LLM processing (500-10000).
    pub fn set_llm_max_words(&self, words: u32) -> Result<(), CoreError> {
        let clamped = words.clamp(500, 10000);
        let mut cfg = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
        cfg.general.llm_max_words = clamped;
        cfg.save(&self.config_dir)
    }

    /// Get whether debug mode is enabled.
    pub fn get_debug_mode(&self) -> Result<bool, CoreError> {
        let config = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
        Ok(config.general.debug_mode)
    }

    /// Set and persist debug mode.
    pub fn set_debug_mode(&self, enabled: bool) -> Result<(), CoreError> {
        let mut cfg = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
        cfg.general.debug_mode = enabled;
        cfg.save(&self.config_dir)
    }

    /// Get the retention period in days (0 = disabled).
    pub fn get_retention_days(&self) -> Result<u32, CoreError> {
        let config = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
        Ok(config.general.retention_days)
    }

    /// Set and persist the retention period in days (0 = disabled).
    pub fn set_retention_days(&self, days: u32) -> Result<(), CoreError> {
        let mut cfg = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
        cfg.general.retention_days = days;
        cfg.save(&self.config_dir)
    }

    /// Run retention cleanup: delete transcriptions older than the configured period.
    /// Returns the number of deleted transcriptions, or 0 if retention is disabled.
    pub fn run_retention_cleanup(&self) -> Result<u32, CoreError> {
        let days = {
            let config = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
            config.general.retention_days
        };

        if days == 0 {
            return Ok(0);
        }

        let storage = crate::util::lock_named(&self.storage, "Storage", CoreError::IoError)?;
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
        let mut config = self.config.lock().unwrap();
        let generation = config.llm.generation.clone();
        let http = Self::build_llm(&provider, &base_url, &model, api_key, &generation)?;
        config.llm.active_provider =
            (!provider.is_empty() && provider != "none").then_some(provider.clone());
        match provider.as_str() {
            "ollama" => {
                config.llm.ollama.base_url = base_url;
                config.llm.ollama.model = model;
            }
            "lmstudio" => {
                config.llm.lmstudio.base_url = base_url;
                config.llm.lmstudio.model = Some(model);
            }
            "openai" => config.llm.openai.model = Some(model),
            "anthropic" => config.llm.anthropic.model = Some(model),
            _ => {}
        }
        // API keys remain in memory. Legacy TOML keys are removed only after
        // Swift confirms successful provider-specific Keychain migration.
        config.save(&self.config_dir)?;
        drop(config);
        *self.llm.lock().unwrap() = http;
        Ok(())
    }

    pub fn get_llm_settings(&self) -> crate::llm::LlmSettings {
        let provider = self
            .config
            .lock()
            .unwrap()
            .llm
            .active_provider
            .clone()
            .unwrap_or_default();
        self.get_provider_settings(provider)
    }
    pub fn get_provider_settings(&self, provider: String) -> crate::llm::LlmSettings {
        let config = self.config.lock().unwrap();
        let (base_url, model) = match provider.as_str() {
            "ollama" => (
                config.llm.ollama.base_url.clone(),
                config.llm.ollama.model.clone(),
            ),
            "lmstudio" => (
                config.llm.lmstudio.base_url.clone(),
                config.llm.lmstudio.model.clone().unwrap_or_default(),
            ),
            "openai" => (
                "https://api.openai.com".into(),
                config.llm.openai.model.clone().unwrap_or_default(),
            ),
            "anthropic" => (
                "https://api.anthropic.com".into(),
                config.llm.anthropic.model.clone().unwrap_or_default(),
            ),
            _ => (String::new(), String::new()),
        };
        crate::llm::LlmSettings {
            provider,
            base_url,
            model,
        }
    }
    pub fn get_generation_settings(&self) -> crate::llm::GenerationSettings {
        self.config.lock().unwrap().llm.generation.clone()
    }
    pub fn set_generation_settings(
        &self,
        settings: crate::llm::GenerationSettings,
    ) -> Result<(), CoreError> {
        if settings.output_limit == 0
            || settings.output_limit > 32768
            || settings.keep_alive.len() > 20
            || settings
                .thinking_level
                .as_ref()
                .is_some_and(|v| v.len() > 40)
            || (settings.think.is_some() && settings.thinking_level.is_some())
        {
            return Err(CoreError::ConfigError("Invalid generation limits".into()));
        }
        let mut config = self.config.lock().unwrap();
        config.llm.generation = settings;
        config.save(&self.config_dir)
    }
    pub fn legacy_credentials(&self) -> Vec<crate::llm::LegacyCredential> {
        crate::credentials::pending(&self.config.lock().unwrap(), &self.config_dir)
    }
    pub fn credential_account(&self, provider: String) -> String {
        let config = self.config.lock().unwrap();
        let reference = match provider.as_str() {
            "openai" => config.llm.openai.credential_account.clone(),
            "anthropic" => config.llm.anthropic.credential_account.clone(),
            _ => None,
        };
        reference.unwrap_or_else(|| format!("llm-api-key-{provider}"))
    }
    pub fn acknowledge_credential_migration(
        &self,
        credential: crate::llm::LegacyCredential,
    ) -> Result<(), CoreError> {
        let mut config = self.config.lock().unwrap();
        if let Some(profile) = &credential.profile {
            if !Config::list_profiles(&self.config_dir).contains(profile) {
                return Err(CoreError::ConfigError("Unknown profile".into()));
            }
            let original = Config::load_profile(&self.config_dir, profile)?;
            let updated = crate::credentials::migrate(&original, &credential)?;
            updated.write_migrated_profile(&self.config_dir, profile)?;
        } else {
            let updated = crate::credentials::migrate(&config, &credential)?;
            updated.save(&self.config_dir)?;
            *config = updated;
        }
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
                    .error_for_status()
                    .map_err(|e| CoreError::LlmError(e.to_string()))?
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
            "lmstudio" | "openai" | "anthropic" => {
                let models_url = if url.ends_with("/v1") {
                    format!("{url}/models")
                } else {
                    format!("{url}/v1/models")
                };
                let mut models = Vec::new();
                let mut cursor: Option<String> = None;
                for _ in 0..10 {
                    let mut req = client.get(&models_url);
                    if provider == "anthropic" {
                        req = req.query(&[("limit", "1000")]);
                        if let Some(cursor) = &cursor {
                            req = req.query(&[("after_id", cursor)]);
                        }
                    }
                    if let Some(key) = &api_key {
                        req = if provider == "anthropic" {
                            req.header("x-api-key", key)
                                .header("anthropic-version", "2023-06-01")
                        } else {
                            req.bearer_auth(key)
                        };
                    }
                    let data: serde_json::Value = req
                        .send()
                        .and_then(|r| r.error_for_status())
                        .and_then(|r| r.json())
                        .map_err(|e| CoreError::LlmError(e.to_string()))?;
                    let entries = data["data"]
                        .as_array()
                        .ok_or_else(|| CoreError::LlmError("Invalid model list".into()))?;
                    models.extend(
                        entries
                            .iter()
                            .filter_map(|m| m["id"].as_str().map(str::to_string)),
                    );
                    if provider != "anthropic" || data["has_more"].as_bool() != Some(true) {
                        return Ok(models);
                    }
                    let next = data["last_id"]
                        .as_str()
                        .ok_or_else(|| CoreError::LlmError("Missing model-list cursor".into()))?
                        .to_string();
                    if cursor.as_ref() == Some(&next) {
                        return Err(CoreError::LlmError("Repeated model-list cursor".into()));
                    }
                    cursor = Some(next);
                }
                Err(CoreError::LlmError(
                    "Model-list pagination exceeded its limit".into(),
                ))
            }
            _ => Err(CoreError::LlmError(format!("Unknown provider: {provider}"))),
        }
    }

    pub fn ollama_thinking_controls(
        &self,
        base_url: String,
        model: String,
    ) -> Result<Vec<String>, CoreError> {
        let client = reqwest::blocking::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .map_err(|e| CoreError::LlmError(e.to_string()))?;
        let data: serde_json::Value = client
            .post(format!("{}/api/show", base_url.trim_end_matches('/')))
            .json(&serde_json::json!({"model":model}))
            .send()
            .and_then(|r| r.error_for_status())
            .and_then(|r| r.json())
            .map_err(|e| CoreError::LlmError(e.to_string()))?;
        Ok(data["thinking"]["values"]
            .as_array()
            .map(|values| {
                values
                    .iter()
                    .filter(|v| v.is_boolean() || v.is_string())
                    .map(|v| v.to_string())
                    .collect()
            })
            .unwrap_or_default())
    }

    /// Test the currently configured LLM connection. Returns the provider name
    /// on success or an error message on failure.
    pub fn test_llm_connection(&self) -> Result<String, CoreError> {
        let llm_guard = crate::util::lock_named(&self.llm, "LLM", CoreError::LlmError)?;
        let llm = llm_guard
            .clone()
            .ok_or_else(|| CoreError::LlmError("No LLM provider configured".into()))?;
        drop(llm_guard);

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
            let mut p = crate::util::lock_named(
                &self.download_progress,
                "Download progress",
                CoreError::IoError,
            )?;
            if p.state == DownloadState::Downloading {
                return Err(CoreError::IoError(
                    "A download is already in progress".into(),
                ));
            }
            p.state = DownloadState::Downloading;
        }
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
        let p = crate::util::lock_named(
            &self.download_progress,
            "Download progress",
            CoreError::IoError,
        )?;
        Ok(p.clone())
    }

    /// Delete a downloaded model's files.
    pub fn delete_model(&self, model_id: String) -> Result<(), CoreError> {
        if models::model_file_set(&model_id).is_none() {
            return Err(CoreError::ModelNotFound(model_id));
        }
        let _lifecycle = self.model_lifecycle.lock().unwrap();
        if model_id.starts_with("nemotron-") {
            self.model_generation.fetch_add(1, Ordering::SeqCst);
            self.streaming_sessions.lock().unwrap().clear();
            *self.streaming.lock().unwrap() = None;
            *self.streaming_readiness.lock().unwrap() = crate::speech::ModelReadiness::Unavailable;
        }
        if model_id.starts_with("parakeet-") {
            self.offline_generation.fetch_add(1, Ordering::SeqCst);
        }
        let model_path = self.models_dir.join(&model_id);

        if !model_path.exists() {
            return Ok(());
        }

        // Unload if this model is currently active
        {
            let config_guard =
                crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
            if config_guard.stt.active_model.as_deref() == Some(&model_id) {
                drop(config_guard);
                *self.stt.lock().unwrap() = None;
            }
        }

        std::fs::remove_dir_all(&model_path)
            .map_err(|e| CoreError::IoError(format!("Failed to delete model {model_id}: {e}")))?;

        Ok(())
    }

    // --- Session-based chunked transcription (for meetings / long-form audio) ---

    /// Start a new chunked transcription session.
    pub fn start_session(&self, session_id: String) -> Result<(), CoreError> {
        let mut processing = self.processing.lock().unwrap();
        if processing.len() >= 16 {
            return Err(CoreError::TranscriptionFailed(
                "Too many active processing sessions".into(),
            ));
        }
        self.storage
            .lock()
            .unwrap()
            .begin_draft(&session_id, "meeting", "dictation")?;
        self.sessions.lock().unwrap().start(&session_id)?;
        self.completed_events
            .lock()
            .unwrap()
            .retain(|(id, _)| id != &session_id);
        processing.insert(
            session_id.clone(),
            crate::processing::ProcessingSession::new(session_id),
        );
        Ok(())
    }
    pub fn poll_transcription_events(
        &self,
        session_id: String,
    ) -> Vec<crate::processing::TranscriptionEvent> {
        if let Some(session) = self.processing.lock().unwrap().get(&session_id) {
            return session.events();
        }
        let mut completed = self.completed_events.lock().unwrap();
        if let Some(index) = completed.iter().position(|(id, _)| id == &session_id) {
            return completed.remove(index).unwrap().1;
        }
        Vec::new()
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
    /// instead of text matching. Pass 0 for non-overlapping audio.
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
        chunk_index: u32,
        chunk_overlap_secs: f64,
        mode: String,
        context: Option<AppContext>,
    ) -> Result<ChunkResult, CoreError> {
        let processing = self.processing_session(&session_id)?;
        let _operation = processing.operation.lock().unwrap();
        if processing.contains(chunk_index, ChunkSource::Mixed) {
            return Err(CoreError::TranscriptionFailed(
                "Duplicate chunk identity".into(),
            ));
        }
        // Session chunks are deliberately NOT routed through
        // `audio::preprocess`. That helper runs `EnergyVad` (tuned for
        // close-mic push-to-talk at ~ -36 dBFS) and trims leading /
        // trailing silence. For meetings — especially the system-audio
        // half of the mix, which we attenuate -6 dB before summing —
        // typical voice levels sit *below* that VAD threshold, so the
        // entire chunk gets rejected as "silence" and the meeting
        // produces an empty transcript even though there was real
        // audio in the buffer. Issue #23 was exactly this. Parakeet
        // already handles intra-chunk silence internally, so we just
        // validate format and pass the buffer straight through.
        let chunk_duration_secs = audio_samples.len() as f64 / sample_rate as f64;
        log::info!(
            "session '{}' chunk {} in: {} samples ({:.1}s @ {}Hz, overlap={:.1}s)",
            session_id,
            chunk_index,
            audio_samples.len(),
            chunk_duration_secs,
            sample_rate,
            chunk_overlap_secs
        );

        if sample_rate != crate::audio::TARGET_SAMPLE_RATE {
            return Err(CoreError::AudioError(format!(
                "Expected {}Hz audio, got {}Hz. Resample before sending to engine.",
                crate::audio::TARGET_SAMPLE_RATE,
                sample_rate
            )));
        }
        if audio_samples.is_empty() {
            log::warn!(
                "session '{}' chunk {}: empty audio buffer, skipping",
                session_id,
                chunk_index
            );
            let mut mgr =
                crate::util::lock_named(&self.sessions, "Session", CoreError::TranscriptionFailed)?;
            let mut chunk_result = mgr.add_chunk_with_overlap(
                &session_id,
                "",
                chunk_duration_secs,
                chunk_overlap_secs,
                Vec::new(),
            )?;
            chunk_result.llm_error = None;
            drop(mgr);
            processing.enqueue(chunk_index, ChunkSource::Mixed, String::new(), None, None)?;
            return Ok(chunk_result);
        }

        // Quick RMS log so we can see in stderr/Console.app whether
        // the chunk that reached us actually contains signal — this
        // is the single most useful number when debugging "no speech
        // detected" reports.
        let rms = {
            let sum_sq: f64 = audio_samples.iter().map(|s| (*s as f64).powi(2)).sum();
            (sum_sq / audio_samples.len() as f64).sqrt()
        };
        let peak = audio_samples
            .iter()
            .copied()
            .fold(0.0_f32, |a, b| a.max(b.abs()));
        log::info!(
            "session '{}' chunk {} levels: rms={:.4} ({:.1} dBFS), peak={:.4} ({:.1} dBFS)",
            session_id,
            chunk_index,
            rms,
            20.0 * rms.max(1e-9).log10(),
            peak,
            20.0 * (peak.max(1e-9) as f64).log10()
        );

        let retain_audio = self.get_recovery_audio()
            && self
                .storage
                .lock()
                .unwrap()
                .capture_sources(&session_id)?
                .is_empty();
        self.storage.lock().unwrap().journal_chunk(
            &session_id,
            chunk_index,
            ChunkSource::Mixed,
            &audio_samples,
            sample_rate,
            chunk_overlap_secs,
            retain_audio,
        )?;
        // Keep the original samples in the recovery journal until the recording is saved.
        let stt_result = {
            let stt_guard = self.stt.lock().unwrap();
            stt_guard
                .as_ref()
                .ok_or_else(|| CoreError::TranscriptionFailed("No STT model loaded".into()))
                .and_then(|stt| stt.transcribe(&audio_samples, sample_rate))
        };
        let stt_result = match stt_result {
            Ok(result) => result,
            Err(error) => {
                self.sessions.lock().unwrap().add_chunk_with_source(
                    &session_id,
                    ChunkSource::Mixed,
                    chunk_index,
                    "",
                    chunk_duration_secs,
                    chunk_overlap_secs,
                    Vec::new(),
                )?;
                processing.enqueue(
                    chunk_index,
                    ChunkSource::Mixed,
                    String::new(),
                    None,
                    Some("Speech recognition failed. Recovery is available in history.".into()),
                )?;
                return Err(error);
            }
        };

        let ctx = context.unwrap_or_default();
        let chunk_text = stt_result.text;

        // Apply LLM post-processing per-chunk to avoid accumulating
        // a huge transcript that overwhelms the LLM at session end.
        let llm_error: Option<String> = None;

        // Stitch into session with overlap dedup.
        let mut mgr =
            crate::util::lock_named(&self.sessions, "Session", CoreError::TranscriptionFailed)?;
        let mut chunk_result = mgr.add_chunk_with_overlap(
            &session_id,
            &chunk_text,
            chunk_duration_secs,
            chunk_overlap_secs,
            stt_result.segments,
        )?;
        chunk_result.llm_error = llm_error.clone();
        drop(mgr);
        let recognized_text = chunk_result.text.clone();
        chunk_result.text = self.dictionary.lock().unwrap().apply(
            &crate::filler::remove_fillers(&chunk_result.text),
            &ctx,
            &mode,
        );
        self.storage.lock().unwrap().recognize_draft_chunk(
            &session_id,
            chunk_index,
            ChunkSource::Mixed,
            &recognized_text,
        )?;
        self.storage.lock().unwrap().save_draft_segments(
            &session_id,
            chunk_index,
            ChunkSource::Mixed,
            &chunk_result
                .segments
                .iter()
                .cloned()
                .map(|mut segment| {
                    segment.start_secs += chunk_result.chunk_offset_secs;
                    segment.end_secs += chunk_result.chunk_offset_secs;
                    segment
                })
                .collect::<Vec<_>>(),
        )?;
        self.queue_polishing(
            &session_id,
            chunk_index,
            ChunkSource::Mixed,
            &chunk_result.text,
            &mode,
            &ctx,
        )?;
        processing.set_recognized_text(chunk_index, ChunkSource::Mixed, &recognized_text);
        log::info!(
            "session '{}' chunk {} out: {} chars, {} segments{}",
            session_id,
            chunk_index,
            chunk_result.text.len(),
            chunk_result.segments.len(),
            if llm_error.is_some() {
                " (LLM degraded)"
            } else {
                ""
            }
        );
        Ok(chunk_result)
    }

    /// Process a chunk from a single audio source (mic or system) for
    /// the speaker-labelled meeting pipeline.
    ///
    /// `slice_index` is shared across sources for the same wall-clock
    /// window — Swift dispatches mic and system with matching indices
    /// so the session manager can line up their segments. Mic segments
    /// are tagged `"Me"`; system segments currently stay un-labelled
    /// (diarization will fill those in once model support lands).
    ///
    /// `ChunkSource::Mixed` delegates to `process_chunk_with_overlap`
    /// for backward compatibility with the legacy mixed-stream flow.
    #[allow(clippy::too_many_arguments)]
    pub fn process_source_chunk(
        &self,
        session_id: String,
        source: ChunkSource,
        slice_index: u32,
        audio_samples: Vec<f32>,
        sample_rate: u32,
        chunk_overlap_secs: f64,
        mode: String,
        context: Option<AppContext>,
    ) -> Result<ChunkResult, CoreError> {
        if source == ChunkSource::Mixed {
            return self.process_chunk_with_overlap(
                session_id,
                audio_samples,
                sample_rate,
                slice_index,
                chunk_overlap_secs,
                mode,
                context,
            );
        }

        let processing = self.processing_session(&session_id)?;
        let _operation = processing.operation.lock().unwrap();
        if processing.contains(slice_index, source) {
            return Err(CoreError::TranscriptionFailed(
                "Duplicate chunk identity".into(),
            ));
        }
        let chunk_duration_secs = audio_samples.len() as f64 / sample_rate as f64;
        log::info!(
            "session '{}' slice {} source={:?}: {} samples ({:.1}s @ {}Hz, overlap={:.1}s)",
            session_id,
            slice_index,
            source,
            audio_samples.len(),
            chunk_duration_secs,
            sample_rate,
            chunk_overlap_secs
        );

        if sample_rate != crate::audio::TARGET_SAMPLE_RATE {
            return Err(CoreError::AudioError(format!(
                "Expected {}Hz audio, got {}Hz. Resample before sending to engine.",
                crate::audio::TARGET_SAMPLE_RATE,
                sample_rate
            )));
        }

        if audio_samples.is_empty() {
            let mut mgr =
                crate::util::lock_named(&self.sessions, "Session", CoreError::TranscriptionFailed)?;
            let result = mgr.add_chunk_with_source(
                &session_id,
                source,
                slice_index,
                "",
                chunk_duration_secs,
                chunk_overlap_secs,
                Vec::new(),
            )?;
            drop(mgr);
            processing.enqueue(slice_index, source, String::new(), None, None)?;
            return Ok(result);
        }

        let retain_audio = self.get_recovery_audio()
            && self
                .storage
                .lock()
                .unwrap()
                .capture_sources(&session_id)?
                .is_empty();
        self.storage.lock().unwrap().journal_chunk(
            &session_id,
            slice_index,
            source,
            &audio_samples,
            sample_rate,
            chunk_overlap_secs,
            retain_audio,
        )?;
        // Keep the original samples in the recovery journal until the recording is saved.
        let stt_result = {
            let stt_guard = self.stt.lock().unwrap();
            stt_guard
                .as_ref()
                .ok_or_else(|| CoreError::TranscriptionFailed("No STT model loaded".into()))
                .and_then(|stt| stt.transcribe(&audio_samples, sample_rate))
        };
        let stt_result = match stt_result {
            Ok(result) => result,
            Err(error) => {
                self.sessions.lock().unwrap().add_chunk_with_source(
                    &session_id,
                    source,
                    slice_index,
                    "",
                    chunk_duration_secs,
                    chunk_overlap_secs,
                    Vec::new(),
                )?;
                processing.enqueue(
                    slice_index,
                    source,
                    String::new(),
                    None,
                    Some("Speech recognition failed. Recovery is available in history.".into()),
                )?;
                return Err(error);
            }
        };

        let ctx = context.unwrap_or_default();
        let chunk_text = stt_result.text;

        let llm_error: Option<String> = None;

        let mut mgr =
            crate::util::lock_named(&self.sessions, "Session", CoreError::TranscriptionFailed)?;
        let mut chunk_result = mgr.add_chunk_with_source(
            &session_id,
            source,
            slice_index,
            &chunk_text,
            chunk_duration_secs,
            chunk_overlap_secs,
            stt_result.segments,
        )?;
        chunk_result.llm_error = llm_error;
        drop(mgr);
        let recognized_text = chunk_result.text.clone();
        chunk_result.text = self.dictionary.lock().unwrap().apply(
            &crate::filler::remove_fillers(&chunk_result.text),
            &ctx,
            &mode,
        );
        self.storage.lock().unwrap().recognize_draft_chunk(
            &session_id,
            slice_index,
            source,
            &recognized_text,
        )?;
        self.storage.lock().unwrap().save_draft_segments(
            &session_id,
            slice_index,
            source,
            &chunk_result
                .segments
                .iter()
                .cloned()
                .map(|mut segment| {
                    segment.start_secs += chunk_result.chunk_offset_secs;
                    segment.end_secs += chunk_result.chunk_offset_secs;
                    segment
                })
                .collect::<Vec<_>>(),
        )?;
        self.queue_polishing(
            &session_id,
            slice_index,
            source,
            &chunk_result.text,
            &mode,
            &ctx,
        )?;
        processing.set_recognized_text(slice_index, source, &recognized_text);
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
        let session = self.processing_session(&session_id)?;
        let _operation = session.operation.lock().unwrap();
        // Extract accumulated text, duration, and segments from the session.
        let mut mgr =
            crate::util::lock_named(&self.sessions, "Session", CoreError::TranscriptionFailed)?;
        let (text, duration_secs, segments) = mgr.finish(&session_id)?;
        drop(mgr);

        let processing = self.processing.lock().unwrap().get(&session_id).cloned();
        let (text, mut summary, llm_error) = if let Some(session) = processing {
            let (polished, summary, error) = session.finish()?;
            (
                if polished.is_empty() { text } else { polished },
                summary,
                error,
            )
        } else {
            (
                text.clone(),
                crate::processing::ProcessingSummary {
                    recognized_text: text,
                    status: "completed".into(),
                },
                None,
            )
        };
        let failed_chunks = {
            let storage = self.storage.lock().unwrap();
            storage.draft_failure_count(&session_id)?
                + u32::from(storage.has_speech_gap(&session_id)?)
        };
        if failed_chunks > 0 {
            summary.status = "incomplete".into();
        }
        let result = TranscriptionResult {
            text,
            duration_secs,
            provider_name: "parakeet".to_string(),
            segments,
            llm_error,
        };

        let ctx = context.unwrap_or_default();
        let src = source.as_deref().unwrap_or("meeting");
        let input = if src == "push_to_talk" {
            "mic"
        } else {
            "mixed"
        };

        log::info!(
            "Finishing session '{}' ({:.1}s, {} segments, {} chars) — persisting",
            session_id,
            result.duration_secs,
            result.segments.len(),
            result.text.len()
        );

        // For meeting sessions a persistence failure is the bug we're
        // trying to make non-silent (issue #23). Propagate it so the
        // Swift layer can surface an error to the user instead of
        // returning a successful-looking TranscriptionResult that was
        // never actually saved.
        let saved =
            self.auto_save_transcription(&session_id, &result, src, &mode, input, &ctx, &summary)?;
        if let Some(id) = saved {
            let mut sections = session.sections();
            for section in &mut sections {
                if section.recognized_text.is_empty() && section.error.is_some() {
                    section.status = "speech_failed".into();
                }
            }
            self.storage.lock().unwrap().save_sections(&id, &sections)?;
        }
        if failed_chunks == 0 {
            self.storage.lock().unwrap().discard_draft(&session_id)?;
        }
        let mut processing = self.processing.lock().unwrap();
        let mut completed = self.completed_events.lock().unwrap();
        if completed.len() >= 16 {
            completed.pop_front();
        }
        completed.push_back((session_id.clone(), session.events()));
        processing.remove(&session_id);

        if failed_chunks > 0 {
            return Err(CoreError::TranscriptionFailed(format!("Recording is incomplete: {failed_chunks} speech sections failed. Open history to recover available speech.")));
        }
        Ok(result)
    }

    /// Get the accumulated text for a session on demand, without the per-chunk
    /// cloning overhead of `ChunkResult.accumulated_text`.
    pub fn get_session_text(&self, session_id: String) -> Result<String, CoreError> {
        if let Some(session) = self.processing.lock().unwrap().get(&session_id) {
            return Ok(session.text());
        }
        let mgr =
            crate::util::lock_named(&self.sessions, "Session", CoreError::TranscriptionFailed)?;
        mgr.get_session_text(&session_id)
    }

    /// Cancel and discard a session.
    pub fn cancel_session(&self, session_id: String) {
        if let Some(session) = self.processing.lock().unwrap().remove(&session_id) {
            session.cancel();
        }
        if let Ok(mut mgr) = self.sessions.lock() {
            mgr.cancel(&session_id);
        }
    }

    // --- Transcription history CRUD ---

    pub fn get_transcription_processing(
        &self,
        id: String,
    ) -> Result<crate::processing::ProcessingSummary, CoreError> {
        self.storage.lock().unwrap().get_processing(&id)
    }

    /// Save a transcription to history (for external callers).
    pub fn save_transcription(
        &self,
        transcription: StoredTranscription,
    ) -> Result<String, CoreError> {
        let storage = crate::util::lock_named(&self.storage, "Storage", CoreError::IoError)?;
        storage.save(&transcription)
    }

    /// Get usage statistics as key-value pairs.
    pub fn get_statistics(&self) -> Result<Vec<Vec<String>>, CoreError> {
        let storage = crate::util::lock_named(&self.storage, "Storage", CoreError::IoError)?;
        let stats = storage.get_statistics()?;
        Ok(stats.into_iter().map(|(k, v)| vec![k, v]).collect())
    }

    /// List transcriptions with optional filtering and search.
    pub fn list_transcriptions(
        &self,
        query: TranscriptionQuery,
    ) -> Result<Vec<StoredTranscription>, CoreError> {
        let storage = crate::util::lock_named(&self.storage, "Storage", CoreError::IoError)?;
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
        let storage = crate::util::lock_named(&self.storage, "Storage", CoreError::IoError)?;
        storage.list(&query)
    }

    /// Get a single transcription by ID.
    pub fn get_transcription(&self, id: String) -> Result<StoredTranscription, CoreError> {
        let storage = crate::util::lock_named(&self.storage, "Storage", CoreError::IoError)?;
        storage.get(&id)
    }

    /// Update the title of a transcription.
    pub fn update_transcription_title(&self, id: String, title: String) -> Result<(), CoreError> {
        let storage = crate::util::lock_named(&self.storage, "Storage", CoreError::IoError)?;
        storage.update_title(&id, &title)
    }

    /// Delete a transcription from history.
    pub fn delete_transcription(&self, id: String) -> Result<(), CoreError> {
        let storage = crate::util::lock_named(&self.storage, "Storage", CoreError::IoError)?;
        storage.delete(&id)
    }

    /// Delete multiple transcriptions by IDs. Returns the number deleted.
    pub fn delete_transcriptions(&self, ids: Vec<String>) -> Result<u32, CoreError> {
        let storage = crate::util::lock_named(&self.storage, "Storage", CoreError::IoError)?;
        storage.delete_many(&ids)
    }

    /// Get timestamp segments for a transcription (for timeline display).
    pub fn get_transcription_segments(
        &self,
        id: String,
    ) -> Result<Vec<TimestampedSegment>, CoreError> {
        let storage = crate::util::lock_named(&self.storage, "Storage", CoreError::IoError)?;
        storage.get_segments(&id)
    }

    pub fn export_database(&self, dest_path: String) -> Result<(), CoreError> {
        self.storage
            .lock()
            .unwrap()
            .export_to(std::path::Path::new(&dest_path))
    }
    pub fn import_database(&self, source_path: String) -> Result<(), CoreError> {
        self.storage
            .lock()
            .unwrap()
            .import_from(std::path::Path::new(&source_path), &self.config_dir)
    }
}

impl Engine {
    pub fn install_streaming_provider(
        &self,
        provider: Box<dyn StreamingProvider>,
    ) -> Result<(), CoreError> {
        *self.streaming.lock().unwrap() = Some(provider);
        *self.streaming_readiness.lock().unwrap() = crate::speech::ModelReadiness::Ready;
        Ok(())
    }
    fn llm_request(
        &self,
        text: &str,
        mode: &str,
        ctx: &AppContext,
    ) -> Result<Option<ProcessingJob>, CoreError> {
        if text.trim().is_empty() {
            return Ok(None);
        }
        let config = self.config.lock().unwrap();
        let all_modes = if config.modes.is_empty() {
            modes::default_modes()
        } else {
            config.modes.clone()
        };
        let max_words = config.general.llm_max_words as usize;
        drop(config);
        let Some(mode) = modes::find_mode(&all_modes, mode) else {
            return Ok(None);
        };
        let Some(mut system_prompt) = mode.system_prompt.clone() else {
            return Ok(None);
        };
        let Some(provider) = self.llm.lock().unwrap().clone() else {
            return Ok(None);
        };
        if text.split_whitespace().count() > max_words {
            return Err(CoreError::LlmError(
                "Polishing skipped: input exceeds the configured word limit".into(),
            ));
        }
        let words: Vec<String> = self
            .dictionary
            .lock()
            .unwrap()
            .rules()
            .iter()
            .filter(|r| r.enabled && r.pattern == r.replacement)
            .map(|r| r.pattern.clone())
            .collect();
        if !words.is_empty() {
            system_prompt.push_str(&format!("\n\nDomain vocabulary: {}", words.join(", ")));
        }
        Ok(Some((
            provider,
            LlmRequest {
                text: text.into(),
                system_prompt,
                context: Some(ctx.clone()),
            },
        )))
    }
    fn processing_session(
        &self,
        id: &str,
    ) -> Result<Arc<crate::processing::ProcessingSession>, CoreError> {
        self.processing
            .lock()
            .unwrap()
            .get(id)
            .cloned()
            .ok_or_else(|| CoreError::TranscriptionFailed("Processing session not found".into()))
    }
    fn queue_polishing(
        &self,
        id: &str,
        index: u32,
        source: ChunkSource,
        text: &str,
        mode: &str,
        context: &AppContext,
    ) -> Result<(), CoreError> {
        let session = self.processing_session(id)?;
        let (work, error) = match self.llm_request(text, mode, context) {
            Ok(work) => (work, None),
            Err(error) => (None, Some(error.to_string())),
        };
        session.enqueue(index, source, text.into(), work, error)
    }
    #[allow(clippy::too_many_arguments)]
    fn auto_save_transcription(
        &self,
        session_id: &str,
        result: &TranscriptionResult,
        source: &str,
        mode: &str,
        audio_source: &str,
        context: &AppContext,
        summary: &crate::processing::ProcessingSummary,
    ) -> Result<Option<String>, CoreError> {
        let is_meeting = source == "meeting";
        let trimmed_empty = result.text.trim().is_empty();

        // Push-to-talk: an empty transcript is a normal "user said nothing"
        // outcome — skip silently as before. Meetings, on the other hand,
        // run for minutes; an empty result there is almost always a bug
        // (silent capture, VAD over-rejection, all chunks failing) and we
        // want a row in the DB anyway so the user can see *something*
        // happened and we have a breadcrumb to debug from.
        if trimmed_empty && !is_meeting && summary.status != "incomplete" {
            log::debug!("Skipping auto-save: empty push-to-talk result");
            return Ok(None);
        }

        if trimmed_empty && is_meeting {
            log::warn!(
                "Meeting session produced empty transcript ({:.1}s, {} segments) — saving placeholder row for diagnostics",
                result.duration_secs,
                result.segments.len()
            );
        }

        let now = chrono::Utc::now().to_rfc3339();
        let title = format!(
            "{} {}",
            if is_meeting { "Meeting" } else { "Note" },
            chrono::Utc::now().format("%Y-%m-%d %H:%M")
        );

        let app_context_json = serde_json::to_string(context).ok();

        let text = if trimmed_empty {
            if summary.status == "incomplete" {
                "[incomplete recording]"
            } else {
                "[no speech detected]"
            }
            .to_string()
        } else {
            result.text.clone()
        };

        let transcription = StoredTranscription {
            id: session_id.to_string(),
            created_at: now,
            duration_secs: result.duration_secs,
            source: source.to_string(),
            mode: mode.to_string(),
            audio_source: Some(audio_source.to_string()),
            app_context: app_context_json,
            title: Some(title),
            text,
        };

        let storage = self.storage.lock().map_err(|e| {
            // Lock poisoning used to silently swallow the entire save —
            // see issue #23. Surface it loudly so callers can react.
            log::error!("Storage lock poisoned during auto-save: {e}");
            CoreError::TranscriptionFailed(format!("Storage lock poisoned: {e}"))
        })?;

        storage.save_complete(&transcription, &result.segments, summary)?;

        Ok(Some(transcription.id))
    }

    /// Set up the LLM provider based on current config.
    fn build_llm(
        provider: &str,
        base: &str,
        model: &str,
        key: Option<String>,
        generation: &crate::llm::GenerationSettings,
    ) -> Result<Option<Arc<dyn LlmProvider>>, CoreError> {
        use crate::llm::http::{HttpProvider, Wire};
        if provider.is_empty() || provider == "none" {
            return Ok(None);
        }
        if model.trim().is_empty() {
            return Err(CoreError::ConfigError(
                "Select an LLM model before enabling the provider".into(),
            ));
        }
        let remote = provider == "openai" || provider == "anthropic";
        if remote && key.as_ref().is_none_or(|k| k.is_empty()) {
            return Err(CoreError::ConfigError("API key required".into()));
        }
        let base = base.trim_end_matches('/');
        let (base, wire) = match provider {
            "ollama" => (base.into(), Wire::Ollama),
            "lmstudio" => (
                if base.ends_with("/v1") {
                    base.into()
                } else {
                    format!("{base}/v1")
                },
                Wire::Chat,
            ),
            "openai" => ("https://api.openai.com/v1".into(), Wire::Responses),
            "anthropic" => ("https://api.anthropic.com/v1".into(), Wire::Anthropic),
            _ => return Err(CoreError::ConfigError("Unknown LLM provider".into())),
        };
        let mut http = HttpProvider::new(&base, model, key, wire);
        http.output_limit = generation.output_limit;
        http.keep_alive = generation.keep_alive.clone();
        http.think = generation.think;
        http.thinking_level = generation.thinking_level.clone();
        Ok(Some(Arc::new(http)))
    }
    fn setup_llm_provider(&self) -> Result<(), CoreError> {
        let settings = self.get_llm_settings();
        let config = self.config.lock().unwrap();
        let key = match settings.provider.as_str() {
            "openai" => config.llm.openai.api_key.clone(),
            "anthropic" => config.llm.anthropic.api_key.clone(),
            _ => None,
        };
        if (settings.provider == "openai" || settings.provider == "anthropic") && key.is_none() {
            return Ok(());
        }
        if settings.model.is_empty() {
            return Ok(());
        }
        let provider = Self::build_llm(
            &settings.provider,
            &settings.base_url,
            &settings.model,
            key,
            &config.llm.generation,
        )?;
        drop(config);
        *self.llm.lock().unwrap() = provider;
        Ok(())
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        if let Ok(sessions) = self.processing.lock() {
            for session in sessions.values() {
                session.cancel();
            }
        }
        self.download_cancel.store(true, Ordering::Relaxed);
    }
}

#[cfg(test)]
mod processing_integration_tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    struct Speech(Arc<AtomicUsize>);
    impl SttProvider for Speech {
        fn name(&self) -> &str {
            "test"
        }
        fn is_loaded(&self) -> bool {
            true
        }
        fn transcribe(&self, _: &[f32], _: u32) -> Result<TranscriptionResult, CoreError> {
            self.0.fetch_add(1, Ordering::SeqCst);
            Ok(TranscriptionResult {
                text: "recognized words".into(),
                duration_secs: 2.,
                provider_name: "test".into(),
                llm_error: None,
                segments: vec![TimestampedSegment {
                    text: "recognized words".into(),
                    start_secs: 0.25,
                    end_secs: 1.75,
                    speaker: None,
                }],
            })
        }
    }
    struct Polish;
    impl LlmProvider for Polish {
        fn name(&self) -> &str {
            "test"
        }
        fn is_available(&self) -> bool {
            true
        }
        fn process(&self, _: &LlmRequest) -> Result<String, CoreError> {
            Ok("A rewritten sentence.".into())
        }
    }
    fn setup() -> (Engine, tempfile::TempDir, Arc<AtomicUsize>) {
        let directory = tempfile::tempdir().unwrap();
        let engine = Engine::new(EngineConfig {
            models_dir: directory.path().join("models").display().to_string(),
            config_dir: directory.path().display().to_string(),
            active_stt_model: None,
            active_llm_provider: None,
            active_mode: "clean".into(),
        })
        .unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        *engine.stt.lock().unwrap() = Some(Box::new(Speech(calls.clone())));
        *engine.llm.lock().unwrap() = Some(Arc::new(Polish));
        (engine, directory, calls)
    }
    fn failed_history(engine: &Engine) {
        let db = engine.storage.lock().unwrap();
        db.save(&StoredTranscription {
            id: "retry".into(),
            created_at: "2026-09-26T00:00:00Z".into(),
            duration_secs: 20.0,
            source: "meeting".into(),
            mode: "clean".into(),
            audio_source: None,
            app_context: None,
            title: None,
            text: "Original words".into(),
        })
        .unwrap();
        db.save_processing(
            "retry",
            &crate::processing::ProcessingSummary {
                recognized_text: "Original words".into(),
                status: "degraded".into(),
            },
        )
        .unwrap();
        db.save_sections(
            "retry",
            &(0..12)
                .map(|chunk_id| crate::recovery::HistorySection {
                    chunk_id,
                    source: ChunkSource::Mixed,
                    recognized_text: "Original words".into(),
                    text: "Original words".into(),
                    status: "failed".into(),
                    error: Some("Unavailable".into()),
                })
                .collect::<Vec<_>>(),
        )
        .unwrap();
    }

    #[test]
    fn retry_history_processes_more_than_queue_capacity_and_keeps_original_and_undo() {
        let (engine, _dir, _) = setup();
        failed_history(&engine);
        engine.retry_history_processing("retry".into()).unwrap();
        let db = engine.storage.lock().unwrap();
        assert_eq!(
            db.get("retry")
                .unwrap()
                .text
                .matches("A rewritten sentence.")
                .count(),
            12
        );
        assert_eq!(
            db.get_processing("retry").unwrap().recognized_text,
            "Original words"
        );
        assert_eq!(db.get_processing("retry").unwrap().status, "completed");
        assert!(db
            .history_sections("retry")
            .unwrap()
            .iter()
            .all(|s| s.status == "completed"));
        db.undo_transcription_edit("retry").unwrap();
        assert_eq!(db.get("retry").unwrap().text, "Original words");
    }

    #[test]
    fn cancelled_history_retry_cannot_replace_saved_text() {
        struct Slow(std::sync::mpsc::SyncSender<()>);
        impl LlmProvider for Slow {
            fn name(&self) -> &str {
                "slow test"
            }
            fn is_available(&self) -> bool {
                true
            }
            fn process(&self, _: &LlmRequest) -> Result<String, CoreError> {
                unreachable!()
            }
            fn process_cancellable(
                &self,
                _: &LlmRequest,
                token: &tokio_util::sync::CancellationToken,
                _: &(dyn Fn(&str) + Send + Sync),
            ) -> Result<String, CoreError> {
                self.0.send(()).unwrap();
                while !token.is_cancelled() {
                    std::thread::sleep(std::time::Duration::from_millis(1));
                }
                Ok("Late output must not be saved".into())
            }
        }
        let (engine, _dir, _) = setup();
        failed_history(&engine);
        let (started, receiver) = std::sync::mpsc::sync_channel(1);
        *engine.llm.lock().unwrap() = Some(Arc::new(Slow(started)));
        std::thread::scope(|scope| {
            let job = scope.spawn(|| engine.retry_history_processing("retry".into()));
            receiver
                .recv_timeout(std::time::Duration::from_secs(5))
                .unwrap();
            engine.cancel_history_processing("retry".into());
            assert!(job.join().unwrap().is_err());
        });
        assert_eq!(
            engine.storage.lock().unwrap().get("retry").unwrap().text,
            "Original words"
        );
        assert!(!engine
            .processing
            .lock()
            .unwrap()
            .contains_key("history:retry"));
    }

    #[test]
    fn recover_capture_before_any_speech_chunk_was_submitted() {
        let (engine, _dir, calls) = setup();
        engine.set_recovery_audio(true).unwrap();
        engine
            .begin_capture("early".into(), "push_to_talk".into(), "dictation".into())
            .unwrap();
        engine
            .append_capture_audio("early".into(), ChunkSource::Mixed, vec![0.1; 16000])
            .unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        assert!(engine.list_recording_drafts().unwrap().is_empty());
        assert!(engine.recover_recording("early".into(), true).is_err());
        engine.end_capture("early".into());
        assert!(engine.list_recording_drafts().unwrap()[0].audio_available);
        engine.recover_recording("early".into(), true).unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert_eq!(
            engine.storage.lock().unwrap().get("early").unwrap().text,
            "recognized words"
        );
        assert!(engine.list_recording_drafts().unwrap().is_empty());
    }
    #[test]
    fn lost_capture_blocks_prevent_success_even_if_recognition_succeeds() {
        let (engine, _dir, _) = setup();
        engine
            .begin_capture("gap".into(), "push_to_talk".into(), "dictation".into())
            .unwrap();
        engine
            .start_recording("gap".into(), "push_to_talk".into(), "dictation".into())
            .unwrap();
        engine
            .process_chunk(
                "gap".into(),
                vec![0.1; 16000],
                16000,
                0,
                "dictation".into(),
                None,
            )
            .unwrap();
        engine.mark_capture_gap("gap".into(), true).unwrap();
        assert!(engine
            .finish_session(
                "gap".into(),
                "dictation".into(),
                None,
                Some("push_to_talk".into())
            )
            .is_err());
        assert_eq!(
            engine
                .storage
                .lock()
                .unwrap()
                .get_processing("gap")
                .unwrap()
                .status,
            "incomplete"
        );
    }

    #[test]
    fn failed_speech_is_incomplete_and_can_be_recovered_without_duplicate_history() {
        let (engine, _dir, _calls) = setup();
        engine.set_recovery_audio(true).unwrap();
        engine
            .start_recording("recover".into(), "push_to_talk".into(), "dictation".into())
            .unwrap();
        *engine.stt.lock().unwrap() = None;
        assert!(engine
            .process_chunk(
                "recover".into(),
                vec![0.1; 32000],
                16000,
                0,
                "dictation".into(),
                None
            )
            .is_err());
        assert!(engine
            .finish_session(
                "recover".into(),
                "dictation".into(),
                None,
                Some("push_to_talk".into())
            )
            .is_err());
        engine.cancel_session("recover".into());
        assert_eq!(
            engine
                .get_transcription_processing("recover".into())
                .unwrap()
                .status,
            "incomplete"
        );
        assert_eq!(engine.list_recording_drafts().unwrap()[0].failed_chunks, 1);
        *engine.stt.lock().unwrap() = Some(Box::new(Speech(Arc::new(AtomicUsize::new(0)))));
        engine.recover_recording("recover".into(), true).unwrap();
        assert!(engine.list_recording_drafts().unwrap().is_empty());
        assert_eq!(
            engine
                .get_transcription_processing("recover".into())
                .unwrap()
                .status,
            "completed"
        );
        assert_eq!(
            engine.storage.lock().unwrap().get("recover").unwrap().text,
            "recognized words"
        );
        assert_eq!(
            engine
                .storage
                .lock()
                .unwrap()
                .list(&TranscriptionQuery {
                    search_text: None,
                    source_filter: None,
                    limit: 10,
                    offset: 0
                })
                .unwrap()
                .len(),
            1
        );
    }
    #[test]
    fn completed_text_and_recognized_timestamps_survive_storage_and_duplicate_input() {
        let (engine, _directory, calls) = setup();
        engine.start_session("s".into()).unwrap();
        let chunk = engine
            .process_chunk("s".into(), vec![0.1; 32000], 16000, 0, "clean".into(), None)
            .unwrap();
        assert_eq!(chunk.text, "recognized words");
        assert!(engine
            .process_chunk("s".into(), vec![0.1; 32000], 16000, 0, "clean".into(), None)
            .is_err());
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        let result = engine
            .finish_session(
                "s".into(),
                "clean".into(),
                None,
                Some("push_to_talk".into()),
            )
            .unwrap();
        assert_eq!(result.text, "A rewritten sentence.");
        assert_eq!(result.segments[0].text, "recognized words");
        assert_eq!(
            (result.segments[0].start_secs, result.segments[0].end_secs),
            (0.25, 1.75)
        );
        let rows = engine
            .list_transcriptions(TranscriptionQuery {
                search_text: None,
                source_filter: None,
                limit: 10,
                offset: 0,
            })
            .unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].text, result.text);
        assert_eq!(
            engine
                .get_transcription_processing(rows[0].id.clone())
                .unwrap()
                .recognized_text,
            "recognized words"
        );
        assert!(engine
            .process_chunk("s".into(), vec![0.1], 16000, 1, "clean".into(), None)
            .is_err());
    }
    #[test]
    fn full_input_is_preserved_when_processing_limit_is_exceeded() {
        let (engine, _directory, _) = setup();
        engine.config.lock().unwrap().general.llm_max_words = 1;
        engine.start_session("s".into()).unwrap();
        engine
            .process_chunk("s".into(), vec![0.1; 32000], 16000, 0, "clean".into(), None)
            .unwrap();
        let result = engine
            .finish_session("s".into(), "clean".into(), None, None)
            .unwrap();
        assert_eq!(result.text, "recognized words");
        assert!(result.llm_error.unwrap().contains("word limit"));
    }
    #[test]
    fn synchronous_adapter_preserves_quiet_speech_and_rejects_invalid_audio() {
        let (engine, _directory, calls) = setup();
        let result = engine
            .transcribe(vec![0.001; 32000], 16000, "dictation".into(), None)
            .unwrap();
        assert_eq!(result.text, "recognized words");
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert!(engine
            .transcribe(vec![0.0; 16000], 16000, "dictation".into(), None)
            .is_err());
        assert!(engine
            .transcribe(vec![f32::NAN; 16000], 16000, "dictation".into(), None)
            .is_err());
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }
    #[test]
    fn empty_chunks_still_reserve_their_identity() {
        let (engine, _directory, calls) = setup();
        engine.start_session("s".into()).unwrap();
        engine
            .process_chunk("s".into(), vec![], 16000, 0, "dictation".into(), None)
            .unwrap();
        assert!(engine
            .process_chunk("s".into(), vec![0.1], 16000, 0, "dictation".into(), None)
            .is_err());
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        engine.cancel_session("s".into());
    }
}
