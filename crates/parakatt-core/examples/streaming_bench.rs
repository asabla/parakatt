//! Shared-weight streaming worker; each JSON request is an independent recording.
use parakatt_core::{
    local_agreement::{LocalAgreement2, Token},
    speech::SpeechLanguage,
    stt::{nemotron::NemotronProvider, streaming::StreamingProvider},
};
use std::{io::BufRead, path::Path, time::Instant};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let dir = std::env::args().nth(1).ok_or("missing model directory")?;
    let threads = std::env::args()
        .nth(3)
        .unwrap_or_else(|| "4".into())
        .parse()?;
    let start = Instant::now();
    let provider = NemotronProvider::load(
        Path::new(&dir),
        "nemotron-3.5-asr-streaming-0.6b",
        SpeechLanguage::Automatic,
        threads,
    )?;
    let size = provider.native_chunk_samples();
    if size == 0 {
        return Err("missing chunk metadata".into());
    }
    println!(
        "{}",
        serde_json::json!({"load_secs": start.elapsed().as_secs_f64(), "backend": "Cpu", "cpu_threads": threads, "chunk_samples": size})
    );
    for line in std::io::stdin().lock().lines() {
        let value: serde_json::Value = serde_json::from_str(&line?)?;
        let path = value["path"].as_str().ok_or("missing path")?;
        let language = match value["language"].as_str() {
            Some("en_us") => SpeechLanguage::English,
            Some("sv_se") => SpeechLanguage::Swedish,
            _ => SpeechLanguage::Automatic,
        };
        let mut reader = hound::WavReader::open(path)?;
        let spec = reader.spec();
        if spec.channels != 1 || spec.sample_rate != 16000 {
            return Err("expected mono 16 kHz WAV".into());
        }
        let audio = match spec.sample_format {
            hound::SampleFormat::Float => reader.samples::<f32>().collect::<Result<Vec<_>, _>>()?,
            hound::SampleFormat::Int => reader
                .samples::<i32>()
                .map(|s| s.map(|v| v as f32 / 2_f32.powi(spec.bits_per_sample as i32 - 1)))
                .collect::<Result<Vec<_>, _>>()?,
        };
        let start = Instant::now();
        let mut session = provider.start_session_for_language(language)?;
        let session_secs = start.elapsed().as_secs_f64();
        let mut agreement = LocalAgreement2::new();
        let (mut first_compute, mut first_audio, mut stable_compute, mut stable_audio) =
            (None, None, None, None);
        let mut chunk_times = Vec::new();
        for (index, chunk) in audio.chunks(size).enumerate() {
            let mut padded = vec![0.; size];
            padded[..chunk.len()].copy_from_slice(chunk);
            let feed = Instant::now();
            session.feed_chunk(&padded)?;
            chunk_times.push(feed.elapsed().as_secs_f64());
            let text = session.current_transcript();
            let tokens = text
                .split_whitespace()
                .map(|t| Token {
                    text: t.into(),
                    start_secs: 0.,
                    end_secs: 0.,
                })
                .collect();
            agreement.update(tokens);
            let elapsed = start.elapsed().as_secs_f64();
            let heard = ((index + 1) * size).min(audio.len()) as f64 / 16000.;
            if first_compute.is_none() && !text.trim().is_empty() {
                first_compute = Some(elapsed);
                first_audio = Some(heard);
            }
            if stable_compute.is_none() && !agreement.committed_text().is_empty() {
                stable_compute = Some(elapsed);
                stable_audio = Some(heard);
            }
        }
        println!(
            "{}",
            serde_json::json!({"backend": "Cpu", "path": path, "text": session.current_transcript(), "inference_secs": start.elapsed().as_secs_f64(), "audio_secs": audio.len() as f64 / 16000., "session_create_secs": session_secs, "first_preview_compute_secs": first_compute, "first_preview_audio_secs": first_audio, "stable_preview_compute_secs": stable_compute, "stable_preview_audio_secs": stable_audio, "chunk_inference_secs": chunk_times})
        );
    }
    Ok(())
}
