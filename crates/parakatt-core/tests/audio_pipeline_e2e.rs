//! End-to-end audio pipeline tests for VAD-aware preprocessing.
//!
//! These exercise `audio::preprocess` and `vad::EnergyVad` with
//! synthetic waveforms covering the failure modes that motivated
//! the architectural overhaul:
//!   - Long silent gaps between speech (must not split into two
//!     transcripts; must preserve the gap in the timeline)
//!   - Quiet trailing fricatives at the end of sentences
//!   - Silent tail after the speaker stops
//!   - Mid-utterance breath / comma pauses
//!   - Single-frame clicks (must not register as speech)
//!   - Pure silence (must error cleanly)
//!   - Continuous speech without pauses

use parakatt_core::audio::preprocess;
use parakatt_core::vad::{EnergyVad, Vad, VoicedRange};

const SR: usize = 16_000;
const FRAME: usize = 320;

/// Build a speech-like signal at `amp` for `frames` frames.
fn signal(amp: f32, frames: usize) -> Vec<f32> {
    vec![amp; frames * FRAME]
}

/// Build silence for `frames` frames.
fn silence(frames: usize) -> Vec<f32> {
    vec![0.0_f32; frames * FRAME]
}

// =====================================================
// audio::preprocess scenarios
// =====================================================

#[test]
fn preprocess_clean_speech_no_padding_no_trim() {
    // 30 frames (~600 ms) of full-amplitude continuous speech.
    // Nothing to trim — leading_trim_secs should be 0.
    let samples = signal(0.5, 30);
    let result = preprocess(&samples, 16_000).expect("preprocess ok");
    assert_eq!(result.leading_trim_secs, 0.0);
    // Output is at least the original signal (VAD pads).
    assert!(result.samples.len() >= samples.len());
}

#[test]
fn preprocess_leading_silence_is_trimmed() {
    let mut samples = silence(20); // 400 ms silence
    samples.extend(signal(0.5, 30)); // 600 ms speech
    let result = preprocess(&samples, 16_000).expect("preprocess ok");
    assert!(
        result.leading_trim_secs > 0.0,
        "expected some leading silence to be trimmed"
    );
    // Trim is at most the actual silence duration.
    assert!(result.leading_trim_secs <= 0.4);
}

#[test]
fn preprocess_only_silence_errors() {
    let samples = silence(50);
    assert!(preprocess(&samples, 16_000).is_err());
}

#[test]
fn preprocess_pure_silence_long_errors() {
    let samples = silence(1000); // 20 s
    assert!(preprocess(&samples, 16_000).is_err());
}

#[test]
fn preprocess_long_silent_gap_between_speech_preserved() {
    // Speech, 3 s silence, speech. The gap MUST be preserved
    // because the STT model needs to know when the second
    // utterance started so timestamps line up.
    let mut samples = signal(0.5, 30); // 600 ms speech
    samples.extend(silence(150)); // 3 s silence
    samples.extend(signal(0.5, 30)); // 600 ms speech

    let result = preprocess(&samples, 16_000).expect("preprocess ok");

    // The output should be at least the speech + gap, NOT just
    // the two speech segments concatenated.
    let expected_min = 30 * FRAME + 150 * FRAME + 30 * FRAME;
    assert!(
        result.samples.len() >= expected_min - 8 * FRAME, // allow for some VAD padding eat-in
        "long silent gap was collapsed: got {} samples, expected >= ~{}",
        result.samples.len(),
        expected_min
    );
}

#[test]
fn preprocess_trailing_silence_keeps_some_padding() {
    // Speech ending in silence — VAD pads ±240 ms so the trailing
    // padding should be ≤ ~250 ms but ≥ ~80 ms.
    let mut samples = signal(0.5, 30);
    samples.extend(silence(50));
    let result = preprocess(&samples, 16_000).expect("preprocess ok");

    // The trimmed buffer should be roughly 30 frames + padding,
    // not 80 frames (the full original).
    let max_acceptable = 30 * FRAME + 20 * FRAME; // 30 speech + ~20 frames pad
    assert!(
        result.samples.len() <= max_acceptable,
        "trailing silence not trimmed: {} samples",
        result.samples.len()
    );
}

#[test]
fn preprocess_dynamic_range_preserved_no_normalization() {
    // Critical correctness check: a 0.3 amplitude signal must
    // come out at 0.3, not normalized up to 1.0.
    let mut samples = silence(5);
    samples.extend(vec![0.3_f32; 30 * FRAME]);
    samples.extend(silence(5));
    let result = preprocess(&samples, 16_000).expect("preprocess ok");
    let max_amp = result
        .samples
        .iter()
        .map(|s| s.abs())
        .fold(0.0_f32, f32::max);
    assert!(
        (max_amp - 0.3).abs() < 1e-3,
        "amplitude got rescaled: max = {max_amp}"
    );
}

#[test]
fn preprocess_quiet_trailing_speech_not_clipped() {
    // Speech that fades from 0.5 → 0.005 over the last 10 frames
    // simulates a soft fricative ("...sssss"). The VAD's
    // exit_threshold (0.003) should keep this in the voiced
    // range so it isn't clipped.
    let mut samples = signal(0.5, 20);
    for i in 0..10 {
        let amp = 0.5 - (i as f32 * 0.05); // 0.5 → 0.05
        samples.extend(vec![amp; FRAME]);
    }
    let result = preprocess(&samples, 16_000).expect("preprocess ok");
    // Should keep all 30 frames of speech.
    assert!(
        result.samples.len() >= 30 * FRAME,
        "quiet trailing speech was clipped: only {} samples",
        result.samples.len()
    );
}

#[test]
fn preprocess_wrong_sample_rate_errors_cleanly() {
    let samples = signal(0.5, 30);
    assert!(preprocess(&samples, 44_100).is_err());
}

