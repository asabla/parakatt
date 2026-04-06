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
/// 2. Run a Voice Activity Detector (`EnergyVad`) to find the
///    longest voiced span in the buffer. We feed only that span to
///    the STT model so we don't waste encoder time on silence and
///    so chunk timestamps don't include leading silence padding.
///    The amount of leading silence trimmed is reported back so
///    callers can offset STT-returned timestamps accordingly.
use crate::vad::{EnergyVad, Vad};
use crate::CoreError;

/// Expected sample rate for all STT providers.
pub const TARGET_SAMPLE_RATE: u32 = 16_000;

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

/// Validate audio format and isolate the voiced span via VAD.
///
/// The returned samples are still in the [-1.0, 1.0] f32 range with
/// the original dynamic range preserved — no normalization, no
/// pre-emphasis. The STT crate handles all of that.
///
/// VAD takes the union of all voiced ranges from the [`EnergyVad`]
/// and emits the buffer from the first voiced sample to the last,
/// preserving any internal pauses (so within-utterance pauses don't
/// confuse the STT decoder's contextual state).
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

    let vad = EnergyVad::default();
    let ranges = vad.voiced_ranges(samples)?;

    if ranges.is_empty() {
        return Err(CoreError::AudioError("Audio contains only silence".into()));
    }

    let start = ranges.first().map(|r| r.start).unwrap_or(0);
    let end = ranges.last().map(|r| r.end).unwrap_or(samples.len());

    if start >= end {
        return Err(CoreError::AudioError("Audio contains only silence".into()));
    }

    Ok(PreprocessedAudio {
        samples: samples[start..end].to_vec(),
        leading_trim_secs: start as f64 / sample_rate as f64,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

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
        // Build ~1s of audio: 100 ms of silence, 200 ms of speech-like
        // signal at 0.3, 100 ms of trailing silence. The VAD should
        // identify the middle as voiced and we should NOT see the
        // amplitude rescaled (peak normalization is gone).
        let mut samples = vec![0.0f32; 320 * 5];
        samples.extend(vec![0.3f32; 320 * 20]);
        samples.extend(vec![0.0f32; 320 * 5]);

        let result = preprocess(&samples, 16000).expect("preprocess");

        let max_after = result
            .samples
            .iter()
            .map(|s| s.abs())
            .fold(0.0f32, f32::max);
        assert!(
            (max_after - 0.3).abs() < 1e-3,
            "peak normalization should be removed; got max {max_after}"
        );

        // Some leading silence should have been trimmed by the VAD,
        // accounting for VAD padding (default 4 frames = ~80 ms).
        assert!(result.leading_trim_secs >= 0.0);
        assert!(result.leading_trim_secs < 0.1);
    }

    #[test]
    fn test_preprocess_no_leading_silence() {
        // 30 frames of full-amplitude continuous signal — VAD won't
        // need to trim anything from the head.
        let samples = vec![0.5f32; 320 * 30];
        let result = preprocess(&samples, 16000).expect("preprocess");
        assert_eq!(result.leading_trim_secs, 0.0);
    }
}
