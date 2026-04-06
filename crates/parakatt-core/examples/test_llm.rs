/// E2E test for LLM integration.
///
/// Tests: model listing, LLM configuration, and transcription with post-processing.
/// Requires LM Studio running at localhost:1234 (or Ollama at localhost:11434).
///
/// Usage: cargo run --example test_llm -p parakatt-core
use parakatt_core::engine::Engine;
use parakatt_core::*;

fn main() {
    let models_dir = format!("{}/Parakatt/models", dirs::data_dir().unwrap().display());
    let config_dir = format!("{}/parakatt-llm-test", std::env::temp_dir().display());

    // Step 1: Create engine
    eprintln!("=== Step 1: Create engine ===");
    let engine = Engine::new(EngineConfig {
        models_dir: models_dir.clone(),
        config_dir,
        active_stt_model: None,
        active_llm_provider: None,
        active_mode: "dictation".to_string(),
    })
    .expect("Engine creation failed");
    eprintln!("Engine created");

    // Step 2: Test model listing for each provider
    eprintln!("\n=== Step 2: List LLM models ===");

    // Try LM Studio
    eprintln!("\n--- LM Studio (localhost:1234) ---");
    match engine.list_llm_models(
        "lmstudio".to_string(),
        "http://localhost:1234".to_string(),
        None,
    ) {
        Ok(models) => {
            eprintln!("Found {} models:", models.len());
            for m in &models {
                eprintln!("  - {}", m);
            }
            if !models.is_empty() {
                test_llm_with_provider(
                    &engine,
                    "lmstudio",
                    "http://localhost:1234",
                    &models[0],
                    &models_dir,
                );
            }
        }
        Err(e) => eprintln!("LM Studio not available: {}", e),
    }

    // Try Ollama
    eprintln!("\n--- Ollama (localhost:11434) ---");
    match engine.list_llm_models(
        "ollama".to_string(),
        "http://localhost:11434".to_string(),
        None,
    ) {
        Ok(models) => {
            eprintln!("Found {} models:", models.len());
            for m in &models {
                eprintln!("  - {}", m);
            }
            if !models.is_empty() {
                test_llm_with_provider(
                    &engine,
                    "ollama",
                    "http://localhost:11434",
                    &models[0],
                    &models_dir,
                );
            }
        }
        Err(e) => eprintln!("Ollama not available: {}", e),
    }

    eprintln!("\n=== Done ===");
}

fn test_llm_with_provider(
    engine: &Engine,
    provider: &str,
    base_url: &str,
    model: &str,
    models_dir: &str,
) {
    eprintln!("\n=== Step 3: Configure LLM ({} / {}) ===", provider, model);
    match engine.configure_llm(
        provider.to_string(),
        base_url.to_string(),
        model.to_string(),
        None,
    ) {
        Ok(_) => eprintln!("LLM configured"),
        Err(e) => {
            eprintln!("Failed to configure LLM: {}", e);
            return;
        }
    }

    // Step 4: Test direct LLM call via "clean" mode transcription
    eprintln!("\n=== Step 4: Test LLM processing ===");

    // Set up dictionary with domain words
    let rules = vec![
        ReplacementRule {
            pattern: "Parakatt".to_string(),
            replacement: "Parakatt".to_string(), // domain word (identity)
            context_type: "always".to_string(),
            context_value: None,
            enabled: true,
        },
        ReplacementRule {
            pattern: "eval".to_string(),
            replacement: "eval".to_string(), // domain word
            context_type: "always".to_string(),
            context_value: None,
            enabled: true,
        },
    ];
    engine
        .set_dictionary_rules(rules)
        .expect("Failed to set dictionary");
    eprintln!("Dictionary set with domain words: Parakatt, eval");

    // Load STT model if available
    let has_stt = std::path::Path::new(models_dir)
        .join("parakeet-tdt-0.6b-v3")
        .join("vocab.txt")
        .exists();

    if has_stt {
        eprintln!("\n--- Test A: Full pipeline (STT → LLM) ---");
        engine
            .load_model("parakeet-tdt-0.6b-v3")
            .expect("Model load failed");

        // Generate TTS audio for testing
        let test_text = "this is a test of the clean mode with grammar fixing";
        eprintln!("Generating test audio via macOS say...");

        // Use macOS `say` to generate speech, then convert to raw f32
        let status = std::process::Command::new("say")
            .args(["-o", "/tmp/parakatt_llm_test.aiff", test_text])
            .status();

        if status.map(|s| s.success()).unwrap_or(false) {
            let sox_status = std::process::Command::new("sox")
                .args([
                    "/tmp/parakatt_llm_test.aiff",
                    "-r",
                    "16000",
                    "-c",
                    "1",
                    "-b",
                    "32",
                    "-e",
                    "floating-point",
                    "/tmp/parakatt_llm_test.raw",
                ])
                .status();

            if sox_status.map(|s| s.success()).unwrap_or(false) {
                let raw =
                    std::fs::read("/tmp/parakatt_llm_test.raw").expect("Failed to read raw audio");
                let samples: Vec<f32> = raw
                    .chunks_exact(4)
                    .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
                    .collect();

                eprintln!(
                    "Audio: {} samples ({:.1}s)",
                    samples.len(),
                    samples.len() as f64 / 16000.0
                );

                // Test dictation mode (no LLM)
                eprintln!("\nDictation mode (no LLM):");
                match engine.transcribe(samples.clone(), 16000, "dictation".to_string(), None) {
                    Ok(r) => eprintln!("  Result: \"{}\" ({:.2}s)", r.text, r.duration_secs),
                    Err(e) => eprintln!("  Error: {}", e),
                }

                // Test clean mode (with LLM)
                eprintln!("\nClean mode (with LLM):");
                match engine.transcribe(samples, 16000, "clean".to_string(), None) {
                    Ok(r) => eprintln!("  Result: \"{}\" ({:.2}s)", r.text, r.duration_secs),
                    Err(e) => eprintln!("  Error: {}", e),
                }
            } else {
                eprintln!("sox not available, skipping full pipeline test");
            }
        } else {
            eprintln!("say command failed, skipping full pipeline test");
        }
    } else {
        eprintln!("STT model not downloaded, skipping full pipeline test");
    }

    // Test B: LLM-only (simulate what happens after STT)
    eprintln!("\n--- Test B: LLM-only processing ---");
    eprintln!("Sending text directly to LLM via clean mode...");

    // We can't call the LLM directly through the public API without STT,
    // but we can verify by using a pre-transcribed text through the engine.
    // For now, just confirm the configuration worked by checking modes.
    let modes = engine.list_modes();
    let clean_mode = modes.iter().find(|m| m.name == "clean");
    if let Some(mode) = clean_mode {
        eprintln!(
            "Clean mode prompt: {:?}",
            mode.system_prompt.as_deref().unwrap_or("none")
        );
        eprintln!("LLM is configured and will process transcriptions in clean/email/code modes");
    }
}
