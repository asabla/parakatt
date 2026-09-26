//! Explicit live check using synthetic text. Does not read or change app settings.
use parakatt_core::llm::{
    http::{HttpProvider, Wire},
    LlmProvider, LlmRequest,
};
use serde_json::json;
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() != 3 {
        eprintln!("Usage: provider_smoke <lmstudio|ollama|openai|anthropic> <base-url> <model>; optional PARAKATT_PROVIDER_KEY");
        std::process::exit(2);
    }
    let wire = match args[0].as_str() {
        "lmstudio" => Wire::Chat,
        "ollama" => Wire::Ollama,
        "openai" => Wire::Responses,
        "anthropic" => Wire::Anthropic,
        _ => std::process::exit(2),
    };
    let mut provider = HttpProvider::new(
        &args[1],
        &args[2],
        std::env::var("PARAKATT_PROVIDER_KEY").ok(),
        wire,
    );
    provider.output_limit = 256;
    let start = std::time::Instant::now();
    let result = provider.process(&LlmRequest {
        text: "This is a synthetic connection test. Det här är ett syntetiskt anslutningstest."
            .into(),
        system_prompt: "Return only the word READY.".into(),
        context: None,
    });
    let valid = result.as_ref().is_ok_and(|text| !text.trim().is_empty());
    println!(
        "{}",
        json!({"provider":args[0],"model":args[2],"valid_completed_stream":valid,"elapsed_seconds":start.elapsed().as_secs_f64(),"response_characters":result.as_ref().map(|s|s.chars().count()).unwrap_or(0),"synthetic_input":true})
    );
    if !valid {
        eprintln!("Live completion check failed; no response text or credentials were logged.");
        std::process::exit(1);
    }
}
