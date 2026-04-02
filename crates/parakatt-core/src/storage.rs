/// SQLite-backed storage for transcription history with FTS5 full-text search.

use std::path::Path;

use rusqlite::{Connection, params};

use crate::{CoreError, TimestampedSegment};

/// A persisted transcription record.
#[derive(Debug, Clone, uniffi::Record)]
pub struct StoredTranscription {
    pub id: String,
    pub created_at: String,
    pub duration_secs: f64,
    /// "push_to_talk" or "meeting"
    pub source: String,
    pub mode: String,
    pub audio_source: Option<String>,
    pub app_context: Option<String>,
    pub title: Option<String>,
    pub text: String,
}

/// Query parameters for listing/searching transcriptions.
#[derive(Debug, Clone, uniffi::Record)]
pub struct TranscriptionQuery {
    /// FTS5 search query (if empty, no text filter is applied).
    pub search_text: Option<String>,
    /// Filter by source ("push_to_talk", "meeting", or None for all).
    pub source_filter: Option<String>,
    pub limit: u32,
    pub offset: u32,
}

/// Manages the transcription SQLite database.
pub struct Storage {
    conn: Connection,
}

impl Storage {
    /// Open or create the database at the given directory.
    /// The database file will be `transcriptions.db` inside `data_dir`.
    pub fn open(data_dir: &Path) -> Result<Self, CoreError> {
        std::fs::create_dir_all(data_dir)
            .map_err(|e| CoreError::IoError(format!("Failed to create data dir: {e}")))?;

        let db_path = data_dir.join("transcriptions.db");
        let conn = Connection::open(&db_path)
            .map_err(|e| CoreError::IoError(format!("Failed to open database: {e}")))?;

        // Enable WAL mode for better concurrent read/write performance.
        conn.execute_batch("PRAGMA journal_mode=WAL;")
            .map_err(|e| CoreError::IoError(format!("Failed to set WAL mode: {e}")))?;

        // Enable foreign key constraints for CASCADE deletes.
        conn.execute_batch("PRAGMA foreign_keys=ON;")
            .map_err(|e| CoreError::IoError(format!("Failed to enable foreign keys: {e}")))?;

        let storage = Self { conn };
        storage.migrate()?;
        Ok(storage)
    }

