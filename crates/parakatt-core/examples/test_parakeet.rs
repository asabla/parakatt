use parakatt_core::engine::Engine;
use parakatt_core::*;

fn main() {
    let models_dir = format!(
        "{}/Parakatt/models",
        dirs::data_dir().unwrap().display()
    );
    let config_dir = format!("{}/parakatt-test", std::env::temp_dir().display());

    eprintln!("Models dir: {}", models_dir);

    eprintln!("\n=== Creating engine (no auto-load) ===");
    let config = EngineConfig {
        models_dir: models_dir.clone(),
        config_dir: config_dir.clone(),
        active_stt_model: None,
        active_llm_provider: None,
        active_mode: "dictation".to_string(),
    };

    let engine = Engine::new(config).expect("Engine should initialize");
    eprintln!("Engine created, model loaded: {}", engine.is_model_loaded());

    let models = engine.list_models();
    eprintln!("Available models:");
    for m in &models {
        eprintln!("  - {} (downloaded: {})", m.display_name, m.downloaded);
    }

    // Find a downloaded model
    let downloaded = models.iter().find(|m| m.downloaded);
    if let Some(model) = downloaded {
        eprintln!("\n=== Loading model: {} ===", model.id);
        engine.load_model(&model.id).expect("Should load model");
        eprintln!("Model loaded: {}", engine.is_model_loaded());

        eprintln!("\n=== Transcribing 3s tone ===");
        let sample_rate = 16000u32;
        let num_samples = 48000;
        let samples: Vec<f32> = (0..num_samples)
            .map(|i| {
                (2.0 * std::f32::consts::PI * 440.0 * i as f32 / sample_rate as f32).sin() * 0.5
            })
            .collect();

        match engine.transcribe(samples, sample_rate, "dictation".into(), None) {
            Ok(result) => {
                eprintln!(
                    "Transcription: '{}' ({:.2}s, provider: {})",
                    result.text, result.duration_secs, result.provider_name
                );
            }
            Err(e) => {
                eprintln!("Transcription error: {}", e);
            }
        }
    } else {
        eprintln!("\nNo model downloaded. Download one first:");
        eprintln!("  See Makefile target: make download-model");
    }

    eprintln!("\n=== Done ===");
}
