//! Shared model weights with independent state for each recording.
use crate::{
    speech::SpeechLanguage,
    stt::streaming::{StreamChunkResult, StreamingProvider, StreamingSession},
    CoreError,
};
use parakeet_rs::{Nemotron, NemotronHandle, NemotronMode};
use std::path::Path;

pub struct NemotronProvider {
    handle: NemotronHandle,
    model_id: String,
    language: SpeechLanguage,
}
impl std::fmt::Debug for NemotronProvider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NemotronProvider")
            .field("model_id", &self.model_id)
            .finish()
    }
}
impl NemotronProvider {
    pub fn new(directory: &Path, id: &str) -> Result<Self, CoreError> {
        Self::load(directory, id, SpeechLanguage::Automatic, 0)
    }
    pub fn load(
        directory: &Path,
        id: &str,
        language: SpeechLanguage,
        threads: u32,
    ) -> Result<Self, CoreError> {
        for file in [
            "encoder.onnx",
            "encoder.onnx.data",
            "decoder_joint.onnx",
            "tokenizer.model",
        ] {
            if !directory.join(file).is_file() {
                return Err(CoreError::ModelNotFound(format!(
                    "Missing Nemotron file {file}"
                )));
            }
        }
        let handle = NemotronHandle::from_pretrained(
            directory,
            Some(
                parakeet_rs::ExecutionConfig::default().with_intra_threads(if threads == 0 {
                    4
                } else {
                    threads as usize
                }),
            ),
        )
        .map_err(|e| CoreError::ModelLoadFailed(e.to_string()))?;
        if language == SpeechLanguage::Swedish && handle.mode() == NemotronMode::EnglishOnly {
            return Err(CoreError::ConfigError(
                "Swedish preview requires the multilingual Nemotron model".into(),
            ));
        }
        Ok(Self {
            handle,
            model_id: id.into(),
            language,
        })
    }
    /// Share weights while choosing a language for an independent session.
    pub fn start_session_for_language(
        &self,
        language: SpeechLanguage,
    ) -> Result<Box<dyn StreamingSession>, CoreError> {
        if language == SpeechLanguage::Swedish && self.handle.mode() == NemotronMode::EnglishOnly {
            return Err(CoreError::ConfigError(
                "Swedish preview requires the multilingual model".into(),
            ));
        }
        let mut model = Nemotron::from_shared(&self.handle);
        if model.mode() == NemotronMode::Multilingual {
            model
                .set_target_lang(language.target())
                .map_err(|e| CoreError::ModelLoadFailed(e.to_string()))?;
        }
        Ok(Box::new(NemotronSession { model }))
    }
}
impl StreamingProvider for NemotronProvider {
    fn start_session(&self) -> Result<Box<dyn StreamingSession>, CoreError> {
        self.start_session_for_language(self.language)
    }

    fn name(&self) -> &str {
        &self.model_id
    }
    fn is_loaded(&self) -> bool {
        true
    }
    fn native_chunk_samples(&self) -> usize {
        self.handle.chunk_samples()
    }
}
struct NemotronSession {
    model: Nemotron,
}
impl StreamingSession for NemotronSession {
    fn feed_chunk(&mut self, audio: &[f32]) -> Result<StreamChunkResult, CoreError> {
        let text = self
            .model
            .transcribe_chunk(audio)
            .map_err(|e| CoreError::TranscriptionFailed(e.to_string()))?;
        Ok(StreamChunkResult { text })
    }
    fn current_transcript(&self) -> String {
        self.model.get_transcript()
    }
    fn reset(&mut self) {
        self.model.reset();
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn missing_model_is_rejected() {
        let directory = tempfile::tempdir().unwrap();
        assert!(NemotronProvider::new(directory.path(), "nemotron-test").is_err());
    }
}