    /// Run database migrations.
    fn migrate(&self) -> Result<(), CoreError> {
        self.conn
            .execute_batch(
                "
                CREATE TABLE IF NOT EXISTS transcriptions (
                    id TEXT PRIMARY KEY,
                    created_at TEXT NOT NULL,
                    duration_secs REAL NOT NULL,
                    source TEXT NOT NULL,
                    mode TEXT NOT NULL,
                    audio_source TEXT,
                    app_context TEXT,
                    title TEXT,
                    text TEXT NOT NULL
                );

                CREATE VIRTUAL TABLE IF NOT EXISTS transcriptions_fts USING fts5(
                    title, text, content=transcriptions, content_rowid=rowid
                );

                -- Triggers to keep FTS index in sync.
                CREATE TRIGGER IF NOT EXISTS transcriptions_ai AFTER INSERT ON transcriptions BEGIN
                    INSERT INTO transcriptions_fts(rowid, title, text)
                    VALUES (new.rowid, new.title, new.text);
                END;

                CREATE TRIGGER IF NOT EXISTS transcriptions_ad AFTER DELETE ON transcriptions BEGIN
                    INSERT INTO transcriptions_fts(transcriptions_fts, rowid, title, text)
                    VALUES ('delete', old.rowid, old.title, old.text);
                END;

                CREATE TRIGGER IF NOT EXISTS transcriptions_au AFTER UPDATE ON transcriptions BEGIN
                    INSERT INTO transcriptions_fts(transcriptions_fts, rowid, title, text)
                    VALUES ('delete', old.rowid, old.title, old.text);
                    INSERT INTO transcriptions_fts(rowid, title, text)
                    VALUES (new.rowid, new.title, new.text);
                END;

                -- Timestamp segments for timeline navigation.
                CREATE TABLE IF NOT EXISTS transcript_segments (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    transcription_id TEXT NOT NULL,
                    text TEXT NOT NULL,
                    start_secs REAL NOT NULL,
                    end_secs REAL NOT NULL,
                    chunk_index INTEGER,
                    FOREIGN KEY (transcription_id) REFERENCES transcriptions(id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS idx_segments_transcription
                    ON transcript_segments(transcription_id);
                ",
            )
            .map_err(|e| CoreError::IoError(format!("Database migration failed: {e}")))?;

        Ok(())
    }

    /// Save a new transcription. Returns the generated ID.
    pub fn save(&self, transcription: &StoredTranscription) -> Result<String, CoreError> {
        self.conn
            .execute(
                "INSERT INTO transcriptions (id, created_at, duration_secs, source, mode, audio_source, app_context, title, text)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    transcription.id,
                    transcription.created_at,
                    transcription.duration_secs,
                    transcription.source,
                    transcription.mode,
                    transcription.audio_source,
                    transcription.app_context,
                    transcription.title,
                    transcription.text,
                ],
            )
            .map_err(|e| CoreError::IoError(format!("Failed to save transcription: {e}")))?;

        Ok(transcription.id.clone())
    }

    /// List transcriptions with optional filtering.
    pub fn list(&self, query: &TranscriptionQuery) -> Result<Vec<StoredTranscription>, CoreError> {
        if let Some(search) = &query.search_text {
            if !search.trim().is_empty() {
                return self.search_fts(search, &query.source_filter, query.limit, query.offset);
            }
        }

        let mut sql = String::from(
            "SELECT id, created_at, duration_secs, source, mode, audio_source, app_context, title, text
             FROM transcriptions"
        );
        let mut conditions = Vec::new();

        if let Some(source) = &query.source_filter {
            conditions.push(format!("source = '{}'", source.replace('\'', "''")));
        }

        if !conditions.is_empty() {
            sql.push_str(" WHERE ");
            sql.push_str(&conditions.join(" AND "));
        }

        sql.push_str(" ORDER BY created_at DESC");
        sql.push_str(&format!(" LIMIT {} OFFSET {}", query.limit, query.offset));

        let mut stmt = self.conn.prepare(&sql)
            .map_err(|e| CoreError::IoError(format!("Query failed: {e}")))?;

        let rows = stmt
            .query_map([], |row| {
                Ok(StoredTranscription {
                    id: row.get(0)?,
                    created_at: row.get(1)?,
                    duration_secs: row.get(2)?,
                    source: row.get(3)?,
                    mode: row.get(4)?,
                    audio_source: row.get(5)?,
                    app_context: row.get(6)?,
                    title: row.get(7)?,
                    text: row.get(8)?,
                })
            })
            .map_err(|e| CoreError::IoError(format!("Query failed: {e}")))?;

        let mut results = Vec::new();
        for row in rows {
            results.push(
                row.map_err(|e| CoreError::IoError(format!("Row read failed: {e}")))?
            );
        }

        Ok(results)
    }

    /// Full-text search using FTS5.
    fn search_fts(
        &self,
        search_text: &str,
        source_filter: &Option<String>,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<StoredTranscription>, CoreError> {
        let mut sql = String::from(
            "SELECT t.id, t.created_at, t.duration_secs, t.source, t.mode,
                    t.audio_source, t.app_context, t.title, t.text
             FROM transcriptions t
             JOIN transcriptions_fts fts ON t.rowid = fts.rowid
             WHERE transcriptions_fts MATCH ?1"
        );

        if let Some(source) = source_filter {
            sql.push_str(&format!(" AND t.source = '{}'", source.replace('\'', "''")));
        }

        sql.push_str(" ORDER BY rank");
        sql.push_str(&format!(" LIMIT {} OFFSET {}", limit, offset));

        let mut stmt = self.conn.prepare(&sql)
            .map_err(|e| CoreError::IoError(format!("FTS query failed: {e}")))?;

        let rows = stmt
            .query_map(params![search_text], |row| {
                Ok(StoredTranscription {
                    id: row.get(0)?,
                    created_at: row.get(1)?,
                    duration_secs: row.get(2)?,
                    source: row.get(3)?,
                    mode: row.get(4)?,
                    audio_source: row.get(5)?,
                    app_context: row.get(6)?,
                    title: row.get(7)?,
                    text: row.get(8)?,
                })
            })
            .map_err(|e| CoreError::IoError(format!("FTS query failed: {e}")))?;

        let mut results = Vec::new();
        for row in rows {
            results.push(
                row.map_err(|e| CoreError::IoError(format!("Row read failed: {e}")))?
            );
        }

        Ok(results)
    }

    /// Get a single transcription by ID.
    pub fn get(&self, id: &str) -> Result<StoredTranscription, CoreError> {
        self.conn
            .query_row(
                "SELECT id, created_at, duration_secs, source, mode, audio_source, app_context, title, text
                 FROM transcriptions WHERE id = ?1",
                params![id],
                |row| {
                    Ok(StoredTranscription {
                        id: row.get(0)?,
                        created_at: row.get(1)?,
                        duration_secs: row.get(2)?,
                        source: row.get(3)?,
                        mode: row.get(4)?,
                        audio_source: row.get(5)?,
                        app_context: row.get(6)?,
                        title: row.get(7)?,
                        text: row.get(8)?,
                    })
                },
            )
            .map_err(|e| CoreError::IoError(format!("Transcription not found: {e}")))
    }

    /// Update the title of a transcription.
    pub fn update_title(&self, id: &str, title: &str) -> Result<(), CoreError> {
        let changed = self.conn
            .execute(
                "UPDATE transcriptions SET title = ?1 WHERE id = ?2",
                params![title, id],
            )
            .map_err(|e| CoreError::IoError(format!("Failed to update title: {e}")))?;

        if changed == 0 {
            return Err(CoreError::IoError(format!("Transcription not found: {id}")));
        }

        Ok(())
    }

    /// Save timestamp segments for a transcription (bulk insert).
    pub fn save_segments(
        &self,
        transcription_id: &str,
        segments: &[TimestampedSegment],
        chunk_index: Option<u32>,
    ) -> Result<(), CoreError> {
        if segments.is_empty() {
            return Ok(());
        }

        let mut stmt = self
            .conn
            .prepare(
                "INSERT INTO transcript_segments (transcription_id, text, start_secs, end_secs, chunk_index)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
            )
            .map_err(|e| CoreError::IoError(format!("Failed to prepare segment insert: {e}")))?;

        for seg in segments {
            stmt.execute(params![
                transcription_id,
                seg.text,
                seg.start_secs,
                seg.end_secs,
                chunk_index,
            ])
            .map_err(|e| CoreError::IoError(format!("Failed to save segment: {e}")))?;
        }

        Ok(())
    }

    /// Get timestamp segments for a transcription, ordered by start time.
    pub fn get_segments(&self, transcription_id: &str) -> Result<Vec<TimestampedSegment>, CoreError> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT text, start_secs, end_secs FROM transcript_segments
                 WHERE transcription_id = ?1 ORDER BY start_secs ASC",
            )
            .map_err(|e| CoreError::IoError(format!("Failed to query segments: {e}")))?;

        let rows = stmt
            .query_map(params![transcription_id], |row| {
                Ok(TimestampedSegment {
                    text: row.get(0)?,
                    start_secs: row.get(1)?,
                    end_secs: row.get(2)?,
                })
            })
            .map_err(|e| CoreError::IoError(format!("Failed to query segments: {e}")))?;

        let mut results = Vec::new();
        for row in rows {
            results.push(
                row.map_err(|e| CoreError::IoError(format!("Segment read failed: {e}")))?
            );
        }

        Ok(results)
    }

