/// Voice Activity Detection.
///
/// Currently provides a single concrete implementation, [`EnergyVad`],
/// which is a hysteresis-based energy detector. It is not as robust on
/// noisy audio as a learned model like Silero VAD, but it has zero
/// runtime dependencies and is significantly better than the naive
/// "RMS > threshold" silence trimmer that audio::preprocess used to do.
///
/// The [`Vad`] trait is here so a future Silero ONNX implementation
/// can drop in without churning the engine. The trait operates on
/// 16 kHz mono f32 PCM and returns coarse [`VoicedRange`] spans.
///
/// Algorithm (EnergyVad):
///   1. Walk the audio in fixed 20 ms frames.
///   2. Compute frame RMS.
///   3. State machine with two thresholds — `enter_threshold` to flip
///      from silence → voice (must be exceeded for at least
///      `min_voiced_frames` consecutive frames) and `exit_threshold`
///      (much lower) to flip back, with at least `min_silence_frames`
///      consecutive low frames so brief pauses inside speech don't
///      cut a sentence in half.
///   4. Pad the resulting voiced ranges by `pad_frames` on each side
///      so we never clip leading consonants or trailing fricatives.
///
/// This is essentially what whisper.cpp's `examples/stream/stream.cpp`
/// does with `vad_thold` (≈0.6) but with explicit hysteresis instead
/// of a single threshold, which avoids chattering on noisy speech
/// boundaries.
///
/// Why not Silero now? Bundling and downloading a ~2 MB ONNX file plus
/// wiring an `ort` session through the engine is its own PR. The trait
/// boundary in this file is the place that PR will plug into.
use crate::CoreError;

/// A half-open span of voiced audio in sample units.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VoicedRange {
    pub start: usize,
    pub end: usize,
}

impl VoicedRange {
    pub fn len(&self) -> usize {
        self.end.saturating_sub(self.start)
    }

    pub fn is_empty(&self) -> bool {
        self.start >= self.end
    }
}

pub trait Vad {
    /// Return the voiced spans inside `samples` (16 kHz mono f32).
    /// Empty result means "no speech detected".
    fn voiced_ranges(&self, samples: &[f32]) -> Result<Vec<VoicedRange>, CoreError>;
}

/// Hysteresis-based energy VAD.
#[derive(Debug, Clone)]
pub struct EnergyVad {
    /// Frame size in samples (20 ms at 16 kHz = 320).
    pub frame_size: usize,
    /// RMS that must be exceeded to enter the voiced state.
    pub enter_threshold: f32,
    /// RMS below which we count toward leaving the voiced state.
    /// Should be considerably lower than `enter_threshold` to avoid
    /// chattering on noisy speech boundaries.
    pub exit_threshold: f32,
    /// Number of consecutive above-enter frames required to flip
    /// silence → voice. Filters out single-frame clicks.
    pub min_voiced_frames: usize,
    /// Number of consecutive below-exit frames required to flip
    /// voice → silence. Lets natural pauses (commas, breaths) keep
    /// the speaker engaged.
    pub min_silence_frames: usize,
    /// Padding frames added on each side of every voiced span so
    /// we don't clip leading consonants / trailing fricatives.
    pub pad_frames: usize,
}

impl Default for EnergyVad {
    fn default() -> Self {
        Self {
            frame_size: 320,        // 20 ms @ 16 kHz
            enter_threshold: 0.015, // ~ -36 dBFS
            exit_threshold: 0.005,  // ~ -46 dBFS
            min_voiced_frames: 3,   // 60 ms — kills clicks/pops
            min_silence_frames: 25, // 500 ms — natural pause tolerance
            pad_frames: 4,          // 80 ms padding
        }
    }
}

