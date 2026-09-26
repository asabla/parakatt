//! Capture checkpoints are independent of model loading and speech chunk boundaries.
use crate::{recovery::source_number, storage::Storage, ChunkSource, CoreError};
use rusqlite::{params, OptionalExtension};
fn io(e: rusqlite::Error) -> CoreError {
    CoreError::IoError(e.to_string())
}
impl Storage {
    pub(crate) fn migrate_capture(&self) -> Result<(), CoreError> {
        self.conn
            .execute_batch(
                "CREATE TABLE IF NOT EXISTS capture_status (
            session_id TEXT PRIMARY KEY REFERENCES recording_drafts(id) ON DELETE CASCADE,
            capture_gap INTEGER NOT NULL DEFAULT 0, speech_gap INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS capture_blocks (
            session_id TEXT NOT NULL REFERENCES recording_drafts(id) ON DELETE CASCADE,
            source INTEGER NOT NULL, sample_start INTEGER NOT NULL, sample_count INTEGER NOT NULL,
            audio BLOB, created INTEGER NOT NULL DEFAULT(unixepoch()),
            PRIMARY KEY(session_id,source,sample_start));",
            )
            .map_err(io)
    }
    pub fn begin_capture(&self, id: &str, source: &str, mode: &str) -> Result<(), CoreError> {
        self.begin_draft(id, source, mode)?;
        self.conn
            .execute(
                "INSERT OR IGNORE INTO capture_status(session_id) VALUES(?1)",
                [id],
            )
            .map_err(io)?;
        Ok(())
    }
    pub fn capture_gap(&self, id: &str, audio_lost: bool) -> Result<(), CoreError> {
        self.conn.execute("UPDATE capture_status SET speech_gap=1,capture_gap=MAX(capture_gap,?2) WHERE session_id=?1",params![id,audio_lost]).map_err(io)?;
        Ok(())
    }
    pub fn has_speech_gap(&self, id: &str) -> Result<bool, CoreError> {
        Ok(self
            .conn
            .query_row(
                "SELECT speech_gap FROM capture_status WHERE session_id=?1",
                [id],
                |r| r.get(0),
            )
            .optional()
            .map_err(io)?
            .unwrap_or(false))
    }
    pub fn append_capture(
        &self,
        id: &str,
        source: ChunkSource,
        samples: &[f32],
    ) -> Result<(), CoreError> {
        if samples.is_empty() {
            return Ok(());
        }
        if samples.len() > 32000 || samples.iter().any(|s| !s.is_finite()) {
            return Err(CoreError::AudioError("Invalid capture checkpoint".into()));
        }
        self.expire_recovery_audio()?;
        let total: i64 = self.conn.query_row("SELECT COALESCE((SELECT SUM(length(audio)) FROM recording_chunks),0)+COALESCE((SELECT SUM(length(audio)) FROM capture_blocks),0)",[],|r|r.get(0)).map_err(io)?;
        if total + (samples.len() * 4) as i64 > 512 * 1024 * 1024 {
            self.capture_gap(id, true)?;
            return Err(CoreError::AudioError(
                "Audio recovery storage is full. Recording stopped to protect existing audio."
                    .into(),
            ));
        }
        let bytes: Vec<u8> = samples.iter().flat_map(|s| s.to_le_bytes()).collect();
        self.conn.execute("INSERT INTO capture_blocks(session_id,source,sample_start,sample_count,audio) SELECT ?1,?2,COALESCE(MAX(sample_start+sample_count),0),?3,?4 FROM capture_blocks WHERE session_id=?1 AND source=?2",params![id,source_number(source),samples.len() as i64,bytes]).map_err(io)?;
        Ok(())
    }
    pub fn capture_sources(&self, id: &str) -> Result<Vec<(u8, i64)>, CoreError> {
        self.conn.prepare("SELECT source,MAX(sample_start+sample_count) FROM capture_blocks WHERE session_id=?1 GROUP BY source ORDER BY source").map_err(io)?.query_map([id],|r|Ok((r.get(0)?,r.get(1)?))).map_err(io)?.collect::<Result<Vec<_>,_>>().map_err(io)
    }
    pub fn capture_available(&self, id: &str) -> Result<bool, CoreError> {
        self.conn.query_row("SELECT EXISTS(SELECT 1 FROM capture_blocks WHERE session_id=?1) AND NOT EXISTS(SELECT 1 FROM capture_blocks WHERE session_id=?1 AND audio IS NULL) AND EXISTS(SELECT 1 FROM capture_status WHERE session_id=?1 AND capture_gap=0)",[id],|r|r.get(0)).map_err(io)
    }
    pub fn capture_slice(
        &self,
        id: &str,
        source: u8,
        start: i64,
        count: usize,
    ) -> Result<Vec<f32>, CoreError> {
        let mut out = Vec::new();
        let mut stmt=self.conn.prepare("SELECT sample_start,audio FROM capture_blocks WHERE session_id=?1 AND source=?2 AND sample_start < ?3 AND sample_start+sample_count > ?4 ORDER BY sample_start").map_err(io)?;
        let rows = stmt
            .query_map(params![id, source, start + count as i64, start], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, Option<Vec<u8>>>(1)?))
            })
            .map_err(io)?;
        for row in rows {
            let (offset, bytes) = row.map_err(io)?;
            let bytes =
                bytes.ok_or_else(|| CoreError::AudioError("Recovery audio has expired".into()))?;
            let skip = start.saturating_sub(offset).max(0) as usize;
            out.extend(
                bytes
                    .chunks_exact(4)
                    .skip(skip)
                    .take(count - out.len())
                    .map(|b| f32::from_le_bytes(b.try_into().unwrap())),
            );
        }
        Ok(out)
    }
    pub fn reset_for_capture_replay(&self, id: &str) -> Result<(), CoreError> {
        self.conn
            .execute("DELETE FROM recording_chunks WHERE session_id=?1", [id])
            .map_err(io)?;
        self.conn
            .execute(
                "UPDATE capture_status SET speech_gap=0 WHERE session_id=?1",
                [id],
            )
            .map_err(io)?;
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn replay_keeps_recognized_text_and_expiry_disables_audio() {
        let dir = tempfile::tempdir().unwrap();
        let db = Storage::open(dir.path()).unwrap();
        db.begin_capture("s", "push_to_talk", "dictation").unwrap();
        db.append_capture("s", ChunkSource::Mixed, &[0.1; 1600])
            .unwrap();
        db.journal_chunk("s", 0, ChunkSource::Mixed, &[0.1; 1600], 16000, 0., false)
            .unwrap();
        db.recognize_draft_chunk("s", 0, ChunkSource::Mixed, "Keep this text")
            .unwrap();
        db.preserve_recovered_text(&db.recording_drafts().unwrap()[0])
            .unwrap();
        db.reset_for_capture_replay("s").unwrap();
        assert_eq!(db.get("s").unwrap().text, "Keep this text");
        assert!(db.capture_available("s").unwrap());
        db.conn
            .execute("UPDATE capture_blocks SET created=unixepoch()-86401", [])
            .unwrap();
        db.expire_recovery_audio().unwrap();
        assert!(!db.capture_available("s").unwrap());
        assert_eq!(db.get("s").unwrap().text, "Keep this text");
    }
    #[test]
    fn capture_survives_restart_before_model_submission() {
        let dir = tempfile::tempdir().unwrap();
        {
            let db = Storage::open(dir.path()).unwrap();
            db.begin_capture("early", "push_to_talk", "dictation")
                .unwrap();
            db.append_capture("early", ChunkSource::Mixed, &[0.1; 1600])
                .unwrap();
            db.append_capture("early", ChunkSource::Mixed, &[0.2; 1600])
                .unwrap();
        }
        let db = Storage::open(dir.path()).unwrap();
        assert!(db.capture_available("early").unwrap());
        assert_eq!(
            db.capture_slice("early", 0, 1500, 200).unwrap(),
            [vec![0.1; 100], vec![0.2; 100]].concat()
        );
        assert!(db.recording_drafts().unwrap()[0].audio_available);
        db.capture_gap("early", false).unwrap();
        assert!(db.capture_available("early").unwrap());
        assert!(db.has_speech_gap("early").unwrap());
        db.capture_gap("early", true).unwrap();
        assert!(!db.capture_available("early").unwrap());
        db.clear_recovery_audio().unwrap();
        assert!(!db.capture_available("early").unwrap());
    }
}
