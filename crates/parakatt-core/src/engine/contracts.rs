//! Regression tests for configuration and session persistence contracts.
use super::*;

fn engine(path: &std::path::Path) -> Arc<Engine> {
    Arc::new(
        Engine::new(EngineConfig {
            config_dir: path.display().to_string(),
            models_dir: path.join("models").display().to_string(),
            active_mode: String::new(),
            active_stt_model: None,
            active_llm_provider: None,
        })
        .unwrap(),
    )
}
fn custom_mode() -> ModeConfig {
    ModeConfig {
        name: "Custom".into(),
        stt_provider: None,
        llm_provider: None,
        system_prompt: None,
        dictionary_enabled: true,
    }
}
fn retain_audio(engine: &Engine) {
    engine.set_recovery_audio(true).unwrap();
    engine
        .begin_capture("capture".into(), "push_to_talk".into(), "dictation".into())
        .unwrap();
    engine
        .append_capture_audio("capture".into(), ChunkSource::Mixed, vec![0.1; 1600])
        .unwrap();
    engine.end_capture("capture".into());
}
fn audio_available(engine: &Engine) -> bool {
    engine
        .list_recording_drafts()
        .unwrap()
        .first()
        .unwrap()
        .audio_available
}

#[test]
fn every_setting_save_failure_preserves_runtime_configuration() {
    type Change = fn(&Engine) -> Result<(), CoreError>;
    let changes: &[(&str, Change)] = &[
        ("auto paste", |e| e.set_auto_paste(false)),
        ("overlay", |e| e.set_show_overlay(false)),
        ("preview", |e| e.set_streaming_preview_enabled(false)),
        ("speakers", |e| e.set_speaker_labels_enabled(true)),
        ("audio source", |e| {
            e.set_preferred_audio_source(Some("test.editor".into()))
        }),
        ("chunk duration", |e| e.set_chunk_duration(60)),
        ("word limit", |e| e.set_llm_max_words(500)),
        ("debug", |e| e.set_debug_mode(true)),
        ("retention", |e| e.set_retention_days(7)),
        ("context", |e| e.set_llm_context_enabled(true)),
        ("recovery", |e| e.set_recovery_audio(true)),
        ("active mode", |e| e.set_active_mode("clean".into())),
        ("add mode", |e| {
            e.save_mode(ModeConfig {
                name: "Other".into(),
                ..custom_mode()
            })
        }),
        ("delete mode", |e| e.delete_mode("Custom".into())),
        ("app mode", |e| {
            e.set_app_mode_default("test.editor".into(), "clean".into())
        }),
        ("hotkey", |e| {
            e.set_hotkey_config(HotkeyConfig {
                key: "r".into(),
                modifiers: vec!["command".into()],
                mode: "toggle".into(),
            })
        }),
        ("generation", |e| {
            e.set_generation_settings(crate::llm::GenerationSettings {
                output_limit: 1024,
                ..Default::default()
            })
        }),
        ("provider", |e| {
            e.configure_llm(
                "ollama".into(),
                "http://127.0.0.1:11434".into(),
                "fixture".into(),
                None,
            )
        }),
        ("dictionary", |e| {
            e.set_dictionary_rules(vec![ReplacementRule {
                pattern: "word".into(),
                replacement: "Word".into(),
                context_type: "always".into(),
                context_value: None,
                enabled: true,
            }])
        }),
    ];
    for (name, change) in changes {
        let dir = tempfile::tempdir().unwrap();
        let e = engine(dir.path());
        e.save_mode(custom_mode()).unwrap();
        let before = serde_json::to_value(e.config.lock().unwrap().clone()).unwrap();
        let file = dir.path().join("config.toml");
        std::fs::remove_file(&file).unwrap();
        std::fs::create_dir(&file).unwrap();
        assert!(change(&e).is_err(), "{name}");
        let after = serde_json::to_value(e.config.lock().unwrap().clone()).unwrap();
        assert_eq!(before, after, "{name}");
        assert!(e.llm.lock().unwrap().is_none(), "{name}");
    }
}

