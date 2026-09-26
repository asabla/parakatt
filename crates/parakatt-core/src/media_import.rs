//! Durable media jobs. Audio is re-read from the source; checkpoints never store PCM.
use crate::{
    processing::ProcessingSummary,
    recovery::HistorySection,
    storage::{Storage, StoredTranscription},
    CoreError, TimestampedSegment,
};
use rusqlite::params;
use serde::{Deserialize, Serialize};

pub(crate) fn io(e: impl std::fmt::Display) -> CoreError {
    CoreError::IoError(e.to_string())
}
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct MediaAttachment {
    pub path: String,
    pub bookmark: Vec<u8>,
    pub fingerprint: String,
    pub review_path: String,
    pub audio_track: i32,
    pub duration_secs: f64,
}
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct ImportJob {
    pub id: String,
    pub kind: String,
    pub input: String,
    pub title: String,
    pub mode: String,
    pub state: String,
    pub message: String,
    pub attachment: MediaAttachment,
    pub next_chunk: u32,
    pub processed_until: f64,
    pub configuration: String,
    pub checkpoint_version: u32,
}
/// Group retained model-timed words only after overlap gating. No timing is invented.
pub(crate) fn group_import_words(words: Vec<TimestampedSegment>) -> Vec<TimestampedSegment> {
    let mut grouped: Vec<TimestampedSegment> = Vec::new();
    for word in words {
        let append = grouped.last().is_some_and(|previous| {
            !previous.text.ends_with(['.', '?', '!'])
                && word.start_secs - previous.end_secs < 1.0
                && previous.text.chars().count() + word.text.chars().count() < 160
        });
        if append {
            let previous = grouped.last_mut().unwrap();
            previous.text.push(' ');
            previous.text.push_str(&word.text);
            previous.end_secs = word.end_secs;
        } else {
            grouped.push(word);
        }
    }
    grouped
}

