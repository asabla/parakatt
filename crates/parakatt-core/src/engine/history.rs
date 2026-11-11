//! Recovery and history operations, separate from the live speech pipeline.
use super::*;

struct HistoryProcessingGuard<'a> {
    engine: &'a Engine,
    id: String,
}
impl Drop for HistoryProcessingGuard<'_> {
    fn drop(&mut self) {
        if let Some(session) = (match crate::util::lock_named(
            &self.engine.processing,
            "processing",
            CoreError::TranscriptionFailed,
        ) {
            Ok(guard) => guard,
            Err(_error) => return,
        })
        .remove(&self.id)
        {
            session.cancel();
        }
    }
}

#[uniffi::export]
impl Engine {
    pub fn begin_capture(&self, id: String, source: String, mode: String) -> Result<(), CoreError> {
        let mut capturing =
            crate::util::lock_named(&self.capturing, "capturing", CoreError::TranscriptionFailed)?;
        if capturing.contains(&id) {
            return Err(CoreError::AudioError("Capture is already active".into()));
        }
        crate::util::lock_named(&self.storage, "storage", CoreError::IoError)?
            .begin_capture(&id, &source, &mode)?;
        capturing.insert(id);
        Ok(())
    }
    pub fn end_capture(&self, id: String) {
        if let Ok(mut capturing) =
            crate::util::lock_named(&self.capturing, "capturing", CoreError::TranscriptionFailed)
        {
            capturing.remove(&id);
        }
    }
    pub fn append_capture_audio(
        &self,
        id: String,
        source: ChunkSource,
        samples: Vec<f32>,
    ) -> Result<(), CoreError> {
        let config = crate::util::lock_named(&self.config, "Config", CoreError::ConfigError)?;
        if config.general.recovery_audio {
            crate::util::lock_named(&self.storage, "storage", CoreError::IoError)?
                .append_capture(&id, source, &samples)?;
        }
        Ok(())
    }
    pub fn mark_capture_gap(&self, id: String, audio_lost: bool) -> Result<(), CoreError> {
        crate::util::lock_named(&self.storage, "storage", CoreError::IoError)?
            .capture_gap(&id, audio_lost)
    }
    pub fn get_recovery_audio(&self) -> bool {
        (match crate::util::lock_named(&self.config, "config", CoreError::ConfigError) {
            Ok(guard) => guard,
            Err(_error) => return Default::default(),
        })
        .general
        .recovery_audio
    }
    pub fn set_recovery_audio(&self, enabled: bool) -> Result<(), CoreError> {
        self.update_config(|config| {
            config.general.recovery_audio = enabled;
            Ok(())
        })
    }
    pub fn list_recording_drafts(&self) -> Result<Vec<crate::recovery::RecordingDraft>, CoreError> {
        let capturing =
            crate::util::lock_named(&self.capturing, "capturing", CoreError::TranscriptionFailed)?;
        let active = crate::util::lock_named(
            &self.processing,
            "processing",
            CoreError::TranscriptionFailed,
        )?;
        Ok(
            crate::util::lock_named(&self.storage, "storage", CoreError::IoError)?
                .recording_drafts()?
                .into_iter()
                .filter(|d| {
                    d.chunk_count > 0 && !active.contains_key(&d.id) && !capturing.contains(&d.id)
                })
                .collect(),
        )
    }
    pub fn discard_recording_draft(&self, id: String) -> Result<(), CoreError> {
        if crate::util::lock_named(&self.capturing, "capturing", CoreError::TranscriptionFailed)?
            .contains(&id)
            || crate::util::lock_named(
                &self.processing,
                "processing",
                CoreError::TranscriptionFailed,
            )?
            .contains_key(&id)
        {
            return Err(CoreError::TranscriptionFailed("Recording is active".into()));
        }
        crate::util::lock_named(&self.storage, "storage", CoreError::IoError)?.discard_draft(&id)
    }
    pub fn start_recording(
        &self,
        session_id: String,
        source: String,
        mode: String,
    ) -> Result<(), CoreError> {
        let enabled = crate::util::lock_named(&self.config, "config", CoreError::ConfigError)?
            .general
            .dictation_punctuation_enabled;
        self.start_recording_with_punctuation(session_id, source, mode, enabled)
    }
    /// An explicit recording-start snapshot, including delayed push-to-talk sessions.
    pub fn start_recording_with_punctuation(
        &self,
        session_id: String,
        source: String,
        mode: String,
        dictation_punctuation_enabled: bool,
    ) -> Result<(), CoreError> {
        self.start_session_with_punctuation(session_id.clone(), dictation_punctuation_enabled)?;
        let result = crate::util::lock_named(&self.storage, "storage", CoreError::IoError)?
            .update_draft(&session_id, &source, &mode);
        if result.is_err() {
            self.cancel_session(session_id);
        }
        result
    }
    pub fn get_history_sections(
        &self,
        id: String,
    ) -> Result<Vec<crate::recovery::HistorySection>, CoreError> {
        crate::util::lock_named(&self.storage, "storage", CoreError::IoError)?.history_sections(&id)
    }
    pub fn edit_transcription(&self, id: String, text: String) -> Result<(), CoreError> {
        crate::util::lock_named(&self.storage, "storage", CoreError::IoError)?
            .edit_transcription(&id, &text)
    }
    pub fn undo_transcription_edit(&self, id: String) -> Result<(), CoreError> {
        crate::util::lock_named(&self.storage, "storage", CoreError::IoError)?
            .undo_transcription_edit(&id)
    }
    pub fn cancel_history_processing(&self, id: String) {
        if let Some(session) = (match crate::util::lock_named(
            &self.processing,
            "processing",
            CoreError::TranscriptionFailed,
        ) {
            Ok(guard) => guard,
            Err(_error) => return,
        })
        .get(&format!("history:{id}"))
        {
            session.cancel();
        }
    }
    pub fn retry_history_processing(&self, id: String) -> Result<(), CoreError> {
        let (item, summary, mut sections, revision) = {
            let storage = crate::util::lock_named(&self.storage, "storage", CoreError::IoError)?;
            (
                storage.get(&id)?,
                storage.get_processing(&id)?,
                storage.history_sections(&id)?,
                storage.history_revision(&id)?,
            )
        };
        if sections.is_empty() {
            sections.push(crate::recovery::HistorySection {
                chunk_id: 0,
                source: ChunkSource::Mixed,
                recognized_text: summary.recognized_text.clone(),
                text: item.text.clone(),
                status: "failed".into(),
                error: None,
            });
        }
        let context = match item.app_context.as_deref() {
            Some(value) => serde_json::from_str::<AppContext>(value).map_err(|_| {
                CoreError::ConfigError("The saved application context is invalid".into())
            })?,
            None => AppContext::default(),
        };
        // Work on a private session; cancellation/queue behavior matches live processing.
        let job_id = format!("history:{id}");
        let punctuation_enabled = self.get_dictation_punctuation_enabled();
        let session = {
            let mut active = crate::util::lock_named(
                &self.processing,
                "processing",
                CoreError::TranscriptionFailed,
            )?;
            if active.contains_key(&job_id) {
                return Err(CoreError::LlmError(
                    "History processing is already running".into(),
                ));
            }
            let session = crate::processing::ProcessingSession::with_dictation_punctuation(
                job_id.clone(),
                punctuation_enabled,
            );
            active.insert(job_id.clone(), session.clone());
            session
        };
        let _registration = HistoryProcessingGuard {
            engine: self,
            id: job_id,
        };
        for section in &sections {
            let input = if section.status == "failed" {
                self.dictionary_text(&section.recognized_text, &item.mode, &context)?
            } else {
                section.text.clone()
            };
            let work = if section.status == "failed" {
                match self.llm_request(&input, &item.mode, &context, punctuation_enabled) {
                    Ok(Some(work)) => Some(work),
                    Ok(None) => {
                        session.cancel();
                        return Err(CoreError::LlmError(
                            "Select an LLM provider and a processing mode before retrying".into(),
                        ));
                    }
                    Err(e) => {
                        session.cancel();
                        return Err(e);
                    }
                }
            } else {
                None
            };
            session.enqueue_with_policy(
                section.chunk_id,
                section.source,
                input,
                work,
                None,
                crate::punctuation::OutputPolicy::for_mode(&item.mode),
            )?;
            session.wait_idle()?;
        }
        let (text, _, error) = session.finish()?;
        let retried = session.sections();
        for section in &mut sections {
            if section.status == "failed" {
                if let Some(updated) = retried
                    .iter()
                    .find(|v| v.chunk_id == section.chunk_id && v.source == section.source)
                {
                    section.text = updated.text.clone();
                    section.status = updated.status.clone();
                    section.error = updated.error.clone();
                }
            }
        }
        let summary = crate::processing::ProcessingSummary {
            recognized_text: summary.recognized_text,
            status: if sections.iter().any(|s| s.status == "speech_failed") {
                "incomplete"
            } else if error.is_some() {
                "degraded"
            } else {
                "completed"
            }
            .into(),
        };
        {
            let storage = crate::util::lock_named(&self.storage, "storage", CoreError::IoError)?;
            session.commit(|| {
                storage.apply_history_processing(&id, &revision, &text, &summary, &sections)
            })?;
        }
        if error.is_some() {
            return Err(CoreError::LlmError(
                "Some sections could not be processed. Recognized text was kept.".into(),
            ));
        }
        Ok(())
    }
    pub fn recover_recording(&self, id: String, transcribe_audio: bool) -> Result<(), CoreError> {
        if crate::util::lock_named(&self.capturing, "capturing", CoreError::TranscriptionFailed)?
            .contains(&id)
            || crate::util::lock_named(
                &self.processing,
                "processing",
                CoreError::TranscriptionFailed,
            )?
            .contains_key(&id)
        {
            return Err(CoreError::TranscriptionFailed("Recording is active".into()));
        }
        let draft = crate::util::lock_named(&self.storage, "storage", CoreError::IoError)?
            .recording_drafts()?
            .into_iter()
            .find(|d| d.id == id)
            .ok_or_else(|| CoreError::IoError("Recovery record not found".into()))?;
        if !transcribe_audio {
            crate::util::lock_named(&self.storage, "storage", CoreError::IoError)?
                .save_recovered_text(&draft)?;
            return Ok(());
        }
        if !draft.audio_available {
            return Err(CoreError::AudioError(
                "Recovery audio is disabled or has expired. Save the recognized text instead."
                    .into(),
            ));
        }
        // Commit the previous recognized text before replay changes chunk boundaries.
        // A failed replay or a process exit must not remove the only text copy.
        crate::util::lock_named(&self.storage, "storage", CoreError::IoError)?
            .preserve_recovered_text(&draft)?;
        let keys = crate::util::lock_named(&self.storage, "storage", CoreError::IoError)?
            .draft_keys(&id)?;
        let captures = crate::util::lock_named(&self.storage, "storage", CoreError::IoError)?
            .capture_sources(&id)?;
        self.start_session(id.clone())?;
        let recovered = (|| {
            if !captures.is_empty() {
                crate::util::lock_named(&self.storage, "storage", CoreError::IoError)?
                    .reset_for_capture_replay(&id)?;
                let total = captures.iter().map(|(_, n)| *n).max().unwrap_or(0);
                let mut start = 0;
                let mut index = 0;
                while start < total {
                    let count = usize::try_from((total - start).min(30 * 16000))
                        .map_err(crate::media_import::io)?;
                    for &(source, _) in &captures {
                        let mut samples =
                            crate::util::lock_named(&self.storage, "storage", CoreError::IoError)?
                                .capture_slice(&id, source, start, count)?;
                        samples.resize(count, 0.0);
                        let source = match source {
                            1 => ChunkSource::Mic,
                            2 => ChunkSource::System,
                            _ => ChunkSource::Mixed,
                        };
                        self.process_source_chunk(
                            id.clone(),
                            source,
                            index,
                            samples,
                            16000,
                            if index == 0 { 0.0 } else { 2.0 },
                            draft.mode.clone(),
                            None,
                        )?;
                    }
                    if start + i64::try_from(count).map_err(crate::media_import::io)? >= total {
                        break;
                    }
                    start += 28 * 16000;
                    index += 1;
                }
            } else {
                for (index, source) in keys {
                    let chunk =
                        crate::util::lock_named(&self.storage, "storage", CoreError::IoError)?
                            .recovery_chunk(&id, index, source)?;
                    let samples = chunk.samples.ok_or_else(|| {
                        CoreError::AudioError("Recovery audio has expired".into())
                    })?;
                    self.process_source_chunk(
                        id.clone(),
                        chunk.source,
                        chunk.index,
                        samples,
                        chunk.sample_rate,
                        chunk.overlap,
                        draft.mode.clone(),
                        None,
                    )?;
                }
            }
            self.finish_session(id.clone(), draft.mode, None, Some(draft.source))?;
            Ok(())
        })();
        if recovered.is_err() {
            self.cancel_session(id);
        }
        recovered
    }
}
