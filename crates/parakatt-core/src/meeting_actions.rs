//! Explicitly confirmed follow-up items, with an immutable supporting quote.
use crate::{storage::Storage, transcript_import::TranscriptUtterance, CoreError};
use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct MeetingAction {
    pub id: String,
    pub text: String,
    pub owner: Option<String>,
    pub due_date: Option<String>,
    pub completed: bool,
    pub source_utterance: u32,
    pub source_quote: String,
}

fn invalid(message: impl std::fmt::Display) -> CoreError {
    CoreError::IoError(format!("Meeting action: {message}"))
}

impl Storage {
    pub(crate) fn migrate_meeting_actions(&self) -> Result<(), CoreError> {
        self.conn.execute_batch("CREATE TABLE IF NOT EXISTS meeting_actions (
            id TEXT PRIMARY KEY, transcription_id TEXT NOT NULL REFERENCES transcriptions(id) ON DELETE CASCADE,
            payload TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS idx_meeting_actions_transcription ON meeting_actions(transcription_id);").map_err(invalid)
    }

    pub fn add_meeting_action(
        &self,
        record_id: &str,
        text: &str,
        owner: Option<String>,
        due_date: Option<String>,
        source_utterance: u32,
    ) -> Result<MeetingAction, CoreError> {
        if text.trim().is_empty()
            || text.len() > 4096
            || text.contains('\0')
            || owner.as_ref().is_some_and(|s| {
                s.trim().is_empty() || s.len() > 512 || s.contains(['\n', '\r', '\0'])
            })
        {
            return Err(invalid("Invalid action or owner"));
        }
        if let Some(date) = &due_date {
            let parsed = chrono::NaiveDate::parse_from_str(date, "%Y-%m-%d").map_err(invalid)?;
            if parsed.format("%Y-%m-%d").to_string() != *date {
                return Err(invalid("Use YYYY-MM-DD for the due date"));
            }
        }
        let json: Option<String> = self
            .conn
            .query_row(
                "SELECT utterances FROM transcript_origins WHERE transcription_id=?1",
                [record_id],
                |r| r.get(0),
            )
            .optional()
            .map_err(invalid)?;
        let texts = if let Some(json) = json {
            serde_json::from_str::<Vec<TranscriptUtterance>>(&json)
                .map_err(invalid)?
                .into_iter()
                .map(|u| u.text)
                .collect::<Vec<_>>()
        } else {
            self.get_segments(record_id)?
                .into_iter()
                .map(|s| s.text)
                .collect()
        };
        let position = usize::try_from(source_utterance).map_err(invalid)?;
        let quote = texts
            .get(position)
            .ok_or_else(|| invalid("Select an existing source utterance"))?
            .clone();
        let action = MeetingAction {
            id: uuid::Uuid::new_v4().to_string(),
            text: text.trim().into(),
            owner,
            due_date,
            completed: false,
            source_utterance,
            source_quote: quote,
        };
        self.conn
            .execute(
                "INSERT INTO meeting_actions VALUES(?1,?2,?3)",
                params![
                    action.id,
                    record_id,
                    serde_json::to_string(&action).map_err(invalid)?
                ],
            )
            .map_err(invalid)?;
        Ok(action)
    }

    pub fn meeting_actions(&self, record_id: &str) -> Result<Vec<MeetingAction>, CoreError> {
        self.get(record_id)?;
        let mut statement = self
            .conn
            .prepare("SELECT payload FROM meeting_actions WHERE transcription_id=?1 ORDER BY rowid")
            .map_err(invalid)?;
        let actions = statement
            .query_map([record_id], |r| r.get::<_, String>(0))
            .map_err(invalid)?
            .map(|row| serde_json::from_str(&row.map_err(invalid)?).map_err(invalid))
            .collect();
        actions
    }

    pub fn complete_meeting_action(
        &self,
        record_id: &str,
        action_id: &str,
        completed: bool,
    ) -> Result<(), CoreError> {
        let json: String = self
            .conn
            .query_row(
                "SELECT payload FROM meeting_actions WHERE transcription_id=?1 AND id=?2",
                params![record_id, action_id],
                |r| r.get(0),
            )
            .map_err(invalid)?;
        let mut action: MeetingAction = serde_json::from_str(&json).map_err(invalid)?;
        action.completed = completed;
        self.conn
            .execute(
                "UPDATE meeting_actions SET payload=?3 WHERE transcription_id=?1 AND id=?2",
                params![
                    record_id,
                    action_id,
                    serde_json::to_string(&action).map_err(invalid)?
                ],
            )
            .map_err(invalid)?;
        Ok(())
    }
}