impl Storage {
    pub(crate) fn migrate_imports(&self) -> Result<(), CoreError> {
        self.conn
            .execute_batch(
                "CREATE TABLE IF NOT EXISTS import_jobs (
            id TEXT PRIMARY KEY REFERENCES transcriptions(id) ON DELETE CASCADE,
            job TEXT NOT NULL, checkpoint TEXT NOT NULL DEFAULT '');
            CREATE TABLE IF NOT EXISTS import_chunks (
            id TEXT NOT NULL REFERENCES import_jobs(id) ON DELETE CASCADE,
            chunk_index INTEGER NOT NULL, recognized TEXT NOT NULL, text TEXT NOT NULL,
            status TEXT NOT NULL, PRIMARY KEY(id,chunk_index));",
            )
            .map_err(io)
    }
    pub(crate) fn import_job(&self, id: &str) -> Result<ImportJob, CoreError> {
        let json: String = self
            .conn
            .query_row("SELECT job FROM import_jobs WHERE id=?1", [id], |r| {
                r.get(0)
            })
            .map_err(io)?;
        serde_json::from_str(&json).map_err(io)
    }
    pub(crate) fn import_jobs(&self) -> Result<Vec<ImportJob>, CoreError> {
        let mut stmt = self
            .conn
            .prepare("SELECT job FROM import_jobs ORDER BY rowid")
            .map_err(io)?;
        let values = stmt
            .query_map([], |r| r.get::<_, String>(0))
            .map_err(io)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(io)?;
        values
            .iter()
            .map(|s| serde_json::from_str(s).map_err(io))
            .collect()
    }
    pub(crate) fn write_import(&self, job: &ImportJob) -> Result<(), CoreError> {
        self.conn
            .execute(
                "UPDATE import_jobs SET job=?2 WHERE id=?1",
                params![job.id, serde_json::to_string(job).map_err(io)?],
            )
            .map_err(io)?;
        Ok(())
    }
    pub(crate) fn create_import(&self, job: &ImportJob) -> Result<(), CoreError> {
        let tx = self.conn.unchecked_transaction().map_err(io)?;
        self.save(&StoredTranscription {
            id: job.id.clone(),
            created_at: chrono::Utc::now().to_rfc3339(),
            duration_secs: 0.0,
            source: "import".into(),
            mode: job.mode.clone(),
            audio_source: Some("media".into()),
            app_context: None,
            title: Some(job.title.clone()),
            text: String::new(),
        })?;
        self.conn
            .execute(
                "INSERT INTO import_jobs(id,job) VALUES(?1,?2)",
                params![job.id, serde_json::to_string(job).map_err(io)?],
            )
            .map_err(io)?;
        self.save_processing(
            &job.id,
            &ProcessingSummary {
                recognized_text: String::new(),
                status: "interrupted".into(),
            },
        )?;
        tx.commit().map_err(io)
    }
    pub(crate) fn import_checkpoint(&self, id: &str) -> Result<String, CoreError> {
        self.conn
            .query_row(
                "SELECT checkpoint FROM import_jobs WHERE id=?1",
                [id],
                |r| r.get(0),
            )
            .map_err(io)
    }
    pub(crate) fn commit_import_chunk(
        &self,
        job: &ImportJob,
        expected_chunk: u32,
        checkpoint: &str,
        recognized: &str,
        text: &str,
        segments: &[TimestampedSegment],
    ) -> Result<(), CoreError> {
        let tx = self.conn.unchecked_transaction().map_err(io)?;
        let current = self.import_job(&job.id)?;
        if current.next_chunk != expected_chunk || current.state != "transcribing" {
            return Err(io("Import changed before the chunk was committed"));
        }
        self.conn
            .execute(
                "INSERT INTO import_chunks VALUES(?1,?2,?3,?4,?5)",
                params![
                    job.id,
                    expected_chunk,
                    recognized,
                    text,
                    if job.mode == "dictation" || text.trim().is_empty() {
                        "processed"
                    } else {
                        "pending"
                    }
                ],
            )
            .map_err(io)?;
        self.save_segments(&job.id, segments, Some(expected_chunk))?;
        self.conn
            .execute(
                "UPDATE import_jobs SET job=?2,checkpoint=?3 WHERE id=?1",
                params![job.id, serde_json::to_string(job).map_err(io)?, checkpoint],
            )
            .map_err(io)?;
        self.refresh_import_text(job)?;
        tx.commit().map_err(io)
    }
    pub(crate) fn refresh_import_text(&self, job: &ImportJob) -> Result<(), CoreError> {
        let rows = self.import_sections(&job.id)?;
        let text = rows
            .iter()
            .map(|s| s.text.as_str())
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join("\n\n");
        let recognized_text = rows
            .iter()
            .map(|s| s.recognized_text.as_str())
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join("\n\n");
        self.conn
            .execute(
                "UPDATE transcriptions SET text=?2,duration_secs=?3 WHERE id=?1",
                params![job.id, text, job.attachment.duration_secs],
            )
            .map_err(io)?;
        let status = if job.state != "completed" {
            "interrupted"
        } else if rows.iter().any(|r| r.status != "processed") {
            "degraded"
        } else {
            "completed"
        };
        self.save_processing(
            &job.id,
            &ProcessingSummary {
                recognized_text,
                status: status.into(),
            },
        )?;
        self.save_sections(&job.id, &rows)
    }
    pub(crate) fn import_sections(&self, id: &str) -> Result<Vec<HistorySection>, CoreError> {
        self.conn.prepare("SELECT chunk_index,recognized,text,status FROM import_chunks WHERE id=?1 ORDER BY chunk_index").map_err(io)?.query_map([id],|r| {
            let status:String=r.get(3)?;
            Ok(HistorySection {chunk_id:r.get(0)?,source:crate::ChunkSource::Mixed,recognized_text:r.get(1)?,text:r.get(2)?,error: if status=="failed" {Some("Text processing failed. Recognized text was kept.".into())} else {None},status})
        }).map_err(io)?.collect::<Result<Vec<_>,_>>().map_err(io)
    }
}
