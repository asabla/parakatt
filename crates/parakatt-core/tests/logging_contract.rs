use parakatt_core::{engine::Engine, EngineConfig};

// Logger state is process-wide. Keep the complete lifecycle in one isolated test binary.
#[test]
fn persisted_debug_setting_controls_core_diagnostics_at_runtime() {
    parakatt_core::init_logging(Some("info".into()));
    let directory = tempfile::tempdir().unwrap();
    let config = EngineConfig {
        models_dir: directory.path().join("models").display().to_string(),
        config_dir: directory.path().display().to_string(),
        active_stt_model: None,
        active_llm_provider: None,
        active_mode: "dictation".into(),
    };
    let engine = Engine::new(config.clone()).unwrap();
    assert!(!log::log_enabled!(target: "parakatt_core::diagnostic", log::Level::Debug));
    engine.set_debug_mode(true).unwrap();
    assert!(log::log_enabled!(target: "parakatt_core::diagnostic", log::Level::Debug));
    assert!(!log::log_enabled!(target: "reqwest::body", log::Level::Debug));
    drop(engine);
    let engine = Engine::new(config).unwrap();
    assert!(engine.get_debug_mode().unwrap());
    assert!(log::log_enabled!(target: "parakatt_core::diagnostic", log::Level::Debug));
    engine.save_profile("diagnostics".into()).unwrap();
    engine.set_debug_mode(false).unwrap();
    assert!(!log::log_enabled!(target: "parakatt_core::diagnostic", log::Level::Debug));
    engine.load_profile("diagnostics".into()).unwrap();
    assert!(engine.get_debug_mode().unwrap());
    assert!(log::log_enabled!(target: "parakatt_core::diagnostic", log::Level::Debug));
    engine.set_debug_mode(false).unwrap();
    let file = directory.path().join("config.toml");
    std::fs::remove_file(&file).unwrap();
    std::fs::create_dir(&file).unwrap();
    assert!(engine.set_debug_mode(true).is_err());
    assert!(!engine.get_debug_mode().unwrap());
    assert!(!log::log_enabled!(target: "parakatt_core::diagnostic", log::Level::Debug));
}
