use crate::speech::SpeechBackend;
use parakeet_rs::ExecutionConfig;
/// Parakeet TDT STT provider using parakeet-rs (NVIDIA Parakeet via ONNX Runtime).
///
/// Runs on CPU which is fast enough on Apple Silicon.
/// The model directory should contain:
/// - encoder-model.onnx + encoder-model.onnx.data
/// - decoder_joint-model.onnx
/// - vocab.txt
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use parakeet_rs::{ParakeetTDT, TimestampMode, Transcriber};

use crate::{CoreError, TimestampedSegment, TranscriptionResult};

use super::SttProvider;

pub struct ParakeetProvider {
    model: Mutex<ParakeetTDT>,
    model_id: String,
    directory: PathBuf,
    accelerated: AtomicBool,
    threads: u32,
    decoder_threads: u32,
}

/// Local benchmark measurements. Encoder time includes host/device transfers.
#[derive(Debug, Default, serde::Serialize)]
pub struct ParakeetProfile {
    pub lock_wait_secs: f64,
    #[serde(flatten)]
    pub inference: parakeet_rs::InferenceTimings,
}

impl ParakeetProvider {
    /// Load a Parakeet TDT model from a directory containing ONNX files.
    pub fn load(model_dir: &Path, model_id: &str) -> Result<Self, CoreError> {
        Self::load_with_backend(model_dir, model_id, SpeechBackend::Cpu, 0, true)
    }
    pub fn load_with_backend(
        model_dir: &Path,
        model_id: &str,
        backend: SpeechBackend,
        threads: u32,
        fallback: bool,
    ) -> Result<Self, CoreError> {
        Self::load_with_thread_counts(model_dir, model_id, backend, threads, threads, fallback)
    }

    /// Benchmark separate session thread counts without changing saved settings.
    pub fn load_with_thread_counts(
        model_dir: &Path,
        model_id: &str,
        backend: SpeechBackend,
        threads: u32,
        decoder_threads: u32,
        fallback: bool,
    ) -> Result<Self, CoreError> {
        if !model_dir.exists() {
            return Err(CoreError::ModelNotFound(format!(
                "Model directory not found: {}",
                model_dir.display()
            )));
        }

        let (model, accelerated) = match Self::create(model_dir, backend, threads, decoder_threads)
        {
            Ok(model) => (model, backend == SpeechBackend::WebGpu),
            Err(error) if backend == SpeechBackend::WebGpu && fallback => {
                log::warn!("WebGPU initialization failed; using CPU: {error}");
                (
                    Self::create(model_dir, SpeechBackend::Cpu, threads, decoder_threads)?,
                    false,
                )
            }
            Err(error) => return Err(error),
        };

        log::info!("Loaded Parakeet TDT model: {}", model_id);

        Ok(Self {
            model: Mutex::new(model),
            model_id: model_id.to_string(),
            directory: model_dir.into(),
            accelerated: AtomicBool::new(accelerated),
            threads,
            decoder_threads,
        })
    }
    fn create(
        path: &Path,
        backend: SpeechBackend,
        threads: u32,
        decoder_threads: u32,
    ) -> Result<ParakeetTDT, CoreError> {
        let cpu = ExecutionConfig::default().with_intra_threads(if threads == 0 {
            4
        } else {
            threads as usize
        });
        let encoder = if backend == SpeechBackend::WebGpu {
            #[cfg(feature = "webgpu")]
            {
                cpu.clone().with_custom_configure(|builder| {
                    Ok(builder.with_execution_providers([ort::ep::WebGPU::default()
                        .build()
                        .error_on_failure()])?)
                })
            }
            #[cfg(not(feature = "webgpu"))]
            {
                return Err(CoreError::ModelLoadFailed(
                    "This runtime does not include WebGPU".into(),
                ));
            }
        } else {
            cpu.clone()
        };
        let decoder = cpu.with_intra_threads(if decoder_threads == 0 {
            4
        } else {
            decoder_threads as usize
        });
        ParakeetTDT::from_pretrained_with_joint_config(path, Some(encoder), Some(decoder))
            .map(|model| model.with_legacy_frontend())
            .map_err(|error| CoreError::ModelLoadFailed(error.to_string()))
    }
    pub fn actual_backend(&self) -> SpeechBackend {
        if self.accelerated.load(Ordering::Relaxed) {
            SpeechBackend::WebGpu
        } else {
            SpeechBackend::Cpu
        }
    }
}