    /// Delete a transcription by ID.
    pub fn delete(&self, id: &str) -> Result<(), CoreError> {
        self.conn
            .execute("DELETE FROM transcriptions WHERE id = ?1", params![id])
            .map_err(|e| CoreError::IoError(format!("Failed to delete transcription: {e}")))?;

        Ok(())
    }

    /// Delete multiple transcriptions by IDs.
    pub fn delete_many(&self, ids: &[String]) -> Result<u32, CoreError> {
        let mut count = 0u32;
        for id in ids {
            self.conn
                .execute("DELETE FROM transcriptions WHERE id = ?1", params![id])
                .map_err(|e| CoreError::IoError(format!("Failed to delete transcription {id}: {e}")))?;
            count += 1;
        }
        Ok(count)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_storage() -> (Storage, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let storage = Storage::open(dir.path()).unwrap();
        (storage, dir)
    }

    fn sample_transcription(source: &str, text: &str) -> StoredTranscription {
        StoredTranscription {
            id: uuid::Uuid::new_v4().to_string(),
            created_at: "2026-03-30T14:30:00Z".to_string(),
            duration_secs: 60.0,
            source: source.to_string(),
            mode: "dictation".to_string(),
            audio_source: Some("mic".to_string()),
            app_context: None,
            title: Some("Test transcription".to_string()),
            text: text.to_string(),
        }
    }

    #[test]
    fn test_save_and_get() {
        let (storage, _dir) = temp_storage();
        let t = sample_transcription("push_to_talk", "hello world");
        let id = storage.save(&t).unwrap();
        let loaded = storage.get(&id).unwrap();
        assert_eq!(loaded.text, "hello world");
        assert_eq!(loaded.source, "push_to_talk");
    }

    #[test]
    fn test_list_all() {
        let (storage, _dir) = temp_storage();
        storage.save(&sample_transcription("push_to_talk", "first")).unwrap();
        storage.save(&sample_transcription("meeting", "second")).unwrap();

        let query = TranscriptionQuery {
            search_text: None,
            source_filter: None,
            limit: 50,
            offset: 0,
        };
        let results = storage.list(&query).unwrap();
        assert_eq!(results.len(), 2);
    }

    #[test]
    fn test_list_with_source_filter() {
        let (storage, _dir) = temp_storage();
        storage.save(&sample_transcription("push_to_talk", "ptt one")).unwrap();
        storage.save(&sample_transcription("meeting", "meeting one")).unwrap();

        let query = TranscriptionQuery {
            search_text: None,
            source_filter: Some("meeting".to_string()),
            limit: 50,
            offset: 0,
        };
        let results = storage.list(&query).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].source, "meeting");
    }

    #[test]
    fn test_fts_search() {
        let (storage, _dir) = temp_storage();
        storage.save(&sample_transcription("push_to_talk", "the quick brown fox jumps")).unwrap();
        storage.save(&sample_transcription("push_to_talk", "lazy dog sleeps all day")).unwrap();

        let query = TranscriptionQuery {
            search_text: Some("fox".to_string()),
            source_filter: None,
            limit: 50,
            offset: 0,
        };
        let results = storage.list(&query).unwrap();
        assert_eq!(results.len(), 1);
        assert!(results[0].text.contains("fox"));
    }

    #[test]
    fn test_update_title() {
        let (storage, _dir) = temp_storage();
        let t = sample_transcription("meeting", "some text");
        let id = storage.save(&t).unwrap();

        storage.update_title(&id, "Weekly standup").unwrap();
        let loaded = storage.get(&id).unwrap();
        assert_eq!(loaded.title, Some("Weekly standup".to_string()));
    }

    #[test]
    fn test_delete() {
        let (storage, _dir) = temp_storage();
        let t = sample_transcription("push_to_talk", "delete me");
        let id = storage.save(&t).unwrap();

        storage.delete(&id).unwrap();
        assert!(storage.get(&id).is_err());
    }

    #[test]
    fn test_save_and_get_segments() {
        let (storage, _dir) = temp_storage();
        let t = sample_transcription("push_to_talk", "hello world");
        let id = storage.save(&t).unwrap();

        let segments = vec![
            TimestampedSegment {
                text: "hello".to_string(),
                start_secs: 0.0,
                end_secs: 1.5,
            },
            TimestampedSegment {
                text: "world".to_string(),
                start_secs: 1.5,
                end_secs: 3.0,
            },
        ];

        storage.save_segments(&id, &segments, None).unwrap();

        let loaded = storage.get_segments(&id).unwrap();
        assert_eq!(loaded.len(), 2);
        assert_eq!(loaded[0].text, "hello");
        assert!((loaded[0].start_secs - 0.0).abs() < 0.01);
        assert!((loaded[0].end_secs - 1.5).abs() < 0.01);
        assert_eq!(loaded[1].text, "world");
    }

    #[test]
    fn test_segments_deleted_with_transcription() {
        let (storage, _dir) = temp_storage();
        let t = sample_transcription("meeting", "test text");
        let id = storage.save(&t).unwrap();

        let segments = vec![TimestampedSegment {
            text: "test text".to_string(),
            start_secs: 0.0,
            end_secs: 2.0,
        }];
        storage.save_segments(&id, &segments, Some(0)).unwrap();

        storage.delete(&id).unwrap();
        let loaded = storage.get_segments(&id).unwrap();
        assert!(loaded.is_empty());
    }

    #[test]
    fn test_pagination() {
        let (storage, _dir) = temp_storage();
        for i in 0..10 {
            storage.save(&sample_transcription("push_to_talk", &format!("item {i}"))).unwrap();
        }

        let query = TranscriptionQuery {
            search_text: None,
            source_filter: None,
            limit: 3,
            offset: 0,
        };
        let results = storage.list(&query).unwrap();
        assert_eq!(results.len(), 3);

        let query2 = TranscriptionQuery {
            search_text: None,
            source_filter: None,
            limit: 3,
            offset: 7,
        };
        let results2 = storage.list(&query2).unwrap();
        assert_eq!(results2.len(), 3);
    }
}
