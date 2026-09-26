use super::*;
use crate::media_import::{io, ImportJob, MediaAttachment};
use rusqlite::params;
use sha2::{Digest, Sha256};

impl Engine {
    fn import_configuration(&self, mode: &str) -> Result<String, CoreError> {
        let config = self.config.lock().unwrap();
        let selected = config.modes.iter().find(|m| m.name == mode);
        let bytes = serde_json::to_vec(&(
            &config.stt,
            &config.dictionary,
            selected,
            &config.llm,
            config.general.llm_context_enabled,
        ))
        .map_err(io)?;
        Ok(format!("{:x}", Sha256::digest(bytes)))
    }
}
#[uniffi::export]
impl Engine {
    pub fn create_import_job(
        &self,
        kind: String,
        input: String,
        title: String,
        mode: String,
    ) -> Result<ImportJob, CoreError> {
        if !["file", "direct", "youtube"].contains(&kind.as_str()) {
            return Err(io("Unsupported import source"));
        }
        let job = ImportJob {
            id: uuid::Uuid::new_v4().to_string(),
            kind,
            input,
            title,
            mode: mode.clone(),
            state: "queued".into(),
            message: String::new(),
            attachment: MediaAttachment {
                path: String::new(),
                bookmark: Vec::new(),
                fingerprint: String::new(),
                review_path: String::new(),
                audio_track: 0,
                duration_secs: 0.0,
            },
            next_chunk: 0,
            processed_until: 0.0,
            configuration: self.import_configuration(&mode)?,
            checkpoint_version: 1,
        };
        self.storage.lock().unwrap().create_import(&job)?;
        Ok(job)
    }
    pub fn list_import_jobs(&self) -> Result<Vec<ImportJob>, CoreError> {
        self.storage.lock().unwrap().import_jobs()
    }
    pub fn get_import_job(&self, id: String) -> Result<ImportJob, CoreError> {
        self.storage.lock().unwrap().import_job(&id)
    }
    pub fn set_import_state(
        &self,
        id: String,
        state: String,
        message: String,
    ) -> Result<ImportJob, CoreError> {
        if ![
            "queued",
            "downloading",
            "preparing",
            "transcribing",
            "paused",
            "interrupted",
            "failed",
            "completed",
        ]
        .contains(&state.as_str())
        {
            return Err(io("Invalid import state"));
        }
        let mode = self.get_import_job(id.clone())?.mode;
        let configuration = self.import_configuration(&mode)?;
        if state != "transcribing" {
            if let Some(token) = self.import_cancellation.lock().unwrap().get(&id) {
                token.cancel();
            }
        }
        let storage = self.storage.lock().unwrap();
        let mut job = storage.import_job(&id)?;
        if job.next_chunk == 0 {
            job.configuration = configuration;
        }
        if state == "completed"
            && (job.attachment.duration_secs <= 0.0
                || job.processed_until + 0.001 < job.attachment.duration_secs)
        {
            return Err(io("Import has unprocessed audio"));
        }
        job.state = state;
        job.message = message;
        let tx = storage.conn.unchecked_transaction().map_err(io)?;
        storage.write_import(&job)?;
        storage.refresh_import_text(&job)?;
        tx.commit().map_err(io)?;
        Ok(job)
    }
    pub fn attach_import_media(
        &self,
        id: String,
        attachment: MediaAttachment,
    ) -> Result<ImportJob, CoreError> {
        if !attachment.duration_secs.is_finite() || attachment.duration_secs < 0.0 {
            return Err(io("Invalid media duration"));
        }
        let storage = self.storage.lock().unwrap();
        let mut job = storage.import_job(&id)?;
        if job.next_chunk > 0
            && (attachment.fingerprint != job.attachment.fingerprint
                || attachment.audio_track != job.attachment.audio_track
                || attachment.duration_secs != job.attachment.duration_secs)
        {
            return Err(io("The source changed. Start a new import."));
        }
        job.attachment = attachment;
        storage.write_import(&job)?;
        Ok(job)
    }
    pub fn invalidate_import_source(&self, id: String) -> Result<(), CoreError> {
        let storage = self.storage.lock().unwrap();
        let mut job = storage.import_job(&id)?;
        job.checkpoint_version = 0;
        job.state = "failed".into();
        job.message = "The source changed during transcription. Start a new import.".into();
        storage.write_import(&job)?;
        storage.refresh_import_text(&job)
    }

