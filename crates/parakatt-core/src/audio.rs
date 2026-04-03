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

/// Pre-emphasis coefficient for boosting high frequencies.
/// Standard value for speech processing (0.95-0.97).
const PRE_EMPHASIS_COEFF: f32 = 0.97;

/// Noise gate threshold — frames below this RMS are zeroed.
/// Set conservatively low to avoid cutting trailing speech consonants
/// which naturally decay to ~0.003-0.008 RMS.
const NOISE_GATE_THRESHOLD: f32 = 0.002;

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

    // Noise gate first to zero background noise, then trim silence.
    // This order prevents the gate from eating trailing speech that
    // silence trimming would have preserved.
    let gated = noise_gate(samples);
    let trimmed = trim_silence(&gated);
    if trimmed.is_empty() {
        return Err(CoreError::AudioError("Audio contains only silence".into()));
    }

    let emphasized = pre_emphasis(trimmed);
    let normalized = normalize(&emphasized);
    Ok(normalized)
}

/// Apply a noise gate: zero out frames with RMS below the threshold.
/// This removes faint background noise between speech segments while
/// preserving the actual speech signal.
fn noise_gate(samples: &[f32]) -> Vec<f32> {
    let mut result = Vec::with_capacity(samples.len());
    for frame in samples.chunks(FRAME_SIZE) {
        if rms(frame) > NOISE_GATE_THRESHOLD {
            result.extend_from_slice(frame);
        } else {
            result.extend(std::iter::repeat(0.0f32).take(frame.len()));
        }
    }
    result
}

/// Apply a pre-emphasis filter to boost high frequencies.
/// This is a standard first step in speech processing pipelines,
/// compensating for the natural roll-off of speech at higher frequencies.
/// Formula: y[n] = x[n] - coeff * x[n-1]
fn pre_emphasis(samples: &[f32]) -> Vec<f32> {
    if samples.is_empty() {
        return Vec::new();
    }
    let mut result = Vec::with_capacity(samples.len());
    result.push(samples[0]);
    for i in 1..samples.len() {
        result.push(samples[i] - PRE_EMPHASIS_COEFF * samples[i - 1]);
    }
    result
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

    #[test]
    fn test_pre_emphasis() {
        let samples = vec![0.0, 1.0, 1.0, 1.0];
        let result = pre_emphasis(&samples);
        assert_eq!(result[0], 0.0);
        // y[1] = 1.0 - 0.97 * 0.0 = 1.0
        assert!((result[1] - 1.0).abs() < 1e-6);
        // y[2] = 1.0 - 0.97 * 1.0 = 0.03
        assert!((result[2] - 0.03).abs() < 1e-4);
    }

    #[test]
    fn test_noise_gate_passes_signal() {
        let signal = vec![0.5f32; FRAME_SIZE];
        let result = noise_gate(&signal);
        assert_eq!(result, signal);
    }

    #[test]
    fn test_noise_gate_silences_noise() {
        // Very quiet noise below threshold (0.002)
        let noise: Vec<f32> = vec![0.0005f32; FRAME_SIZE];
        let result = noise_gate(&noise);
        assert!(result.iter().all(|&s| s == 0.0));
    }

    #[test]
    fn test_noise_gate_preserves_trailing_speech() {
        // Trailing speech at 0.005 RMS should NOT be gated (above 0.002 threshold)
        let trailing: Vec<f32> = vec![0.005f32; FRAME_SIZE];
        let result = noise_gate(&trailing);
        assert_eq!(result, trailing);
    }
}