#[test]
fn profile_and_recovery_switch_share_audio_cleanup_and_failure_semantics() {
    let dir = tempfile::tempdir().unwrap();
    let e = engine(dir.path());
    e.save_profile("private".into()).unwrap();
    retain_audio(&e);
    assert!(audio_available(&e));
    let file = dir.path().join("config.toml");
    std::fs::remove_file(&file).unwrap();
    std::fs::create_dir(&file).unwrap();
    assert!(e.load_profile("private".into()).is_err());
    assert!(e.get_recovery_audio());
    assert!(audio_available(&e));
    assert!(e.set_recovery_audio(false).is_err());
    assert!(e.get_recovery_audio());
    assert!(audio_available(&e));
    std::fs::remove_dir(&file).unwrap();
    e.load_profile("private".into()).unwrap();
    assert!(!e.get_recovery_audio());
    assert!(!audio_available(&e));
    // A late capture callback must not recreate audio after disabling recovery.
    e.append_capture_audio("capture".into(), ChunkSource::Mixed, vec![0.2; 1600])
        .unwrap();
    assert!(!audio_available(&e));
    drop(e);
    let reopened = engine(dir.path());
    assert!(!reopened.get_recovery_audio());
    assert!(!audio_available(&reopened));
}

#[test]
fn audio_cleanup_failure_keeps_the_old_profile_and_settings_file() {
    let dir = tempfile::tempdir().unwrap();
    let e = engine(dir.path());
    e.save_profile("private".into()).unwrap();
    retain_audio(&e);
    e.storage.lock().unwrap().conn.execute_batch("CREATE TRIGGER fail_audio_cleanup BEFORE UPDATE ON capture_blocks BEGIN SELECT RAISE(ABORT,'fixture'); END;").unwrap();
    assert!(e.load_profile("private".into()).is_err());
    assert!(e.get_recovery_audio());
    assert!(audio_available(&e));
    assert!(Config::load(dir.path()).unwrap().general.recovery_audio);
}

#[test]
fn deleting_a_mode_repairs_all_references_and_persists_the_repair() {
    let dir = tempfile::tempdir().unwrap();
    let e = engine(dir.path());
    e.save_mode(custom_mode()).unwrap();
    e.set_active_mode("custom".into()).unwrap();
    e.set_app_mode_default("test.editor".into(), "CUSTOM".into())
        .unwrap();
    e.delete_mode("custom".into()).unwrap();
    assert_eq!(e.get_active_mode(), "dictation");
    assert!(e.get_app_mode_defaults().unwrap().is_empty());
    assert_eq!(
        e.resolve_mode_for_app(Some("test.editor".into())).unwrap(),
        "dictation"
    );
    assert!(e
        .set_app_mode_default("test.editor".into(), "missing".into())
        .is_err());
    assert_eq!(
        e.dictionary_text("words", "dictation", &AppContext::default())
            .unwrap(),
        "words"
    );
    drop(e);
    let e = engine(dir.path());
    assert_eq!(e.get_active_mode(), "dictation");
    assert!(e.get_app_mode_defaults().unwrap().is_empty());
}

struct Speech;
impl SttProvider for Speech {
    fn name(&self) -> &str {
        "fixture"
    }
    fn is_loaded(&self) -> bool {
        true
    }
    fn transcribe(&self, audio: &[f32], rate: u32) -> Result<TranscriptionResult, CoreError> {
        Ok(TranscriptionResult {
            text: "Recognized words".into(),
            duration_secs: audio.len() as f64 / f64::from(rate),
            provider_name: "fixture".into(),
            segments: vec![],
            llm_error: None,
        })
    }
}
fn wait_for_processing_finish(session: &crate::processing::ProcessingSession) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        if session
            .events()
            .iter()
            .any(|v| matches!(v.state, crate::processing::ProcessingState::Finished))
        {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "processing did not finish"
        );
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
}
#[test]
fn cancellation_before_commit_preserves_recovery_without_saving_history() {
    let dir = tempfile::tempdir().unwrap();
    let e = engine(dir.path());
    *e.stt.lock().unwrap() = Some(Box::new(Speech));
    e.start_session("commit-race".into()).unwrap();
    e.process_chunk(
        "commit-race".into(),
        vec![0.1; 16000],
        16000,
        0,
        "dictation".into(),
        None,
    )
    .unwrap();
    let session = e.processing_session("commit-race").unwrap();
    let storage = e.storage.lock().unwrap();
    let worker = e.clone();
    let finishing = std::thread::spawn(move || {
        worker.finish_session(
            "commit-race".into(),
            "dictation".into(),
            None,
            Some("meeting".into()),
        )
    });
    wait_for_processing_finish(&session);
    e.cancel_session("commit-race".into());
    drop(storage);
    assert!(finishing.join().unwrap().is_err());
    assert!(e.get_transcription("commit-race".into()).is_err());
    assert_eq!(
        e.list_recording_drafts()
            .unwrap()
            .first()
            .unwrap()
            .recognized_text,
        "Recognized words"
    );
}