    pub fn process_import_chunk(
        &self,
        id: String,
        samples: Vec<f32>,
        media_offset_secs: f64,
    ) -> Result<ImportJob, CoreError> {
        if samples.is_empty() || samples.len() > 480_000 || samples.iter().any(|s| !s.is_finite()) {
            return Err(io("Expected up to 30 seconds of finite 16 kHz mono audio"));
        }
        let (mut job, checkpoint) = {
            let storage = self.storage.lock().unwrap();
            (storage.import_job(&id)?, storage.import_checkpoint(&id)?)
        };
        if job.checkpoint_version != 1
            || job.configuration != self.import_configuration(&job.mode)?
        {
            return Err(io("The model or processing settings changed. Restore the previous settings or start a new import."));
        }
        let expected = if job.next_chunk == 0 {
            0.0
        } else {
            (job.processed_until - 2.0).max(0.0)
        };
        if job.state != "transcribing"
            || !media_offset_secs.is_finite()
            || (expected - media_offset_secs).abs() > 0.0001
        {
            return Err(io("Unexpected media position"));
        }
        let duration = samples.len() as f64 / 16000.0;
        if media_offset_secs + duration > job.attachment.duration_secs + 0.001
            || media_offset_secs + duration <= job.processed_until
        {
            return Err(io("Invalid media chunk duration"));
        }
        let stt_result = if samples.iter().all(|s| *s == 0.0) {
            TranscriptionResult {
                text: String::new(),
                duration_secs: duration,
                provider_name: "parakeet".into(),
                segments: vec![],
                llm_error: None,
            }
        } else {
            let stt = self.stt.lock().unwrap();
            stt.as_ref()
                .ok_or_else(|| io("Load the speech model before importing"))?
                .transcribe_import(&samples, 16000)?
        };
        let mut assembly = SessionManager::new();
        if checkpoint.is_empty() {
            assembly.start(&id)?;
        } else {
            assembly.restore_import(&id, &checkpoint)?;
        }
        let result = assembly.add_chunk_with_overlap(
            &id,
            &stt_result.text,
            duration,
            if job.next_chunk == 0 { 0.0 } else { 2.0 },
            stt_result.segments,
        )?;
        let mut segments = crate::media_import::group_import_words(result.segments);
        for segment in &mut segments {
            segment.start_secs += media_offset_secs;
            segment.end_secs += media_offset_secs;
        }
        let text = self.dictionary.lock().unwrap().apply(
            &crate::filler::remove_fillers(&result.text),
            &AppContext::default(),
            &job.mode,
        );
        let expected_chunk = job.next_chunk;
        job.next_chunk += 1;
        job.processed_until = media_offset_secs + duration;
        self.storage.lock().unwrap().commit_import_chunk(
            &job,
            expected_chunk,
            &assembly.import_checkpoint(&id)?,
            &result.text,
            &text,
            &segments,
        )?;
        Ok(job)
    }
    /// Synchronous, one section at a time: imported media applies backpressure.
    pub fn process_import_text(&self, id: String) -> Result<(), CoreError> {
        let cancellation = tokio_util::sync::CancellationToken::new();
        {
            let mut active = self.import_cancellation.lock().unwrap();
            if active.contains_key(&id) {
                return Err(io("Import processing is already active"));
            }
            active.insert(id.clone(), cancellation.clone());
        }
        struct Guard<'a>(&'a Engine, String);
        impl Drop for Guard<'_> {
            fn drop(&mut self) {
                self.0.import_cancellation.lock().unwrap().remove(&self.1);
            }
        }
        let _guard = Guard(self, id.clone());
        let (job, sections) = {
            let s = self.storage.lock().unwrap();
            (s.import_job(&id)?, s.import_sections(&id)?)
        };
        if job.configuration != self.import_configuration(&job.mode)? {
            return Err(io(
                "Processing settings changed. Restore them before resuming.",
            ));
        }
        for section in sections.iter().filter(|s| s.status == "pending") {
            let current = self.get_import_job(id.clone())?;
            if current.state != "transcribing" {
                return Ok(());
            }
            let work = self.llm_request(&section.text, &job.mode, &AppContext::default());
            let result = match work {
                Ok(Some((provider, mut request))) => {
                    if request.allow_preceding_context {
                        let prior = sections
                            .iter()
                            .filter(|s| s.chunk_id < section.chunk_id)
                            .rev()
                            .take(2)
                            .collect::<Vec<_>>();
                        let joined = prior
                            .iter()
                            .rev()
                            .map(|s| s.recognized_text.as_str())
                            .collect::<Vec<_>>()
                            .join(" ");
                        let words = joined.split_whitespace().collect::<Vec<_>>();
                        request.preceding_text =
                            Some(words[words.len().saturating_sub(120)..].join(" "));
                    }
                    provider.process_cancellable(&request, &cancellation, &|_| {})
                }
                Ok(None) => Ok(section.text.clone()),
                Err(e) => Err(e),
            };
            if cancellation.is_cancelled() {
                return Ok(());
            }
            let (text, status) = match result {
                Ok(t) if !t.trim().is_empty() => (t, "processed"),
                _ => (section.text.clone(), "failed"),
            };
            let storage = self.storage.lock().unwrap();
            let tx = storage.conn.unchecked_transaction().map_err(io)?;
            storage.conn.execute("UPDATE import_chunks SET text=?3,status=?4 WHERE id=?1 AND chunk_index=?2 AND status='pending'",params![id,section.chunk_id,text,status]).map_err(io)?;
            storage.refresh_import_text(&storage.import_job(&id)?)?;
            tx.commit().map_err(io)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Speech;
    impl SttProvider for Speech {
        fn name(&self) -> &str {
            "fixture"
        }
        fn is_loaded(&self) -> bool {
            true
        }
        fn transcribe(&self, _: &[f32], _: u32) -> Result<TranscriptionResult, CoreError> {
            Ok(TranscriptionResult {
                text: "repeat repeat next".into(),
                duration_secs: 30.0,
                provider_name: "fixture".into(),
                llm_error: None,
                segments: vec![
                    TimestampedSegment {
                        text: "repeat".into(),
                        start_secs: 0.25,
                        end_secs: 1.0,
                        speaker: None,
                    },
                    TimestampedSegment {
                        text: "next".into(),
                        start_secs: 3.0,
                        end_secs: 4.0,
                        speaker: None,
                    },
                ],
            })
        }
    }
    fn engine(dir: &std::path::Path) -> Engine {
        let engine = Engine::new(EngineConfig {
            models_dir: dir.join("models").display().to_string(),
            config_dir: dir.display().to_string(),
            active_stt_model: None,
            active_llm_provider: None,
            active_mode: "dictation".into(),
        })
        .unwrap();
        *engine.stt.lock().unwrap() = Some(Box::new(Speech));
        engine
    }
    fn job(engine: &Engine) -> ImportJob {
        let mut job = engine
            .create_import_job(
                "file".into(),
                "/fixture.mp4".into(),
                "Fixture".into(),
                "dictation".into(),
            )
            .unwrap();
        job.attachment.duration_secs = 58.0;
        job.attachment.fingerprint = "fixture".into();
        job.attachment.path = "/fixture.mp4".into();
        engine
            .attach_import_media(job.id.clone(), job.attachment.clone())
            .unwrap();
        engine
            .set_import_state(job.id.clone(), "transcribing".into(), String::new())
            .unwrap()
    }
    #[test]
    fn resumes_without_duplicate_speech_or_timestamp_shift() {
        let dir = tempfile::tempdir().unwrap();
        let first = engine(dir.path());
        let job = job(&first);
        first
            .process_import_chunk(job.id.clone(), vec![0.1; 480000], 0.0)
            .unwrap();
        drop(first);
        let second = engine(dir.path());
        let saved = second.get_import_job(job.id.clone()).unwrap();
        assert_eq!(saved.next_chunk, 1);
        assert_eq!(saved.processed_until, 30.0);
        second
            .process_import_chunk(job.id.clone(), vec![0.1; 480000], 28.0)
            .unwrap();
        second
            .set_import_state(job.id.clone(), "completed".into(), String::new())
            .unwrap();
        let storage = second.storage.lock().unwrap();
        let segments = storage.get_segments(&job.id).unwrap();
        assert_eq!(segments.len(), 3);
        assert_eq!(segments[2].start_secs, 31.0);
        assert_eq!(storage.get(&job.id).unwrap().text, "repeat next\n\nnext");
        assert!(storage.import_checkpoint(&job.id).unwrap().len() < 2048);
    }
    #[test]
    fn rejects_wrong_position_changed_source_and_incomplete_completion() {
        let dir = tempfile::tempdir().unwrap();
        let engine = engine(dir.path());
        let mut job = job(&engine);
        assert!(engine
            .process_import_chunk(job.id.clone(), vec![0.1; 480000], 28.0)
            .is_err());
        assert!(engine
            .set_import_state(job.id.clone(), "completed".into(), String::new())
            .is_err());
        engine
            .process_import_chunk(job.id.clone(), vec![0.1; 480000], 0.0)
            .unwrap();
        job.attachment.fingerprint = "changed".into();
        assert!(engine
            .attach_import_media(job.id.clone(), job.attachment)
            .is_err());
        assert!(engine
            .process_import_chunk(job.id.clone(), vec![0.1; 480000], 0.0)
            .is_err());
        engine
            .set_import_state(job.id.clone(), "paused".into(), String::new())
            .unwrap();
        assert!(engine
            .process_import_chunk(job.id.clone(), vec![0.1; 480000], 28.0)
            .is_err());
    }
    #[test]
    fn failed_transaction_does_not_advance_checkpoint() {
        let dir = tempfile::tempdir().unwrap();
        let engine = engine(dir.path());
        let job = job(&engine);
        engine.storage.lock().unwrap().conn.execute_batch("CREATE TRIGGER fail_import BEFORE INSERT ON transcript_segments BEGIN SELECT RAISE(ABORT,'simulated disk failure'); END;").unwrap();
        assert!(engine
            .process_import_chunk(job.id.clone(), vec![0.1; 480000], 0.0)
            .is_err());
        assert_eq!(engine.get_import_job(job.id.clone()).unwrap().next_chunk, 0);
        assert!(engine
            .storage
            .lock()
            .unwrap()
            .import_sections(&job.id)
            .unwrap()
            .is_empty());
        engine
            .storage
            .lock()
            .unwrap()
            .conn
            .execute_batch("DROP TRIGGER fail_import")
            .unwrap();
        engine
            .process_import_chunk(job.id.clone(), vec![0.1; 480000], 0.0)
            .unwrap();
        assert_eq!(engine.get_import_job(job.id).unwrap().next_chunk, 1);
    }
    #[test]
    fn silent_final_audio_is_committed_and_delete_cascades() {
        let dir = tempfile::tempdir().unwrap();
        let engine = engine(dir.path());
        let job = job(&engine);
        engine
            .process_import_chunk(job.id.clone(), vec![0.0; 480000], 0.0)
            .unwrap();
        engine
            .process_import_chunk(job.id.clone(), vec![0.0; 480000], 28.0)
            .unwrap();
        engine
            .set_import_state(job.id.clone(), "completed".into(), String::new())
            .unwrap();
        let storage = engine.storage.lock().unwrap();
        assert!(storage.get(&job.id).unwrap().text.is_empty());
        storage.delete(&job.id).unwrap();
        assert!(storage.import_jobs().unwrap().is_empty());
    }
}