impl SttProvider for ParakeetProvider {
    fn backend(&self) -> SpeechBackend {
        self.actual_backend()
    }
    fn transcribe(
        &self,
        audio: &[f32],
        sample_rate: u32,
    ) -> Result<TranscriptionResult, CoreError> {
        self.transcribe_timed(audio, sample_rate, TimestampMode::Sentences, false)
            .map(|(result, _)| result)
    }

    fn transcribe_import(
        &self,
        audio: &[f32],
        sample_rate: u32,
    ) -> Result<TranscriptionResult, CoreError> {
        self.transcribe_timed(audio, sample_rate, TimestampMode::Words, false)
            .map(|(result, _)| result)
    }

    fn transcribe_chunk(
        &self,
        audio: &[f32],
        sample_rate: u32,
        overlap_secs: f64,
    ) -> Result<TranscriptionResult, CoreError> {
        let (mut result, _) =
            self.transcribe_timed(audio, sample_rate, TimestampMode::Words, false)?;
        result.segments = chunk_sentences(result.segments, overlap_secs);
        result.text = result
            .segments
            .iter()
            .map(|s| s.text.as_str())
            .collect::<Vec<_>>()
            .join(" ");
        Ok(result)
    }

    fn name(&self) -> &str {
        &self.model_id
    }

    fn is_loaded(&self) -> bool {
        true
    }
}

/// Remove only words fully covered by the preceding chunk. A word that crosses
/// the boundary stays intact; sentence grouping must happen after this check.
fn chunk_sentences(words: Vec<TimestampedSegment>, overlap_secs: f64) -> Vec<TimestampedSegment> {
    crate::stt::group_timed_words(
        words
            .into_iter()
            .filter(|word| word.end_secs > overlap_secs)
            .collect(),
    )
}

impl ParakeetProvider {
    pub fn transcribe_profiled(
        &self,
        audio: &[f32],
        sample_rate: u32,
    ) -> Result<(TranscriptionResult, ParakeetProfile), CoreError> {
        self.transcribe_timed(audio, sample_rate, TimestampMode::Sentences, true)
    }

    fn transcribe_timed(
        &self,
        audio: &[f32],
        sample_rate: u32,
        timestamp_mode: TimestampMode,
        profile: bool,
    ) -> Result<(TranscriptionResult, ParakeetProfile), CoreError> {
        let start = std::time::Instant::now();
        let mut timings = ParakeetProfile::default();

        let mut model = self.model.lock().map_err(|e| {
            CoreError::TranscriptionFailed(format!("Failed to acquire model lock: {e}"))
        })?;
        if profile {
            timings.lock_wait_secs = start.elapsed().as_secs_f64();
        }

        let result = infer_with_fallback(
            &mut *model,
            &self.accelerated,
            |model| {
                if profile {
                    return model
                        .transcribe_samples_profiled(
                            audio.to_vec(),
                            sample_rate,
                            1,
                            Some(timestamp_mode),
                        )
                        .map(|(result, measured)| {
                            timings.inference = measured;
                            result
                        })
                        .map_err(|e| CoreError::TranscriptionFailed(e.to_string()));
                }
                model
                    .transcribe_samples(audio.to_vec(), sample_rate, 1, Some(timestamp_mode))
                    .map_err(|e| CoreError::TranscriptionFailed(e.to_string()))
            },
            || {
                Self::create(
                    &self.directory,
                    SpeechBackend::Cpu,
                    self.threads,
                    self.decoder_threads,
                )
            },
        )
        .map_err(|e| CoreError::TranscriptionFailed(e.to_string()))?;

        let duration = start.elapsed();
        let text = result.text.trim().to_string();

        // Keep the timing granularity requested by the caller.
        let segments: Vec<TimestampedSegment> = result
            .tokens
            .iter()
            .filter(|t| !t.text.trim().is_empty())
            .map(|t| TimestampedSegment {
                text: t.text.trim().to_string(),
                start_secs: t.start as f64,
                end_secs: t.end as f64,
                speaker: None,
            })
            .collect();

        log::debug!(
            "Parakeet transcribed {} samples in {:.2}s ({} segments): '{}'",
            audio.len(),
            duration.as_secs_f64(),
            segments.len(),
            text
        );

        Ok((
            TranscriptionResult {
                text,
                duration_secs: audio.len() as f64 / sample_rate as f64,
                provider_name: self.name().to_string(),
                segments,
                llm_error: None,
            },
            timings,
        ))
    }
}

