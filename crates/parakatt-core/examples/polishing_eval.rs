//! Synthetic EN/SV checks. Protected-term checks are not a complete semantic evaluation.
use parakatt_core::llm::{
    http::{HttpProvider, Wire},
    LlmProvider, LlmRequest,
};
use serde_json::json;
fn main() {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if args.len() != 3 {
        eprintln!("Usage: polishing_eval <lmstudio|ollama|openai|anthropic> <base-url> <model>");
        std::process::exit(2);
    }
    let wire = match args[0].as_str() {
        "lmstudio" => Wire::Chat,
        "ollama" => Wire::Ollama,
        "openai" => Wire::Responses,
        "anthropic" => Wire::Anthropic,
        _ => std::process::exit(2),
    };
    let base = args[1].trim_end_matches('/');
    let base = if matches!(wire, Wire::Ollama) || base.ends_with("/v1") {
        base.to_string()
    } else {
        format!("{base}/v1")
    };
    let mut provider = HttpProvider::new(
        &base,
        &args[2],
        std::env::var("PARAKATT_PROVIDER_KEY").ok(),
        wire,
    );
    provider.output_limit = 1024;
    let cases = [
        (
            "english",
            "We discussed the approval process.",
            "Anna did not approve 42 items.",
            vec!["anna", "42"],
            vec!["not", "n't"],
        ),
        (
            "swedish",
            "Vi diskuterade godkännandet.",
            "Åsa godkände inte 42 poster.",
            vec!["åsa", "42"],
            vec!["inte"],
        ),
        (
            "english",
            "The deployment concerns",
            "version 1.2. Do not change Kubernetes.",
            vec!["1.2", "kubernetes"],
            vec!["not", "n't"],
        ),
        (
            "swedish",
            "Driftsättningen gäller",
            "version 1.2. Ändra inte Kubernetes.",
            vec!["1.2", "kubernetes"],
            vec!["inte"],
        ),
        (
            "mixed",
            "This project uses Swedish and English.",
            "Anna said nej. Deploy Kubernetes, men ändra inte version 1.2.",
            vec!["anna", "nej", "kubernetes", "1.2"],
            vec!["inte"],
        ),
    ];
    let mut results = Vec::new();
    let mut passed = true;
    for (language, prior, text, terms, negation) in cases {
        for with_context in [false, true] {
            let result=provider.process(&LlmRequest {text:text.into(),preceding_text:with_context.then(||prior.into()),allow_preceding_context:with_context,context:None,system_prompt:"Correct grammar and punctuation. Preserve the original language, names, numbers, and meaning. Return only the corrected text.".into()});
            let output = result.as_deref().unwrap_or("");
            let normalized = output.to_lowercase();
            let valid = result.is_ok()
                && terms.iter().all(|term| normalized.contains(term))
                && negation.iter().any(|term| normalized.contains(term));
            passed &= valid;
            results.push(json!({"language":language,"context":with_context,"input":text,"output":output,"valid_completed_stream":result.is_ok(),"protected_terms_pass":valid}));
        }
    }
    println!(
        "{}",
        json!({"provider":args[0],"model":args[2],"synthetic_input":true,"all_protected_terms_pass":passed,"cases":results,"limitations":"Term presence does not prove semantic equivalence. Review outputs and compare both context settings before enabling a default."})
    );
    if !passed {
        std::process::exit(1);
    }
}