impl Vad for EnergyVad {
    fn voiced_ranges(&self, samples: &[f32]) -> Result<Vec<VoicedRange>, CoreError> {
        if samples.is_empty() || self.frame_size == 0 {
            return Ok(Vec::new());
        }

        // Frame-level RMS sweep.
        let frame_count = samples.len().div_ceil(self.frame_size);
        let mut frame_rms = Vec::with_capacity(frame_count);
        for i in 0..frame_count {
            let start = i * self.frame_size;
            let end = (start + self.frame_size).min(samples.len());
            frame_rms.push(rms(&samples[start..end]));
        }

        // State machine over frames.
        let mut ranges: Vec<VoicedRange> = Vec::new();
        let mut in_voice = false;
        let mut voice_run_start: usize = 0;
        let mut consecutive_above: usize = 0;
        let mut consecutive_below: usize = 0;

        for (i, &r) in frame_rms.iter().enumerate() {
            if !in_voice {
                if r > self.enter_threshold {
                    consecutive_above += 1;
                    if consecutive_above >= self.min_voiced_frames {
                        in_voice = true;
                        // Range starts at the first frame of the run.
                        voice_run_start = i + 1 - consecutive_above;
                        consecutive_below = 0;
                    }
                } else {
                    consecutive_above = 0;
                }
            } else {
                if r < self.exit_threshold {
                    consecutive_below += 1;
                    if consecutive_below >= self.min_silence_frames {
                        // End of voiced run is the frame just before
                        // this silence run started.
                        let run_end = i + 1 - consecutive_below;
                        ranges.push(VoicedRange {
                            start: frame_to_sample(voice_run_start, self.frame_size),
                            end: frame_to_sample(run_end, self.frame_size).min(samples.len()),
                        });
                        in_voice = false;
                        consecutive_above = 0;
                        consecutive_below = 0;
                    }
                } else {
                    consecutive_below = 0;
                }
            }
        }

        // Close any open range at end-of-input.
        if in_voice {
            ranges.push(VoicedRange {
                start: frame_to_sample(voice_run_start, self.frame_size),
                end: samples.len(),
            });
        }

        // Pad each range and merge any that overlap as a result.
        let pad_samples = self.pad_frames * self.frame_size;
        let mut padded: Vec<VoicedRange> = ranges
            .into_iter()
            .map(|r| VoicedRange {
                start: r.start.saturating_sub(pad_samples),
                end: (r.end + pad_samples).min(samples.len()),
            })
            .collect();

        padded.sort_by_key(|r| r.start);
        let mut merged: Vec<VoicedRange> = Vec::new();
        for r in padded {
            if let Some(last) = merged.last_mut() {
                if r.start <= last.end {
                    last.end = last.end.max(r.end);
                    continue;
                }
            }
            merged.push(r);
        }

        Ok(merged)
    }
}

fn frame_to_sample(frame_idx: usize, frame_size: usize) -> usize {
    frame_idx * frame_size
}

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

    fn vad() -> EnergyVad {
        EnergyVad::default()
    }

    fn signal(amp: f32, frames: usize) -> Vec<f32> {
        vec![amp; frames * 320]
    }

    fn silence(frames: usize) -> Vec<f32> {
        vec![0.0; frames * 320]
    }

    #[test]
    fn empty_input_returns_no_ranges() {
        assert!(vad().voiced_ranges(&[]).unwrap().is_empty());
    }

    #[test]
    fn pure_silence_returns_no_ranges() {
        let s = silence(50);
        assert!(vad().voiced_ranges(&s).unwrap().is_empty());
    }

    #[test]
    fn pure_loud_signal_returns_one_range_covering_everything() {
        let v = vad();
        let s = signal(0.5, 50);
        let r = v.voiced_ranges(&s).unwrap();
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].start, 0);
        assert_eq!(r[0].end, s.len());
    }

    #[test]
    fn brief_pause_inside_speech_does_not_split_segment() {
        let v = vad();
        // 20 frames of speech, 10 frames of silence (200 ms,
        // < min_silence_frames=25), 20 frames of speech.
        let mut s = signal(0.5, 20);
        s.extend(silence(10));
        s.extend(signal(0.5, 20));
        let r = v.voiced_ranges(&s).unwrap();
        // The brief pause is below min_silence_frames so we get one
        // merged range.
        assert_eq!(r.len(), 1, "expected one merged range, got {:?}", r);
    }

    #[test]
    fn long_pause_splits_segment() {
        let v = vad();
        let mut s = signal(0.5, 20);
        s.extend(silence(60)); // 1.2 s — well above 500 ms
        s.extend(signal(0.5, 20));
        let r = v.voiced_ranges(&s).unwrap();
        assert_eq!(r.len(), 2);
        assert!(r[0].end < r[1].start);
    }

    #[test]
    fn single_frame_click_does_not_register_as_speech() {
        let v = vad();
        let mut s = silence(20);
        // One frame above enter — should be ignored (need >=3 frames).
        s.extend(signal(0.5, 1));
        s.extend(silence(20));
        let r = v.voiced_ranges(&s).unwrap();
        assert!(r.is_empty(), "expected click to be ignored, got {:?}", r);
    }

    #[test]
    fn padding_adds_to_both_sides() {
        let v = EnergyVad {
            pad_frames: 2,
            ..EnergyVad::default()
        };
        // 30 frames silence, 10 frames speech, 30 frames silence.
        let mut s = silence(30);
        s.extend(signal(0.5, 10));
        s.extend(silence(30));
        let r = v.voiced_ranges(&s).unwrap();
        assert_eq!(r.len(), 1);
        // Range should start ~2 frames before the speech and end
        // ~2 frames after.
        assert!(r[0].start < 30 * 320);
        assert!(r[0].end > 40 * 320);
    }

    #[test]
    fn voiced_range_len_is_correct() {
        let r = VoicedRange { start: 100, end: 250 };
        assert_eq!(r.len(), 150);
        assert!(!r.is_empty());

        let empty = VoicedRange { start: 50, end: 50 };
        assert!(empty.is_empty());
        assert_eq!(empty.len(), 0);
    }
}
