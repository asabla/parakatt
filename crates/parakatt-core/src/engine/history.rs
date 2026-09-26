//! Recovery and history operations, separate from the live speech pipeline.
use super::*;

struct HistoryProcessingGuard<'a> {
    engine: &'a Engine,
    id: String,
}
impl Drop for HistoryProcessingGuard<'_> {
    fn drop(&mut self) {
        if let Some(session) = self.engine.processing.lock().unwrap().remove(&self.id) {
            session.cancel();
        }
    }
}

#[uniffi::export]
impl Engine {
    pub fn get_recovery_audio(&self) -> bool {
        self.config.lock().unwrap().general.recovery_audio
    }
    pub fn set_recovery_audio(&self, enabled: bool) -> Result<(), CoreError> {
        let mut config = self.config.lock().unwrap();
        config.general.recovery_audio = enabled;
        config.save(&self.config_dir)?;
        if !enabled {
            self.storage.lock().unwrap().clear_recovery_audio()?;
        }
        Ok(())
    }
    pub fn list_recording_drafts(&self) -> Result<Vec<crate::recovery::RecordingDraft>, CoreError> {
        let active = self.processing.lock().unwrap();
        Ok(self
            .storage
            .lock()
            .unwrap()
            .recording_drafts()?
            .into_iter()
            .filter(|d| d.chunk_count > 0 && !active.contains_key(&d.id))
            .collect())
    }
    pub fn discard_recording_draft(&self, id: String) -> Result<(), CoreError> {
        if self.processing.lock().unwrap().contains_key(&id) {
            return Err(CoreError::TranscriptionFailed("Recording is active".into()));
        }
        self.storage.lock().unwrap().discard_draft(&id)
    }
    pub fn start_recording(
        &self,
        session_id: String,
        source: String,
        mode: String,
    ) -> Result<(), CoreError> {
        self.start_session(session_id.clone())?;
        let result = self
            .storage
            .lock()
            .unwrap()
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
        self.storage.lock().unwrap().history_sections(&id)
    }
    pub fn edit_transcription(&self, id: String, text: String) -> Result<(), CoreError> {
        self.storage.lock().unwrap().edit_transcription(&id, &text)
    }
    pub fn undo_transcription_edit(&self, id: String) -> Result<(), CoreError> {
        self.storage.lock().unwrap().undo_transcription_edit(&id)
    }
    pub fn cancel_history_processing(&self, id: String) {
        if let Some(session) = self
            .processing
            .lock()
            .unwrap()
            .get(&format!("history:{id}"))
        {
            session.cancel();
        }
    }
    pub fn retry_history_processing(&self, id: String) -> Result<(), CoreError> {
        let (item, summary, mut sections) = {
            let storage = self.storage.lock().unwrap();
            (
                storage.get(&id)?,
                storage.get_processing(&id)?,
                storage.history_sections(&id)?,
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
        // Work on a private session; cancellation/queue behavior matches live processing.
        let job_id = format!("history:{id}");
        let session = {
            let mut active = self.processing.lock().unwrap();
            if active.contains_key(&job_id) {
                return Err(CoreError::LlmError(
                    "History processing is already running".into(),
                ));
            }
            let session = crate::processing::ProcessingSession::new(job_id.clone());
            active.insert(job_id.clone(), session.clone());
            session
        };
        let _registration = HistoryProcessingGuard {
            engine: self,
            id: job_id,
        };
        for section in &sections {
            let work = if section.status == "failed" {
                match self.llm_request(&section.recognized_text, &item.mode, &AppContext::default())
                {
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
            session.enqueue(
                section.chunk_id,
                section.source,
                if work.is_some() {
                    section.recognized_text.clone()
                } else {
                    section.text.clone()
                },
                work,
                None,
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
        self.storage
            .lock()
            .unwrap()
            .apply_history_processing(&id, &text, &summary, &sections)?;
        if error.is_some() {
            return Err(CoreError::LlmError(
                "Some sections could not be processed. Recognized text was kept.".into(),
            ));
        }
        Ok(())
    }
    pub fn recover_recording(&self, id: String, transcribe_audio: bool) -> Result<(), CoreError> {
        if self.processing.lock().unwrap().contains_key(&id) {
            return Err(CoreError::TranscriptionFailed("Recording is active".into()));
        }
        let draft = self
            .storage
            .lock()
            .unwrap()
            .recording_drafts()?
            .into_iter()
            .find(|d| d.id == id)
            .ok_or_else(|| CoreError::IoError("Recovery record not found".into()))?;
        if !transcribe_audio {
            self.storage.lock().unwrap().save_recovered_text(&draft)?;
            return Ok(());
        }
        if !draft.audio_available {
            return Err(CoreError::AudioError(
                "Recovery audio is disabled or has expired. Save the recognized text instead."
                    .into(),
            ));
        }
        let keys = self.storage.lock().unwrap().draft_keys(&id)?;
        self.start_session(id.clone())?;
        let recovered = (|| {
            for (index, source) in keys {
                let chunk = self
                    .storage
                    .lock()
                    .unwrap()
                    .recovery_chunk(&id, index, source)?;
                let samples = chunk
                    .samples
                    .ok_or_else(|| CoreError::AudioError("Recovery audio has expired".into()))?;
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
            self.finish_session(id.clone(), draft.mode, None, Some(draft.source))?;
            Ok(())
        })();
        if recovered.is_err() {
            self.cancel_session(id);
        }
        recovered
    }
}
