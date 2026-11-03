//! JSON-lines benchmark worker. Audio remains local; no history is written.
use parakatt_core::stt::{parakeet::ParakeetProvider, SttProvider};
use std::{io::BufRead, path::Path, time::Instant};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let directory = std::env::args().nth(1).ok_or("missing model directory")?;
    let backend_name = std::env::args().nth(2).unwrap_or_else(|| "cpu".into());
    let backend = match backend_name.as_str() {
        "cpu" => parakatt_core::speech::SpeechBackend::Cpu,
        "webgpu" => parakatt_core::speech::SpeechBackend::WebGpu,
        _ => return Err("invalid backend".into()),
    };
    let threads: u32 = std::env::args()
        .nth(3)
        .unwrap_or_else(|| "0".into())
        .parse()?;
    let decoder_threads: u32 = std::env::args()
        .nth(4)
        .map(|v| v.parse())
        .transpose()?
        .unwrap_or(threads);
    let profile = std::env::args().nth(5).as_deref() == Some("profile");
    let started = Instant::now();
    let provider = ParakeetProvider::load_with_thread_counts(
        Path::new(&directory),
        "parakeet-tdt-0.6b-v3",
        backend,
        threads,
        decoder_threads,
        false,
    )?;
    println!(
        "{}",
        serde_json::json!({"load_secs": started.elapsed().as_secs_f64(), "backend": format!("{:?}", provider.actual_backend()), "cpu_threads": threads, "decoder_threads": decoder_threads, "profile": profile})
    );
    for line in std::io::stdin().lock().lines() {
        let path = line?;
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
        let start = Instant::now();
        let (result, timings) = if profile {
            let (result, timings) = provider.transcribe_profiled(&samples, spec.sample_rate)?;
            (result, Some(timings))
        } else {
            (provider.transcribe(&samples, spec.sample_rate)?, None)
        };
        println!(
            "{}",
            serde_json::json!({"backend": format!("{:?}", provider.actual_backend()), "path": path, "text": result.text, "segments": result.segments, "stages": timings, "inference_secs": start.elapsed().as_secs_f64(), "audio_secs": samples.len() as f64 / 16000.0})
        );
    }
    Ok(())
}