/// Return one result after at most one CPU retry. Failed initialization keeps the
/// previous backend state so status never claims that CPU loaded successfully.
fn infer_with_fallback<M, T, E: std::fmt::Display>(
    model: &mut M,
    accelerated: &AtomicBool,
    mut infer: impl FnMut(&mut M) -> Result<T, E>,
    cpu: impl FnOnce() -> Result<M, E>,
) -> Result<T, E> {
    match infer(model) {
        Err(error) if accelerated.load(Ordering::Relaxed) => {
            log::warn!("WebGPU inference failed; retrying this audio once on CPU: {error}");
            let replacement = cpu()?;
            *model = replacement;
            accelerated.store(false, Ordering::Relaxed);
            infer(model)
        }
        result => result,
    }
}

#[cfg(test)]
mod fallback_tests {
    use super::*;
    #[test]
    fn chunk_overlap_is_removed_before_sentences_are_grouped() {
        let words = [
            ("old", 0.2, 1.0),
            ("tail", 1.0, 2.0),
            ("new", 1.95, 2.5),
            ("content.", 2.6, 8.0),
            ("Next.", 9.0, 10.0),
        ]
        .into_iter()
        .map(|(text, start_secs, end_secs)| TimestampedSegment {
            text: text.into(),
            start_secs,
            end_secs,
            speaker: None,
        })
        .collect();
        let sentences = chunk_sentences(words, 2.0);
        assert_eq!(
            sentences
                .iter()
                .map(|s| s.text.as_str())
                .collect::<Vec<_>>(),
            ["new content.", "Next."]
        );
        assert_eq!(sentences[0].start_secs, 1.95);
        assert_eq!(sentences[0].end_secs, 8.0);
    }
    #[test]
    fn failed_gpu_chunk_returns_one_cpu_result_and_next_chunk_stays_on_cpu() {
        let mut gpu = true;
        let accelerated = AtomicBool::new(true);
        let mut calls = 0;
        let text = infer_with_fallback(
            &mut gpu,
            &accelerated,
            |gpu| {
                calls += 1;
                if *gpu {
                    Err("GPU lost")
                } else {
                    Ok("one transcript")
                }
            },
            || Ok(false),
        )
        .unwrap();
        assert_eq!(text, "one transcript");
        assert_eq!(calls, 2);
        assert!(!accelerated.load(Ordering::Relaxed));
        let _: Result<(), &str> = infer_with_fallback(
            &mut gpu,
            &accelerated,
            |_| {
                calls += 1;
                Err("CPU failure")
            },
            || panic!("CPU must not retry"),
        );
        assert_eq!(calls, 3);
    }
    #[test]
    fn failed_cpu_initialization_does_not_report_a_loaded_cpu_backend() {
        let mut gpu = true;
        let accelerated = AtomicBool::new(true);
        let result: Result<(), &str> = infer_with_fallback(
            &mut gpu,
            &accelerated,
            |_| Err("GPU lost"),
            || Err("CPU unavailable"),
        );
        assert!(result.is_err());
        assert!(gpu && accelerated.load(Ordering::Relaxed));
    }
}
