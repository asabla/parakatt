# Parakatt compatibility patch

Source: crates.io parakeet-rs 0.3.8 (archive SHA-256 `4f54545a861dca6b43c8d44e3dd932764ca196d84bcf0d1b48ea212b43b29666`), unmodified package files except `src/audio.rs` and `src/parakeet_tdt.rs`.

The upstream 0.3.8 frontend centers the Hann window in the FFT buffer and omits the last feature frame. The 0.3.4 frontend starts the window at offset zero and includes that frame. On the pinned English and Swedish FLEURS corpus, the unmodified update increased WER in both languages.

This patch adds an explicit `with_legacy_frontend` option for TDT. The default upstream behavior stays unchanged. Parakatt selects the compatibility option for its existing final-transcription model. The FFT plan and mel filterbank remain cached. Nemotron is unaffected.

The acceptance comparison is recorded in the maintenance report. Do not remove this patch without passing both language accuracy gates. The original upstream license is retained.
