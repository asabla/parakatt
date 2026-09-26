//! Local recovery records. Text remains until completion or explicit dismissal.
//! Audio is opt-in, expires after 24 hours, and is removed on successful completion.
use crate::{storage::Storage, ChunkSource, CoreError};
use rusqlite::params;

#[derive(Debug, Clone, uniffi::Record)]
pub struct RecordingDraft {
    pub id: String,
    pub created_at: String,
    pub source: String,
    pub mode: String,
    pub recognized_text: String,
    pub chunk_count: u32,
    pub failed_chunks: u32,
    pub audio_available: bool,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct HistorySection {
    pub chunk_id: u32,
    pub source: ChunkSource,
    pub recognized_text: String,
    pub text: String,
    pub status: String,
    pub error: Option<String>,
}

pub struct RecoveryChunk {
    pub index: u32,
    pub source: ChunkSource,
    pub samples: Option<Vec<f32>>,
    pub sample_rate: u32,
    pub overlap: f64,
    pub duration: f64,
    pub text: String,
}

fn io(e: rusqlite::Error) -> CoreError {
    CoreError::IoError(e.to_string())
}
pub fn source_number(source: ChunkSource) -> u8 {
    match source {
        ChunkSource::Mixed => 0,
        ChunkSource::Mic => 1,
        ChunkSource::System => 2,
    }
}
fn source_value(value: u8) -> ChunkSource {
    match value {
        1 => ChunkSource::Mic,
        2 => ChunkSource::System,
        _ => ChunkSource::Mixed,
    }
}

impl Storage {
    pub(crate) fn migrate_recovery(&self) -> Result<(), CoreError> {
        self.conn.execute_batch("
            CREATE TABLE IF NOT EXISTS recording_drafts (
                id TEXT PRIMARY KEY, created_at TEXT NOT NULL, source TEXT NOT NULL, mode TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS recording_chunks (
                session_id TEXT NOT NULL REFERENCES recording_drafts(id) ON DELETE CASCADE,
                chunk_id INTEGER NOT NULL, source INTEGER NOT NULL,
                sample_rate INTEGER NOT NULL, overlap REAL NOT NULL, duration REAL NOT NULL,
                audio BLOB, audio_created INTEGER NOT NULL,
                recognized_text TEXT NOT NULL DEFAULT '', segments TEXT NOT NULL DEFAULT '[]', failed INTEGER NOT NULL DEFAULT 1,
                PRIMARY KEY(session_id,chunk_id,source)
            );
            CREATE TABLE IF NOT EXISTS transcription_sections (
                transcription_id TEXT PRIMARY KEY REFERENCES transcriptions(id) ON DELETE CASCADE,
                sections TEXT NOT NULL
            );
            CREATE TRIGGER IF NOT EXISTS discard_transcription_recovery AFTER DELETE ON transcriptions BEGIN
                DELETE FROM recording_drafts WHERE id=old.id;
            END;
            CREATE TABLE IF NOT EXISTS transcription_edits (
                transcription_id TEXT PRIMARY KEY REFERENCES transcriptions(id) ON DELETE CASCADE,
                previous_text TEXT NOT NULL
            );
        ").map_err(io)?;
        let has_segments = self
            .conn
            .prepare("PRAGMA table_info(recording_chunks)")
            .map_err(io)?
            .query_map([], |r| r.get::<_, String>(1))
            .map_err(io)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(io)?
            .iter()
            .any(|s| s == "segments");
        if !has_segments {
            self.conn
                .execute_batch(
                    "ALTER TABLE recording_chunks ADD COLUMN segments TEXT NOT NULL DEFAULT '[]'",
                )
                .map_err(io)?;
        }
        self.expire_recovery_audio()
    }
    pub fn expire_recovery_audio(&self) -> Result<(), CoreError> {
        self.conn
            .execute(
                "UPDATE recording_chunks SET audio=NULL WHERE audio_created < unixepoch()-86400",
                [],
            )
            .map_err(io)?;
        Ok(())
    }
    pub fn clear_recovery_audio(&self) -> Result<(), CoreError> {
        self.conn
            .execute("UPDATE recording_chunks SET audio=NULL", [])
            .map_err(io)?;
        Ok(())
    }
    pub fn update_draft(&self, id: &str, source: &str, mode: &str) -> Result<(), CoreError> {
        self.conn
            .execute(
                "UPDATE recording_drafts SET source=?2,mode=?3 WHERE id=?1",
                params![id, source, mode],
            )
            .map_err(io)?;
        Ok(())
    }
    pub fn apply_history_processing(
        &self,
        id: &str,
        text: &str,
        summary: &crate::processing::ProcessingSummary,
        sections: &[HistorySection],
    ) -> Result<(), CoreError> {
        let tx = self.conn.unchecked_transaction().map_err(io)?;
        self.edit_transcription_inner(id, text)?;
        self.save_processing(id, summary)?;
        self.save_sections(id, sections)?;
        tx.commit().map_err(io)
    }
    pub fn save_recovered_text(&self, draft: &RecordingDraft) -> Result<(), CoreError> {
        if draft.recognized_text.is_empty() {
            return Err(CoreError::TranscriptionFailed(
                "No recognized text is available. Retained audio is required for recovery.".into(),
            ));
        }
        let item = crate::storage::StoredTranscription {
            id: draft.id.clone(),
            created_at: draft.created_at.clone(),
            duration_secs: 0.0,
            source: draft.source.clone(),
            mode: draft.mode.clone(),
            audio_source: None,
            app_context: None,
            title: Some("Recovered recording".into()),
            text: draft.recognized_text.clone(),
        };
        let tx = self.conn.unchecked_transaction().map_err(io)?;
        self.save(&item)?;
        let json_rows=self.conn.prepare("SELECT segments FROM recording_chunks WHERE session_id=?1 ORDER BY chunk_id,source").map_err(io)?.query_map([&draft.id],|r|r.get::<_,String>(0)).map_err(io)?.collect::<Result<Vec<_>,_>>().map_err(io)?;
        let mut segments = Vec::<crate::TimestampedSegment>::new();
        for json in json_rows {
            segments.extend(
                serde_json::from_str::<Vec<crate::TimestampedSegment>>(&json)
                    .map_err(|e| CoreError::IoError(e.to_string()))?,
            );
        }
        segments.sort_by(|a, b| a.start_secs.total_cmp(&b.start_secs));
        self.conn
            .execute(
                "DELETE FROM transcript_segments WHERE transcription_id=?1",
                [&draft.id],
            )
            .map_err(io)?;
        self.save_segments(&draft.id, &segments, None)?;
        self.conn.execute("UPDATE transcriptions SET duration_secs=(SELECT COALESCE(SUM(duration),0) FROM (SELECT MAX(MAX(duration-overlap,0)) AS duration FROM recording_chunks WHERE session_id=?1 GROUP BY chunk_id)) WHERE id=?1",[&draft.id]).map_err(io)?;
        self.save_processing(
            &draft.id,
            &crate::processing::ProcessingSummary {
                recognized_text: draft.recognized_text.clone(),
                status: "interrupted".into(),
            },
        )?;
        self.discard_draft(&draft.id)?;
        tx.commit().map_err(io)
    }
    pub fn begin_draft(&self, id: &str, source: &str, mode: &str) -> Result<(), CoreError> {
        self.conn
            .execute(
                "INSERT OR IGNORE INTO recording_drafts VALUES(?1,?2,?3,?4)",
                params![id, chrono::Utc::now().to_rfc3339(), source, mode],
            )
            .map_err(io)?;
        Ok(())
    }
    #[allow(clippy::too_many_arguments)]
    pub fn journal_chunk(
        &self,
        id: &str,
        index: u32,
        source: ChunkSource,
        samples: &[f32],
        rate: u32,
        overlap: f64,
        retain_audio: bool,
    ) -> Result<(), CoreError> {
        if rate == 0
            || !overlap.is_finite()
            || overlap < 0.0
            || samples.iter().any(|s| !s.is_finite())
        {
            return Err(CoreError::AudioError("Invalid recovery audio".into()));
        }
        self.expire_recovery_audio()?;
        let audio = retain_audio.then(|| {
            samples
                .iter()
                .flat_map(|v| v.to_le_bytes())
                .collect::<Vec<u8>>()
        });
        self.conn.execute("INSERT INTO recording_chunks(session_id,chunk_id,source,sample_rate,overlap,duration,audio,audio_created) VALUES(?1,?2,?3,?4,?5,?6,?7,unixepoch()) ON CONFLICT(session_id,chunk_id,source) DO UPDATE SET audio=excluded.audio,audio_created=excluded.audio_created,failed=1", params![id,index,source_number(source),rate,overlap,samples.len() as f64 / rate as f64,audio]).map_err(io)?;
        let total: i64 = self
            .conn
            .query_row(
                "SELECT COALESCE(SUM(length(audio)),0) FROM recording_chunks",
                [],
                |r| r.get(0),
            )
            .map_err(io)?;
        if total > 512 * 1024 * 1024 {
            self.conn.execute("UPDATE recording_chunks SET audio=NULL WHERE rowid IN (SELECT rowid FROM (SELECT rowid,SUM(length(audio)) OVER (ORDER BY audio_created DESC,rowid DESC) AS retained FROM recording_chunks WHERE audio IS NOT NULL) WHERE retained > 536870912)",[]).map_err(io)?;
        }
        Ok(())
    }
    pub fn recognize_draft_chunk(
        &self,
        id: &str,
        index: u32,
        source: ChunkSource,
        text: &str,
    ) -> Result<(), CoreError> {
        self.conn.execute("UPDATE recording_chunks SET recognized_text=?4,failed=0 WHERE session_id=?1 AND chunk_id=?2 AND source=?3", params![id,index,source_number(source),text]).map_err(io)?;
        Ok(())
    }
    pub fn save_draft_segments(
        &self,
        id: &str,
        index: u32,
        source: ChunkSource,
        segments: &[crate::TimestampedSegment],
    ) -> Result<(), CoreError> {
        let json =
            serde_json::to_string(segments).map_err(|e| CoreError::IoError(e.to_string()))?;
        self.conn.execute("UPDATE recording_chunks SET segments=?4 WHERE session_id=?1 AND chunk_id=?2 AND source=?3",params![id,index,source_number(source),json]).map_err(io)?;
        Ok(())
    }
    pub fn draft_failure_count(&self, id: &str) -> Result<u32, CoreError> {
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM recording_chunks WHERE session_id=?1 AND failed=1",
                [id],
                |r| r.get(0),
            )
            .map_err(io)
    }
    pub fn draft_keys(&self, id: &str) -> Result<Vec<(u32, u8)>, CoreError> {
        self.conn.prepare("SELECT chunk_id,source FROM recording_chunks WHERE session_id=?1 ORDER BY chunk_id,source").map_err(io)?.query_map([id], |r|Ok((r.get(0)?,r.get(1)?))).map_err(io)?.collect::<Result<Vec<_>,_>>().map_err(io)
    }
    pub fn recovery_chunk(
        &self,
        id: &str,
        index: u32,
        source: u8,
    ) -> Result<RecoveryChunk, CoreError> {
        self.conn.query_row("SELECT sample_rate,overlap,duration,recognized_text,audio FROM recording_chunks WHERE session_id=?1 AND chunk_id=?2 AND source=?3",params![id,index,source],|r| {
            let audio: Option<Vec<u8>> = r.get(4)?;
            Ok(RecoveryChunk { index, source: source_value(source), sample_rate:r.get(0)?, overlap:r.get(1)?, duration:r.get(2)?, text:r.get(3)?, samples:audio.map(|bytes|bytes.chunks_exact(4).map(|v|f32::from_le_bytes(v.try_into().unwrap())).collect()) })
        }).map_err(io)
    }
    pub fn recording_drafts(&self) -> Result<Vec<RecordingDraft>, CoreError> {
        self.expire_recovery_audio()?;
        let mut statement = self.conn.prepare("SELECT d.id,d.created_at,d.source,d.mode,COUNT(c.chunk_id),COALESCE(SUM(c.failed),0),COUNT(c.audio)=COUNT(c.chunk_id) AND COUNT(c.chunk_id)>0 FROM recording_drafts d LEFT JOIN recording_chunks c ON d.id=c.session_id GROUP BY d.id ORDER BY d.created_at DESC").map_err(io)?;
        let mut rows = statement
            .query_map([], |r| {
                Ok(RecordingDraft {
                    id: r.get(0)?,
                    created_at: r.get(1)?,
                    source: r.get(2)?,
                    mode: r.get(3)?,
                    recognized_text: String::new(),
                    chunk_count: r.get(4)?,
                    failed_chunks: r.get(5)?,
                    audio_available: r.get(6)?,
                })
            })
            .map_err(io)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(io)?;
        for row in &mut rows {
            // Read only text here; opening history must not load all retained audio.
            let chunks = self.conn.prepare("SELECT recognized_text,source FROM recording_chunks WHERE session_id=?1 ORDER BY chunk_id,source").map_err(io)?.query_map([&row.id], |r|Ok((r.get::<_,String>(0)?,source_value(r.get(1)?)))).map_err(io)?.collect::<Result<Vec<_>,_>>().map_err(io)?;
            row.recognized_text = crate::text_assembly::assemble_transcript_parts(
                chunks.iter().map(|c| c.0.clone()).collect(),
                chunks.iter().map(|c| c.1).collect(),
            );
        }
        Ok(rows)
    }
    pub fn discard_draft(&self, id: &str) -> Result<(), CoreError> {
        self.conn
            .execute("DELETE FROM recording_drafts WHERE id=?1", [id])
            .map_err(io)?;
        Ok(())
    }
    pub fn save_sections(&self, id: &str, sections: &[HistorySection]) -> Result<(), CoreError> {
        let json =
            serde_json::to_string(sections).map_err(|e| CoreError::IoError(e.to_string()))?;
        self.conn.execute("INSERT INTO transcription_sections VALUES(?1,?2) ON CONFLICT(transcription_id) DO UPDATE SET sections=excluded.sections",params![id,json]).map_err(io)?;
        Ok(())
    }
    pub fn history_sections(&self, id: &str) -> Result<Vec<HistorySection>, CoreError> {
        use rusqlite::OptionalExtension;
        let json: Option<String> = self
            .conn
            .query_row(
                "SELECT sections FROM transcription_sections WHERE transcription_id=?1",
                [id],
                |r| r.get(0),
            )
            .optional()
            .map_err(io)?;
        json.map(|j| serde_json::from_str(&j).map_err(|e| CoreError::IoError(e.to_string())))
            .transpose()
            .map(|v| v.unwrap_or_default())
    }
    pub fn edit_transcription(&self, id: &str, text: &str) -> Result<(), CoreError> {
        let tx = self.conn.unchecked_transaction().map_err(io)?;
        self.edit_transcription_inner(id, text)?;
        tx.commit().map_err(io)
    }
    fn edit_transcription_inner(&self, id: &str, text: &str) -> Result<(), CoreError> {
        self.conn.execute("INSERT OR REPLACE INTO transcription_edits SELECT id,text FROM transcriptions WHERE id=?1",[id]).map_err(io)?;
        let changed = self
            .conn
            .execute(
                "UPDATE transcriptions SET text=?2 WHERE id=?1",
                params![id, text],
            )
            .map_err(io)?;
        if changed != 1 {
            return Err(CoreError::IoError("Transcription no longer exists".into()));
        }
        Ok(())
    }
    pub fn undo_transcription_edit(&self, id: &str) -> Result<(), CoreError> {
        let tx = self.conn.unchecked_transaction().map_err(io)?;
        self.conn.execute("UPDATE transcriptions SET text=(SELECT previous_text FROM transcription_edits WHERE transcription_id=?1) WHERE id=?1 AND EXISTS(SELECT 1 FROM transcription_edits WHERE transcription_id=?1)",[id]).map_err(io)?;
        self.conn
            .execute(
                "DELETE FROM transcription_edits WHERE transcription_id=?1",
                [id],
            )
            .map_err(io)?;
        tx.commit().map_err(io)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn backup_excludes_audio_and_recovery_preserves_timestamps_and_delete_cleans_draft() {
        let dir = tempfile::tempdir().unwrap();
        let db = Storage::open(dir.path()).unwrap();
        db.begin_draft("s", "meeting", "clean").unwrap();
        db.journal_chunk("s", 0, ChunkSource::Mic, &[0.1; 16000], 16000, 0., true)
            .unwrap();
        db.recognize_draft_chunk("s", 0, ChunkSource::Mic, "Original words")
            .unwrap();
        db.save_draft_segments(
            "s",
            0,
            ChunkSource::Mic,
            &[crate::TimestampedSegment {
                text: "Original words".into(),
                start_secs: 0.25,
                end_secs: 0.75,
                speaker: Some("Me".into()),
            }],
        )
        .unwrap();
        let backup = dir.path().join("backup.db");
        db.export_to(&backup).unwrap();
        let exported = rusqlite::Connection::open(backup).unwrap();
        assert_eq!(
            exported
                .query_row("SELECT COUNT(audio) FROM recording_chunks", [], |r| r
                    .get::<_, u32>(0))
                .unwrap(),
            0
        );
        assert!(db.recovery_chunk("s", 0, 1).unwrap().samples.is_some());
        db.save_recovered_text(&db.recording_drafts().unwrap()[0])
            .unwrap();
        assert_eq!(db.get("s").unwrap().duration_secs, 1.0);
        let start: f64 = db
            .conn
            .query_row(
                "SELECT start_secs FROM transcript_segments WHERE transcription_id='s'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(start, 0.25);
        db.begin_draft("s", "meeting", "clean").unwrap();
        db.delete("s").unwrap();
        assert!(db.recording_drafts().unwrap().is_empty());
    }

    #[test]
    fn restart_recovers_text_and_optional_audio_and_expiry_keeps_text() {
        let dir = tempfile::tempdir().unwrap();
        {
            let db = Storage::open(dir.path()).unwrap();
            db.begin_draft("s", "push_to_talk", "clean").unwrap();
            db.journal_chunk("s", 0, ChunkSource::Mixed, &[0.1, 0.2], 16000, 0., false)
                .unwrap();
            db.recognize_draft_chunk("s", 0, ChunkSource::Mixed, "Första meningen.")
                .unwrap();
            assert!(!db.recording_drafts().unwrap()[0].audio_available);
            db.journal_chunk("s", 1, ChunkSource::Mixed, &[0.3, 0.4], 16000, 0., true)
                .unwrap();
        }
        let db = Storage::open(dir.path()).unwrap();
        let draft = &db.recording_drafts().unwrap()[0];
        assert_eq!(draft.recognized_text, "Första meningen.");
        assert_eq!(draft.failed_chunks, 1);
        assert_eq!(
            db.recovery_chunk("s", 1, 0).unwrap().samples.unwrap(),
            vec![0.3, 0.4]
        );
        db.conn
            .execute(
                "UPDATE recording_chunks SET audio_created=unixepoch()-86401",
                [],
            )
            .unwrap();
        db.expire_recovery_audio().unwrap();
        assert!(db.recovery_chunk("s", 1, 0).unwrap().samples.is_none());
        assert_eq!(
            db.recording_drafts().unwrap()[0].recognized_text,
            "Första meningen."
        );
        db.save_recovered_text(&db.recording_drafts().unwrap()[0])
            .unwrap();
        assert!(db.recording_drafts().unwrap().is_empty());
        assert_eq!(db.get("s").unwrap().text, "Första meningen.");
        assert_eq!(db.get_processing("s").unwrap().status, "interrupted");
        db.edit_transcription("s", "Corrected text").unwrap();
        assert_eq!(
            db.get_processing("s").unwrap().recognized_text,
            "Första meningen."
        );
        db.undo_transcription_edit("s").unwrap();
        assert_eq!(db.get("s").unwrap().text, "Första meningen.");
        assert_eq!(
            db.list(&crate::storage::TranscriptionQuery {
                search_text: Some("Första".into()),
                source_filter: None,
                limit: 10,
                offset: 0
            })
            .unwrap()
            .len(),
            1
        );
    }
}
