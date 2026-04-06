/// Integration tests for the Parakatt engine.
use parakatt_core::engine::Engine;
use parakatt_core::*;
use std::path::PathBuf;

fn models_dir() -> PathBuf {
    dirs::data_dir()
        .expect("Could not find data directory")
        .join("Parakatt/models")
}

fn config_dir() -> PathBuf {
    let dir = std::env::temp_dir().join("parakatt-test-config");
    std::fs::create_dir_all(&dir).ok();
    dir
}

fn has_parakeet_model() -> bool {
    let dir = models_dir().join("parakeet-tdt-0.6b-v3");
    dir.exists() && dir.join("tokenizer.json").exists()
}

#[test]
fn test_engine_creation_without_model() {
    let config = EngineConfig {
        models_dir: std::env::temp_dir()
            .join("parakatt-test-empty-models")
            .to_string_lossy()
            .to_string(),
        config_dir: config_dir().to_string_lossy().to_string(),
        active_stt_model: None,
        active_llm_provider: None,
        active_mode: "dictation".to_string(),
    };

    let engine = Engine::new(config).expect("Engine should initialize without model");
    assert!(!engine.is_model_loaded());

    let modes = engine.list_modes();
    assert!(modes.len() >= 4);
    assert!(modes.iter().any(|m| m.name == "dictation"));
}

#[test]
fn test_dictionary_integration() {
    let config = EngineConfig {
        models_dir: std::env::temp_dir()
            .join("parakatt-test-models2")
            .to_string_lossy()
            .to_string(),
        config_dir: std::env::temp_dir()
            .join("parakatt-test-config2")
            .to_string_lossy()
            .to_string(),
        active_stt_model: None,
        active_llm_provider: None,
        active_mode: "dictation".to_string(),
    };

    let engine = Engine::new(config).expect("Engine should initialize");

    let rules = vec![ReplacementRule {
        pattern: "kubernetes".to_string(),
        replacement: "Kubernetes".to_string(),
        context_type: "always".to_string(),
        context_value: None,
        enabled: true,
    }];

    engine
        .set_dictionary_rules(rules)
        .expect("Should set rules");

    let retrieved = engine.get_dictionary_rules();
    assert_eq!(retrieved.len(), 1);
    assert_eq!(retrieved[0].pattern, "kubernetes");
}

#[test]
#[ignore = "requires downloaded parakeet model"]
fn test_parakeet_transcription() {
    if !has_parakeet_model() {
        eprintln!("Skipping: parakeet model not downloaded");
        return;
    }

    let config = EngineConfig {
        models_dir: models_dir().to_string_lossy().to_string(),
        config_dir: config_dir().to_string_lossy().to_string(),
        active_stt_model: None,
        active_llm_provider: None,
        active_mode: "dictation".to_string(),
    };

    let engine = Engine::new(config).expect("Engine should initialize");
    engine
        .load_model("parakeet-tdt-0.6b-v3")
        .expect("Should load parakeet model");

    assert!(engine.is_model_loaded());

    // 3 seconds of 440Hz tone
    let samples: Vec<f32> = (0..48000)
        .map(|i| (2.0 * std::f32::consts::PI * 440.0 * i as f32 / 16000.0).sin() * 0.5)
        .collect();

    let result = engine
        .transcribe(samples, 16000, "dictation".into(), None)
        .expect("Transcription should succeed");

    println!(
        "Transcription: '{}' ({:.2}s)",
        result.text, result.duration_secs
    );
    assert_eq!(result.provider_name, "parakeet-tdt-0.6b-v3");
}
