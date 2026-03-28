/// Direct LLM test — sends text to the LLM without STT.
/// Tests that the LLM actually processes and modifies text.
///
/// Usage: cargo run --example test_llm_direct -p parakatt-core

use parakatt_core::engine::Engine;
use parakatt_core::*;

fn main() {
    let config_dir = format!("{}/parakatt-llm-direct", std::env::temp_dir().display());
    let models_dir = format!("{}/Parakatt/models", dirs::data_dir().unwrap().display());

    let engine = Engine::new(EngineConfig {
        models_dir,
        config_dir,
        active_stt_model: None,
        active_llm_provider: None,
        active_mode: "dictation".to_string(),
    }).expect("Engine creation failed");

    // Configure LM Studio
    eprintln!("=== Configuring LM Studio ===");
    let models = engine.list_llm_models(
        "lmstudio".to_string(),
        "http://localhost:1234".to_string(),
        None,
    );

    let model = match models {
        Ok(ref m) if !m.is_empty() => {
            // Pick a chat model (skip embeddings)
            let chat_model = m.iter()
                .find(|name| !name.contains("embed"))
                .unwrap_or(&m[0]);
            eprintln!("Using model: {}", chat_model);
            chat_model.clone()
        }
        Ok(_) => { eprintln!("No models found"); return; }
        Err(e) => { eprintln!("LM Studio not available: {}", e); return; }
    };

    engine.configure_llm(
        "lmstudio".to_string(),
        "http://localhost:1234".to_string(),
        model,
        None,
    ).expect("Configure failed");

    // Set domain words
    engine.set_dictionary_rules(vec![
        ReplacementRule {
            pattern: "eval".to_string(),
            replacement: "eval".to_string(),
            context_type: "always".to_string(),
            context_value: None,
            enabled: true,
        },
        ReplacementRule {
            pattern: "Parakatt".to_string(),
            replacement: "Parakatt".to_string(),
            context_type: "always".to_string(),
            context_value: None,
            enabled: true,
        },
    ]).ok();

    // Load STT model
    engine.load_model("parakeet-tdt-0.6b-v2").expect("STT model load failed");

    // Generate audio with intentionally sloppy speech
    let test_cases = [
        ("me and him went to the store yesterday and buyed some stuff", "clean"),
        ("hey john i wanted to ask about the meeting can you send me the notes thanks", "email"),
        ("create a function called get user that takes an id parameter and returns a user object", "code"),
    ];

    for (text, mode) in &test_cases {
        eprintln!("\n=== Mode: {} ===", mode);
        eprintln!("Input:  \"{}\"", text);

        // Generate audio via say
        std::process::Command::new("say")
            .args(["-o", "/tmp/parakatt_llm_direct.aiff", *text])
            .status().ok();
        std::process::Command::new("sox")
            .args(["/tmp/parakatt_llm_direct.aiff", "-r", "16000", "-c", "1", "-b", "32", "-e", "floating-point", "/tmp/parakatt_llm_direct.raw"])
            .status().ok();

        let raw = std::fs::read("/tmp/parakatt_llm_direct.raw").expect("read failed");
        let samples: Vec<f32> = raw.chunks_exact(4)
            .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
            .collect();

        match engine.transcribe(samples, 16000, mode.to_string(), None) {
            Ok(r) => eprintln!("Output: \"{}\" ({:.2}s)", r.text, r.duration_secs),
            Err(e) => eprintln!("Error:  {}", e),
        }
    }

    eprintln!("\n=== Done ===");
}
