//! Synthetic shared-model contention. This is not a live capture/UI measurement.
use parakatt_core::{speech::SpeechBackend, stt::parakeet::ParakeetProvider};
use std::{
    io::BufRead,
    path::Path,
    sync::Arc,
    time::{Duration, Instant},
};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let directory = std::env::args().nth(1).ok_or("missing model directory")?;
    let backend = match std::env::args().nth(2).as_deref() {
        Some("cpu") => SpeechBackend::Cpu,
        Some("webgpu") => SpeechBackend::WebGpu,
        _ => return Err("expected cpu or webgpu".into()),
    };
    let provider = Arc::new(ParakeetProvider::load_with_backend(
        Path::new(&directory),
        "parakeet-tdt-0.6b-v3",
        backend,
        4,
        false,
    )?);
    println!(
        "{}",
        serde_json::json!({"backend":format!("{:?}",provider.actual_backend()),"kind":"synthetic shared-model contention","preview_audio_secs":30,"trials":10})
    );
    for path in std::io::stdin().lock().lines() {
        let path = path?;
        let mut reader = hound::WavReader::open(&path)?;
        let spec = reader.spec();
        if spec.sample_rate != 16000 || spec.channels != 1 {
            return Err("expected mono 16 kHz audio".into());
        }
        let samples = match spec.sample_format {
            hound::SampleFormat::Float => reader.samples::<f32>().collect::<Result<Vec<_>, _>>()?,
            hound::SampleFormat::Int => reader
                .samples::<i32>()
                .map(|s| s.map(|v| v as f32 / 2_f32.powi(spec.bits_per_sample as i32 - 1)))
                .collect::<Result<Vec<_>, _>>()?,
        };
        if samples.is_empty() {
            return Err("empty fixture".into());
        }
        let preview: Vec<f32> = samples.iter().copied().cycle().take(30 * 16000).collect();
        let (expected, _) = provider.transcribe_profiled(&samples, 16000)?;
        // Warm the longer shape before recording either mode.
        provider.transcribe_profiled(&preview, 16000)?;
        let mut rows = Vec::new();
        for trial in 0..10 {
            let started = Instant::now();
            let (solo, _) = provider.transcribe_profiled(&samples, 16000)?;
            let solo_secs = started.elapsed().as_secs_f64();
            if solo.text != expected.text {
                return Err("isolated transcript changed".into());
            }
            let (ready, receive) = std::sync::mpsc::channel();
            let shared = Arc::clone(&provider);
            let audio = preview.clone();
            let work = std::thread::spawn(move || {
                ready.send(()).unwrap();
                shared.transcribe_profiled(&audio, 16000)
            });
            receive.recv()?;
            // Give the preview thread a head start, then record actual lock wait.
            std::thread::sleep(Duration::from_millis(10));
            let started = Instant::now();
            let result = provider.transcribe_profiled(&samples, 16000);
            let contended_secs = started.elapsed().as_secs_f64();
            work.join().map_err(|_| "preview worker panicked")??;
            let (contended, profile) = result?;
            if contended.text != expected.text {
                return Err("contended transcript changed".into());
            }
            rows.push(serde_json::json!({"trial":trial,"solo_secs":solo_secs,"contended_secs":contended_secs,"provider_lock_wait_secs":profile.lock_wait_secs}));
        }
        println!(
            "{}",
            serde_json::json!({"backend":format!("{:?}",provider.actual_backend()),"path":path,"rows":rows})
        );
    }
    Ok(())
}