#[test]
fn a_failed_final_write_rolls_back_history_and_keeps_the_recovery_draft() {
    let dir = tempfile::tempdir().unwrap();
    let e = engine(dir.path());
    *e.stt.lock().unwrap() = Some(Box::new(Speech));
    e.start_session("write-failure".into()).unwrap();
    e.process_chunk(
        "write-failure".into(),
        vec![0.1; 16000],
        16000,
        0,
        "dictation".into(),
        None,
    )
    .unwrap();
    e.storage.lock().unwrap().conn.execute_batch("CREATE TRIGGER fail_sections BEFORE INSERT ON transcription_sections BEGIN SELECT RAISE(ABORT,'fixture'); END;").unwrap();
    assert!(e
        .finish_session(
            "write-failure".into(),
            "dictation".into(),
            None,
            Some("meeting".into())
        )
        .is_err());
    assert!(e.get_transcription("write-failure".into()).is_err());
    e.cancel_session("write-failure".into());
    assert_eq!(
        e.list_recording_drafts()
            .unwrap()
            .first()
            .unwrap()
            .recognized_text,
        "Recognized words"
    );
}

#[test]
fn cancelling_a_history_retry_before_commit_keeps_the_saved_result() {
    struct Delayed {
        entered: std::sync::mpsc::SyncSender<()>,
        release: Mutex<std::sync::mpsc::Receiver<()>>,
    }
    impl LlmProvider for Delayed {
        fn name(&self) -> &str {
            "fixture"
        }
        fn is_available(&self) -> bool {
            true
        }
        fn process(&self, _: &LlmRequest) -> Result<String, CoreError> {
            self.entered.send(()).unwrap();
            self.release
                .lock()
                .unwrap()
                .recv_timeout(std::time::Duration::from_secs(5))
                .unwrap();
            Ok("Late generated result".into())
        }
    }
    let dir = tempfile::tempdir().unwrap();
    let e = engine(dir.path());
    e.save_transcription(StoredTranscription {
        id: "retry-cancel".into(),
        created_at: "2026-11-05T00:00:00Z".into(),
        duration_secs: 1.0,
        source: "meeting".into(),
        mode: "clean".into(),
        audio_source: None,
        app_context: None,
        title: None,
        text: "Saved words".into(),
    })
    .unwrap();
    {
        let storage = e.storage.lock().unwrap();
        storage
            .save_processing(
                "retry-cancel",
                &crate::processing::ProcessingSummary {
                    recognized_text: "Saved words".into(),
                    status: "degraded".into(),
                },
            )
            .unwrap();
        storage
            .save_sections(
                "retry-cancel",
                &[crate::recovery::HistorySection {
                    chunk_id: 0,
                    source: ChunkSource::Mixed,
                    recognized_text: "Saved words".into(),
                    text: "Saved words".into(),
                    status: "failed".into(),
                    error: Some("fixture".into()),
                }],
            )
            .unwrap();
    }
    let (started, entered) = std::sync::mpsc::sync_channel(1);
    let (release, waiting) = std::sync::mpsc::channel();
    *e.llm.lock().unwrap() = Some(Arc::new(Delayed {
        entered: started,
        release: Mutex::new(waiting),
    }));
    let worker = e.clone();
    let retry = std::thread::spawn(move || worker.retry_history_processing("retry-cancel".into()));
    entered
        .recv_timeout(std::time::Duration::from_secs(5))
        .unwrap();
    let storage = e.storage.lock().unwrap();
    release.send(()).unwrap();
    let session = e.processing_session("history:retry-cancel").unwrap();
    wait_for_processing_finish(&session);
    e.cancel_history_processing("retry-cancel".into());
    drop(storage);
    assert!(retry.join().unwrap().is_err());
    assert_eq!(
        e.get_transcription("retry-cancel".into()).unwrap().text,
        "Saved words"
    );
    assert_eq!(
        e.get_transcription_processing("retry-cancel".into())
            .unwrap()
            .status,
        "degraded"
    );
}

