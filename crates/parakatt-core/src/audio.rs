/// Audio preprocessing utilities.
///
/// All audio entering the STT pipeline must be 16kHz mono f32 PCM.
/// We deliberately do **as little processing as possible** here:
///
/// - Pre-emphasis is applied inside `parakeet-rs` (coef 0.97), so we
///   must NOT pre-emphasize again — doing so distorts high frequencies
///   and degrades STT accuracy.
/// - Per-feature mean/variance normalization is applied to the mel
///   spectrogram inside `parakeet-rs`, so peak-normalizing the raw
///   waveform is wrong (it destroys amplitude cues the model uses).
///
/// What this module does:
/// 1. Validate sample rate.
/// 2. Trim leading/trailing silence so we don't waste encoder time
///    on empty audio (and so chunk timestamps don't include silence
///    padding at the head). The amount trimmed is reported back so
///    the caller can offset segment timestamps accordingly.
use crate::CoreError;

/// Expected sample rate for all STT providers.
pub const TARGET_SAMPLE_RATE: u32 = 16_000;

/// Minimum RMS energy to consider a frame as non-silent.
const SILENCE_THRESHOLD: f32 = 0.01;

/// Frame size in samples for silence detection (20ms at 16kHz).
const FRAME_SIZE: usize = 320;

/// Frames of trailing silence to keep so we don't clip the natural
/// fade-out of speech (e.g. fricatives, plosives).
const TRAILING_SILENCE_PAD_FRAMES: usize = 3;

/// Result of preprocessing an audio buffer.
#[derive(Debug, Clone)]
pub struct PreprocessedAudio {
    /// Audio samples ready to feed into the STT model.
    pub samples: Vec<f32>,
    /// How many seconds of leading silence were trimmed from the
    /// original buffer. Add this to any STT-returned timestamps to
    /// get them in the original buffer's time base.
    pub leading_trim_secs: f64,
}

/// Validate audio format and trim silence at the edges.
///
/// The returned samples are still in the [-1.0, 1.0] f32 range with
/// the original dynamic range preserved — no normalization, no
/// pre-emphasis, no noise gating. The STT crate handles all of that.
pub fn preprocess(samples: &[f32], sample_rate: u32) -> Result<PreprocessedAudio, CoreError> {
    if sample_rate != TARGET_SAMPLE_RATE {
        return Err(CoreError::AudioError(format!(
            "Expected {}Hz audio, got {}Hz. Resample before sending to engine.",
            TARGET_SAMPLE_RATE, sample_rate
        )));
    }

    if samples.is_empty() {
        return Err(CoreError::AudioError("Empty audio buffer".into()));
    }

    let start = find_first_voiced_frame(samples)
        .ok_or_else(|| CoreError::AudioError("Audio contains only silence".into()))?;
    let raw_end = find_last_voiced_frame(samples)
        .ok_or_else(|| CoreError::AudioError("Audio contains only silence".into()))?;
    let end = (raw_end + FRAME_SIZE * TRAILING_SILENCE_PAD_FRAMES).min(samples.len());

    if start >= end {
        return Err(CoreError::AudioError("Audio contains only silence".into()));
    }

    Ok(PreprocessedAudio {
        samples: samples[start..end].to_vec(),
        leading_trim_secs: start as f64 / sample_rate as f64,
    })
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
    let num_frames = samples.len().div_ceil(FRAME_SIZE);
    for i in (0..num_frames).rev() {
        let start = i * FRAME_SIZE;
        let end = (start + FRAME_SIZE).min(samples.len());
        if rms(&samples[start..end]) > SILENCE_THRESHOLD {
            return Some(end);
        }
    }
    None
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
    fn test_preprocess_only_silence() {
        let samples = vec![0.0f32; 16_000];
        assert!(preprocess(&samples, 16000).is_err());
    }

    #[test]
    fn test_preprocess_preserves_dynamic_range() {
        // Build 1s of audio with leading silence, mid-level signal, trailing silence.
        let mut samples = vec![0.0f32; 320 * 5]; // 100ms silence
        samples.extend(vec![0.3f32; 320 * 10]); // 200ms quiet speech
        samples.extend(vec![0.0f32; 320 * 5]); // 100ms trailing silence

        let result = preprocess(&samples, 16000).expect("preprocess");

        // The signal samples must NOT be re-scaled to peak 1.0 — they
        // should still be ~0.3.
        let max_after = result
            .samples
            .iter()
            .map(|s| s.abs())
            .fold(0.0f32, f32::max);
        assert!(
            (max_after - 0.3).abs() < 1e-3,
            "peak normalization should be removed; got max {max_after}"
        );

        // Leading silence (5 frames * 320 samples) should be trimmed.
        assert!(result.leading_trim_secs > 0.0);
        assert!((result.leading_trim_secs - (5.0 * 320.0 / 16000.0)).abs() < 1e-6);
    }

    #[test]
    fn test_preprocess_no_leading_silence() {
        let samples = vec![0.5f32; 320 * 10];
        let result = preprocess(&samples, 16000).expect("preprocess");
        assert_eq!(result.leading_trim_secs, 0.0);
    }
}