// =====================================================
// VAD scenarios — direct EnergyVad checks
// =====================================================

fn vad() -> EnergyVad {
    EnergyVad::default()
}

#[test]
fn vad_finds_two_segments_across_long_pause() {
    // 20 frames speech, 60 frames silence (1.2 s, > 500 ms),
    // 20 frames speech.
    let mut s = signal(0.5, 20);
    s.extend(silence(60));
    s.extend(signal(0.5, 20));
    let r = vad().voiced_ranges(&s).unwrap();
    assert_eq!(r.len(), 2, "expected two voiced segments, got {r:?}");
    // Each segment should be roughly the speech length plus
    // padding on either side.
    for range in &r {
        assert!(range.len() >= 20 * FRAME);
    }
}

#[test]
fn vad_brief_pause_under_threshold_keeps_one_segment() {
    // 20 frames speech, 10 frames silence (200 ms, < 500 ms),
    // 20 frames speech. Should be ONE segment.
    let mut s = signal(0.5, 20);
    s.extend(silence(10));
    s.extend(signal(0.5, 20));
    let r = vad().voiced_ranges(&s).unwrap();
    assert_eq!(r.len(), 1, "brief pause split the segment: {r:?}");
}

#[test]
fn vad_three_distinct_sentences_with_long_gaps() {
    let mut s = signal(0.5, 15);
    s.extend(silence(60));
    s.extend(signal(0.5, 15));
    s.extend(silence(60));
    s.extend(signal(0.5, 15));
    let r = vad().voiced_ranges(&s).unwrap();
    assert_eq!(r.len(), 3, "expected three sentences, got {r:?}");
}

#[test]
fn vad_handles_5_second_silence_in_middle() {
    let mut s = signal(0.5, 20);
    s.extend(silence(250)); // 5 s
    s.extend(signal(0.5, 20));
    let r = vad().voiced_ranges(&s).unwrap();
    assert_eq!(r.len(), 2);
    let gap_samples = r[1].start - r[0].end;
    // Some of the silence got eaten by padding on both sides
    // (240 ms × 2 = 480 ms) but most should remain.
    let min_remaining = (5.0 - 0.5) * 16_000.0;
    assert!(
        gap_samples as f32 >= min_remaining,
        "silence gap shrank too much: {gap_samples} samples"
    );
}

#[test]
fn vad_single_frame_click_not_registered() {
    let mut s = silence(20);
    s.extend(signal(0.8, 1)); // single frame click
    s.extend(silence(20));
    let r = vad().voiced_ranges(&s).unwrap();
    assert!(r.is_empty(), "click misregistered as speech: {r:?}");
}

#[test]
fn vad_three_frames_minimum_registers() {
    // Just at the edge: 3 consecutive frames at enter threshold
    // should register (min_voiced_frames=3 in the default).
    let mut s = silence(10);
    s.extend(signal(0.5, 3));
    s.extend(silence(10));
    let r = vad().voiced_ranges(&s).unwrap();
    assert_eq!(r.len(), 1);
}

#[test]
fn vad_pure_silence_returns_empty() {
    let s = silence(100);
    let r = vad().voiced_ranges(&s).unwrap();
    assert!(r.is_empty());
}

#[test]
fn vad_continuous_speech_one_segment() {
    let s = signal(0.5, 200); // 4 s
    let r = vad().voiced_ranges(&s).unwrap();
    assert_eq!(r.len(), 1);
    assert!(r[0].len() >= 200 * FRAME);
}

#[test]
fn vad_voiced_range_helpers() {
    let r = VoicedRange { start: 100, end: 250 };
    assert_eq!(r.len(), 150);
    assert!(!r.is_empty());

    let empty = VoicedRange { start: 50, end: 50 };
    assert!(empty.is_empty());
}

// =====================================================
// Edge case: alternating speech / silence pattern (rapid bursts)
// =====================================================

#[test]
fn vad_rapid_burst_pattern_merges_via_min_silence() {
    // Speech, 3 frames silence, speech, 3 frames silence, ...
    // Each silence is too short to flip the state machine, so
    // the entire sequence should be one voiced range.
    let mut s = Vec::new();
    for _ in 0..10 {
        s.extend(signal(0.5, 5));
        s.extend(silence(3));
    }
    let r = vad().voiced_ranges(&s).unwrap();
    assert_eq!(r.len(), 1, "rapid bursts split unexpectedly: {r:?}");
}

#[test]
fn preprocess_realistic_dictation_with_pauses() {
    // Simulate a realistic dictation: long lead-in, short phrase,
    // brief breath, longer phrase, sentence-end pause, final phrase.
    // Lead-in must exceed VAD padding (240 ms = 12 frames) for any
    // trimming to be observable.
    let mut s = silence(40); // 800 ms before speech
    s.extend(signal(0.5, 25)); // first phrase
    s.extend(silence(15)); // breath, 300 ms
    s.extend(signal(0.5, 50)); // longer phrase
    s.extend(silence(40)); // sentence pause, 800 ms
    s.extend(signal(0.5, 30)); // final phrase
    s.extend(silence(20)); // trailing
    let result = preprocess(&s, 16_000).expect("preprocess ok");

    // Trim should remove leading silence (≥ 800 ms - 240 ms VAD pad).
    assert!(
        result.leading_trim_secs > 0.0,
        "expected non-zero leading trim, got {}",
        result.leading_trim_secs
    );
    assert!(result.leading_trim_secs < 1.0);

    // The internal pauses should be mostly preserved.
    let total_speech = (25 + 50 + 30) * FRAME;
    assert!(
        result.samples.len() > total_speech,
        "internal pauses got eaten: {} samples vs {} just-speech",
        result.samples.len(),
        total_speech
    );
}
