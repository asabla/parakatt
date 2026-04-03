/// Audio preprocessing utilities.
///
/// All audio entering the STT pipeline should be 16kHz mono f32 PCM.
/// This module handles validation, normalization, and silence trimming.

use crate::CoreError;

/// Expected sample rate for all STT providers.
pub const TARGET_SAMPLE_RATE: u32 = 16_000;

/// Minimum RMS energy to consider a frame as non-silent.
const SILENCE_THRESHOLD: f32 = 0.01;

/// Frame size in samples for silence detection (20ms at 16kHz).
const FRAME_SIZE: usize = 320;

/// Validate that audio is in the expected format and return it ready for processing.
pub fn preprocess(samples: &[f32], sample_rate: u32) -> Result<Vec<f32>, CoreError> {
    if sample_rate != TARGET_SAMPLE_RATE {
        return Err(CoreError::AudioError(format!(
            "Expected {}Hz audio, got {}Hz. Resample before sending to engine.",
            TARGET_SAMPLE_RATE, sample_rate
        )));
    }

    if samples.is_empty() {
        return Err(CoreError::AudioError("Empty audio buffer".into()));
    }

    let trimmed = trim_silence(samples);
    if trimmed.is_empty() {
        return Err(CoreError::AudioError("Audio contains only silence".into()));
    }

    let normalized = normalize(trimmed);
    Ok(normalized)
}

/// Trim leading and trailing silence from audio samples.
fn trim_silence(samples: &[f32]) -> &[f32] {
    let start = find_first_voiced_frame(samples).unwrap_or(0);
    let raw_end = find_last_voiced_frame(samples).unwrap_or(samples.len());
    // Keep 3 extra frames (60ms) after last voiced frame to preserve speech fade-outs
    let end = (raw_end + FRAME_SIZE * 3).min(samples.len());
    &samples[start..end]
}

/// Find the sample index where the first voiced frame begins.
fn find_first_voiced_frame(samples: &[f32]) -> Option<usize> {
    for (i, frame) in samples.chunks(FRAME_SIZE).enumerate() {
        if rms(frame) > SILENCE_THRESHOLD {
            return Some(i * FRAME_SIZE);
        }
    }
    None
}

/// Find the sample index where the last voiced frame ends.
fn find_last_voiced_frame(samples: &[f32]) -> Option<usize> {
    let num_frames = (samples.len() + FRAME_SIZE - 1) / FRAME_SIZE;
    for i in (0..num_frames).rev() {
        let start = i * FRAME_SIZE;
        let end = (start + FRAME_SIZE).min(samples.len());
        if rms(&samples[start..end]) > SILENCE_THRESHOLD {
            return Some(end);
        }
    }
    None
}

/// Normalize audio to peak amplitude of 1.0.
fn normalize(samples: &[f32]) -> Vec<f32> {
    let peak = samples
        .iter()
        .map(|s| s.abs())
        .fold(0.0f32, f32::max);

    if peak < 1e-6 {
        return samples.to_vec();
    }

    let scale = 1.0 / peak;
    samples.iter().map(|s| s * scale).collect()
}

/// Root mean square energy of a frame.
fn rms(frame: &[f32]) -> f32 {
    if frame.is_empty() {
        return 0.0;
    }
    let sum_sq: f32 = frame.iter().map(|s| s * s).sum();
    (sum_sq / frame.len() as f32).sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rms_silence() {
        let silence = vec![0.0f32; 320];
        assert!(rms(&silence) < SILENCE_THRESHOLD);
    }

    #[test]
    fn test_rms_signal() {
        let signal: Vec<f32> = (0..320).map(|i| (i as f32 * 0.1).sin() * 0.5).collect();
        assert!(rms(&signal) > SILENCE_THRESHOLD);
    }

    #[test]
    fn test_normalize() {
        let samples = vec![0.0, 0.25, -0.5, 0.1];
        let norm = normalize(&samples);
        assert!((norm[2] - (-1.0)).abs() < 1e-6);
        assert!((norm[1] - 0.5).abs() < 1e-6);
    }

    #[test]
    fn test_preprocess_wrong_sample_rate() {
        let samples = vec![0.1; 1600];
        assert!(preprocess(&samples, 44100).is_err());
    }

    #[test]
    fn test_preprocess_empty() {
        let samples: Vec<f32> = vec![];
        assert!(preprocess(&samples, 16000).is_err());
    }

    #[test]
    fn test_trim_silence() {
        let mut samples = vec![0.0f32; 640]; // silence
        samples.extend(vec![0.5f32; 320]); // signal
        samples.extend(vec![0.0f32; 960]); // trailing silence (enough for padding)
        let trimmed = trim_silence(&samples);
        // Signal (320) + 3 trailing padding frames (960), capped by available samples
        assert_eq!(trimmed.len(), 320 + FRAME_SIZE * 3);
    }
}