#[test]
fn import_attachment_validation_checks_each_identity_field_independently() {
    let dir = tempfile::tempdir().unwrap();
    let e = engine(dir.path());
    *e.stt.lock().unwrap() = Some(Box::new(Speech));
    let job = e
        .create_import_job(
            "file".into(),
            "/fixture.mp4".into(),
            "Fixture".into(),
            "dictation".into(),
        )
        .unwrap();
    let mut attachment = job.attachment;
    // Zero is valid before media probing, but negative and non-finite values are never valid.
    e.attach_import_media(job.id.clone(), attachment.clone())
        .unwrap();
    for invalid in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, -1.0] {
        let mut changed = attachment.clone();
        changed.duration_secs = invalid;
        assert!(
            e.attach_import_media(job.id.clone(), changed).is_err(),
            "{invalid}"
        );
    }
    attachment.duration_secs = 2.0;
    attachment.fingerprint = "fixture".into();
    attachment.path = "/fixture.mp4".into();
    e.attach_import_media(job.id.clone(), attachment.clone())
        .unwrap();
    e.set_import_state(job.id.clone(), "transcribing".into(), String::new())
        .unwrap();
    e.process_import_chunk(job.id.clone(), vec![0.1; 16000], 0.0)
        .unwrap();
    for field in ["fingerprint", "track", "duration"] {
        let mut changed = attachment.clone();
        match field {
            "fingerprint" => changed.fingerprint = "different".into(),
            "track" => changed.audio_track = 1,
            _ => changed.duration_secs = 3.0,
        }
        assert!(
            e.attach_import_media(job.id.clone(), changed).is_err(),
            "{field}"
        );
        let saved = e.get_import_job(job.id.clone()).unwrap().attachment;
        assert_eq!(saved.fingerprint, attachment.fingerprint);
        assert_eq!(saved.audio_track, attachment.audio_track);
        assert_eq!(saved.duration_secs, attachment.duration_secs);
    }
    // Locating the same source again may update its path and bookmark.
    attachment.path = "/relocated.mp4".into();
    attachment.bookmark = vec![1, 2, 3];
    let saved = e.attach_import_media(job.id.clone(), attachment).unwrap();
    assert_eq!(saved.attachment.path, "/relocated.mp4");
    assert_eq!(saved.next_chunk, 1);
}

#[test]
fn failed_audio_cleanup_commit_restores_the_settings_file_and_audio() {
    let dir = tempfile::tempdir().unwrap();
    let e = engine(dir.path());
    retain_audio(&e);
    e.storage.lock().unwrap().conn.execute_batch(
        "CREATE TABLE cleanup_fixture(parent TEXT REFERENCES transcriptions(id) DEFERRABLE INITIALLY DEFERRED);
         CREATE TRIGGER fail_cleanup_commit AFTER UPDATE ON capture_blocks BEGIN INSERT INTO cleanup_fixture VALUES('missing'); END;"
    ).unwrap();
    assert!(e.set_recovery_audio(false).is_err());
    assert!(e.get_recovery_audio());
    assert!(Config::load(dir.path()).unwrap().general.recovery_audio);
    assert!(audio_available(&e));
}

#[test]
fn startup_finishes_audio_cleanup_after_an_interrupted_preference_change() {
    let dir = tempfile::tempdir().unwrap();
    let e = engine(dir.path());
    retain_audio(&e);
    let mut config = Config::load(dir.path()).unwrap();
    config.general.recovery_audio = false;
    config.save(dir.path()).unwrap();
    drop(e);
    let reopened = engine(dir.path());
    assert!(!reopened.get_recovery_audio());
    assert!(!audio_available(&reopened));
}

#[test]
fn legacy_deleted_mode_references_fall_back_to_an_available_mode() {
    let dir = tempfile::tempdir().unwrap();
    let e = engine(dir.path());
    {
        let mut config = e.config.lock().unwrap();
        config.general.active_mode = "deleted".into();
        config
            .general
            .app_mode_defaults
            .insert("test.editor".into(), "deleted".into());
    }
    assert_eq!(
        e.resolve_mode_for_app(Some("test.editor".into())).unwrap(),
        "dictation"
    );
    assert_eq!(e.resolve_mode_for_app(None).unwrap(), "dictation");
    e.set_active_mode("clean".into()).unwrap();
    assert_eq!(
        e.resolve_mode_for_app(Some("test.editor".into())).unwrap(),
        "clean"
    );
}
