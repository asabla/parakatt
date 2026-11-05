use std::fs::File;
use std::io::{Cursor, Read};
use std::path::Path;

pub const SAMPLE_RATE: u32 = parakatt_core::audio::TARGET_SAMPLE_RATE;
pub const MAX_SAMPLES: usize = SAMPLE_RATE as usize * 30;
const MAX_AUDIO_BYTES: usize = MAX_SAMPLES * 4;
// Bound metadata too; a WAV header must not defeat the input allocation limit.
const MAX_FILE_BYTES: usize = MAX_AUDIO_BYTES + 64 * 1024;

pub fn read_audio(path: &Path, raw: bool) -> Result<Vec<f32>, String> {
    if !path.metadata().map_err(|e| e.to_string())?.is_file() {
        return Err("Input must be a regular audio file".into());
    }
    let file = File::open(path).map_err(|e| format!("Cannot open {}: {e}", path.display()))?;
    let metadata = file.metadata().map_err(|e| e.to_string())?;
    if !metadata.is_file() || metadata.len() > MAX_FILE_BYTES as u64 {
        return Err("Input exceeds the bounded audio file size limit".into());
    }
    let mut bytes = Vec::with_capacity(
        usize::try_from(metadata.len())
            .map_err(|_| "Input is too large for this platform".to_string())?,
    );
    file.take(MAX_FILE_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() > MAX_FILE_BYTES {
        return Err("Input exceeds the bounded audio file size limit".into());
    }
    let samples = if raw {
        if bytes.len() > MAX_AUDIO_BYTES {
            return Err("Audio exceeds the 30-second limit".into());
        }
        let (frames, remainder) = bytes.as_chunks::<4>();
        if !remainder.is_empty() {
            return Err("Raw f32le input length must be divisible by four bytes".into());
        }
        frames
            .iter()
            .map(|frame| f32::from_le_bytes(*frame))
            .collect()
    } else {
        decode_wav(bytes)?
    };
    if samples.is_empty() {
        return Err("Audio input is empty".into());
    }
    if samples.iter().any(|v| !v.is_finite() || v.abs() > 1.0) {
        return Err("Audio samples must be finite and in the range -1 to 1".into());
    }
    if samples.iter().all(|v| *v == 0.0) {
        return Err("Audio contains only silence".into());
    }
    Ok(samples)
}

fn decode_wav(bytes: Vec<u8>) -> Result<Vec<f32>, String> {
    let mut reader =
        hound::WavReader::new(Cursor::new(bytes)).map_err(|e| format!("Invalid WAV input: {e}"))?;
    let spec = reader.spec();
    if spec.channels != 1 || spec.sample_rate != SAMPLE_RATE {
        return Err("WAV input must be mono at 16000 Hz; resample before transcribing".into());
    }
    if reader.duration() as usize > MAX_SAMPLES {
        return Err("Audio exceeds the 30-second limit".into());
    }
    match (spec.sample_format, spec.bits_per_sample) {
        (hound::SampleFormat::Float, 32) => reader
            .samples::<f32>()
            .map(|v| v.map_err(|e| format!("Invalid WAV sample: {e}")))
            .collect(),
        (hound::SampleFormat::Int, bits @ (16 | 24 | 32)) => {
            let scale = (1_u64 << (bits - 1)) as f32;
            reader
                .samples::<i32>()
                .map(|v| {
                    v.map(|sample| sample as f32 / scale)
                        .map_err(|e| format!("Invalid WAV sample: {e}"))
                })
                .collect()
        }
        _ => Err("WAV input must use 16/24/32-bit integer PCM or 32-bit float".into()),
    }
}
