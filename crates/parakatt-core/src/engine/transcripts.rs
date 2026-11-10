use super::*;
use crate::transcript_import::{
    TranscriptImportRequest, TranscriptImportResult, TranscriptOrigin, TranscriptUtterance,
};

#[uniffi::export]
impl Engine {
    pub fn add_meeting_action(
        &self,
        id: String,
        text: String,
        owner: Option<String>,
        due_date: Option<String>,
        source_utterance: u32,
    ) -> Result<crate::meeting_actions::MeetingAction, CoreError> {
        crate::util::lock_named(&self.storage, "storage", CoreError::IoError)?.add_meeting_action(
            &id,
            &text,
            owner,
            due_date,
            source_utterance,
        )
    }
    pub fn get_meeting_actions(
        &self,
        id: String,
    ) -> Result<Vec<crate::meeting_actions::MeetingAction>, CoreError> {
        crate::util::lock_named(&self.storage, "storage", CoreError::IoError)?.meeting_actions(&id)
    }
    pub fn complete_meeting_action(
        &self,
        id: String,
        action_id: String,
        completed: bool,
    ) -> Result<(), CoreError> {
        crate::util::lock_named(&self.storage, "storage", CoreError::IoError)?
            .complete_meeting_action(&id, &action_id, completed)
    }
    pub fn import_transcript(
        &self,
        request: TranscriptImportRequest,
    ) -> Result<TranscriptImportResult, CoreError> {
        crate::util::lock_named(&self.storage, "storage", CoreError::IoError)?
            .import_transcript(&request)
    }
    pub fn get_transcript_origin(&self, id: String) -> Result<TranscriptOrigin, CoreError> {
        crate::util::lock_named(&self.storage, "storage", CoreError::IoError)?
            .transcript_origin(&id)
    }
    pub fn get_imported_utterances(
        &self,
        id: String,
    ) -> Result<Vec<TranscriptUtterance>, CoreError> {
        crate::util::lock_named(&self.storage, "storage", CoreError::IoError)?
            .imported_utterances(&id)
    }
    pub fn set_transcript_speaker_alias(
        &self,
        id: String,
        original: String,
        display: String,
    ) -> Result<(), CoreError> {
        crate::util::lock_named(&self.storage, "storage", CoreError::IoError)?
            .set_speaker_alias(&id, &original, &display)
    }
}
