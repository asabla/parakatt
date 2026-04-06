/// Transcribe a raw f32 audio file captured by the Swift test.
///
/// Usage: cargo run --example test_audio_file -p parakatt-core [path]
///
/// Expects f32le, 16kHz, mono.
/// Default path: /tmp/parakatt_test.raw
use parakatt_core::engine::Engine;
use parakatt_core::*;

fn main() {
    let audio_path = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "/tmp/parakatt_test.raw".to_string());

    let models_dir = format!("{}/Parakatt/models", dirs::data_dir().unwrap().display());
    let config_dir = format!("{}/parakatt-test", std::env::temp_dir().display());

    // Read audio
    eprintln!("=== Reading audio from {} ===", audio_path);
    let raw_bytes = match std::fs::read(&audio_path) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("Failed to read {}: {}", audio_path, e);
            std::process::exit(1);
        }
    };

    let samples: Vec<f32> = raw_bytes
        .chunks_exact(4)
        .map(|chunk| f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]))
        .collect();

    let duration = samples.len() as f64 / 16000.0;
    let max_amp: f32 = samples.iter().map(|s| s.abs()).fold(0.0f32, f32::max);

    eprintln!(
        "Samples: {} ({:.1}s), max amplitude: {:.6}",
        samples.len(),
        duration,
        max_amp
    );

    if max_amp < 0.001 {
        eprintln!("Audio is silence — nothing to transcribe");
        std::process::exit(1);
    }

    // Create engine and load model
    eprintln!("\n=== Loading model ===");
    let engine = Engine::new(EngineConfig {
        models_dir,
        config_dir,
        active_stt_model: None,
        active_llm_provider: None,
        active_mode: "dictation".to_string(),
    })
    .expect("Engine creation failed");

    engine
        .load_model("parakeet-tdt-0.6b-v3")
        .expect("Model load failed");

    // Transcribe
    eprintln!("\n=== Transcribing ===");
    match engine.transcribe(samples, 16000, "dictation".to_string(), None) {
        Ok(result) => {
            if result.text.is_empty() {
                eprintln!("(no speech detected)");
            } else {
                eprintln!("Result ({:.2}s): {}", result.duration_secs, result.text);
                println!("{}", result.text);
            }
        }
        Err(e) => {
            eprintln!("Transcription failed: {}", e);
            std::process::exit(1);
        }
    }
}
