//! Experimental worker; not linked into or shipped with Parakatt.
use parakeet_rs::{ExecutionConfig, ExecutionProvider, ParakeetTDT, TimestampMode, Transcriber};
use std::{io::BufRead, time::Instant};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let directory = std::env::args().nth(1).ok_or("missing model directory")?;
    if std::env::args().nth(2).as_deref() != Some("burnmetal") {
        return Err("this worker requires burnmetal".into());
    }
    if std::env::args().nth(3).is_some_and(|v| v != "0") {
        return Err("Burn uses its runtime thread policy; use --threads 0".into());
    }
    let started = Instant::now();
    let config = ExecutionConfig::new().with_execution_provider(ExecutionProvider::BurnWgpu);
    let mut model = ParakeetTDT::from_pretrained(directory, Some(config))?;
    println!(
        "{}",
        serde_json::json!({"load_secs": started.elapsed().as_secs_f64(), "backend": "burnmetal", "runtime": "parakeet-rs 0.4.4 / burn Metal", "frontend": "upstream"})
    );
    for path in std::io::stdin().lock().lines() {
        let path = path?;
        let mut reader = hound::WavReader::open(&path)?;
        let spec = reader.spec();
        if spec.channels != 1 || spec.sample_rate != 16000 {
            return Err("fixtures must be mono 16 kHz WAV".into());
        }
        let samples = match spec.sample_format {
            hound::SampleFormat::Float => reader.samples::<f32>().collect::<Result<Vec<_>, _>>()?,
            hound::SampleFormat::Int => reader
                .samples::<i32>()
                .map(|s| s.map(|v| v as f32 / 2_f32.powi(spec.bits_per_sample as i32 - 1)))
                .collect::<Result<Vec<_>, _>>()?,
        };
        let audio_secs = samples.len() as f64 / 16000.0;
        let started = Instant::now();
        let result = model.transcribe_samples(samples, 16000, 1, Some(TimestampMode::Sentences))?;
        let elapsed = started.elapsed().as_secs_f64();
        let segments: Vec<_> = result.tokens.iter().map(|token| serde_json::json!({"text":token.text,"start_secs":token.start,"end_secs":token.end})).collect();
        println!(
            "{}",
            serde_json::json!({"backend":"burnmetal","path":path,"text":result.text,"segments":segments,"inference_secs":elapsed,"audio_secs":audio_secs})
        );
    }
    Ok(())
}
