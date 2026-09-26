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
        if !model_dir.exists() {
            return Err(CoreError::ModelNotFound(format!(
                "Model directory not found: {}",
                model_dir.display()
            )));
        }

        let (model, accelerated) = match Self::create(model_dir, backend, threads) {
            Ok(model) => (model, backend == SpeechBackend::WebGpu),
            Err(error) if backend == SpeechBackend::WebGpu && fallback => {
                log::warn!("WebGPU initialization failed; using CPU: {error}");
                (Self::create(model_dir, SpeechBackend::Cpu, threads)?, false)
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
        })
    }
    fn create(path: &Path, backend: SpeechBackend, threads: u32) -> Result<ParakeetTDT, CoreError> {
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
        ParakeetTDT::from_pretrained_with_joint_config(path, Some(encoder), Some(cpu))
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
        self.transcribe_timed(audio, sample_rate, TimestampMode::Sentences)
    }

    fn transcribe_import(
        &self,
        audio: &[f32],
        sample_rate: u32,
    ) -> Result<TranscriptionResult, CoreError> {
        self.transcribe_timed(audio, sample_rate, TimestampMode::Words)
    }

    fn name(&self) -> &str {
        &self.model_id
    }

    fn is_loaded(&self) -> bool {
        true
    }
}

impl ParakeetProvider {
    fn transcribe_timed(
        &self,
        audio: &[f32],
        sample_rate: u32,
        timestamp_mode: TimestampMode,
    ) -> Result<TranscriptionResult, CoreError> {
        let start = std::time::Instant::now();

        let mut model = self.model.lock().map_err(|e| {
            CoreError::TranscriptionFailed(format!("Failed to acquire model lock: {e}"))
        })?;

        let result = infer_with_fallback(
            &mut *model,
            &self.accelerated,
            |model| {
                model
                    .transcribe_samples(audio.to_vec(), sample_rate, 1, Some(timestamp_mode))
                    .map_err(|e| CoreError::TranscriptionFailed(e.to_string()))
            },
            || Self::create(&self.directory, SpeechBackend::Cpu, self.threads),
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
            &text
        );

        Ok(TranscriptionResult {
            text,
            duration_secs: audio.len() as f64 / sample_rate as f64,
            provider_name: self.name().to_string(),
            segments,
            llm_error: None,
        })
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
