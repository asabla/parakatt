/// Integration tests for the Parakatt engine.
use parakatt_core::engine::Engine;
use parakatt_core::*;
use std::path::PathBuf;

fn models_dir() -> PathBuf {
    if let Some(path) = std::env::var_os("PARAKATT_MODELS") {
        return path.into();
    }
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
    let dir = parakatt_core::models::model_path(&models_dir(), "parakeet-tdt-0.6b-v3");
    [
        "vocab.txt",
        "encoder-model.onnx",
        "encoder-model.onnx.data",
        "decoder_joint-model.onnx",
    ]
    .iter()
    .all(|name| dir.join(name).is_file())
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
    assert!(
        has_parakeet_model(),
        "Required Parakeet model files are missing"
    );

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

    let fixture_path = std::env::var_os("PARAKATT_FIXTURES")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| {
            std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../target/fixtures/fleurs/manifest.json")
        });
    let fixtures: serde_json::Value = serde_json::from_slice(
        &std::fs::read(&fixture_path)
            .expect("Pinned FLEURS fixtures are required; run scripts/prepare-fixtures.py"),
    )
    .unwrap();
    for language in ["en_us", "sv_se"] {
        let sample = fixtures["samples"]
            .as_array()
            .unwrap()
            .iter()
            .find(|s| s["language"] == language)
            .expect("Required language fixture");
        let mut wav = hound::WavReader::open(sample["path"].as_str().unwrap())
            .expect("Required audio fixture");
        assert_eq!(wav.spec().sample_rate, 16000);
        let spec = wav.spec();
        assert_eq!(spec.channels, 1);
        let samples = match spec.sample_format {
            hound::SampleFormat::Float => {
                wav.samples::<f32>().collect::<Result<Vec<_>, _>>().unwrap()
            }
            hound::SampleFormat::Int => wav
                .samples::<i32>()
                .map(|s| s.map(|v| v as f32 / 2_f32.powi(spec.bits_per_sample as i32 - 1)))
                .collect::<Result<Vec<_>, _>>()
                .unwrap(),
        };
        let result = engine
            .transcribe(samples, 16000, "dictation".into(), None)
            .expect("Real speech transcription");
        assert!(
            !result.text.is_empty(),
            "No recognized speech for {language}"
        );
        assert_eq!(result.provider_name, "parakeet-tdt-0.6b-v3");
    }
}
