//! Bounded text transcript ingestion. Does not load models, run LLMs, or infer identities.
use crate::{
    processing::ProcessingSummary,
    storage::{Storage, StoredTranscription},
    CoreError, TimestampedSegment,
};
use regex::Regex;
use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

pub const MAX_CONTENT_BYTES: usize = 8 * 1024 * 1024;
const MAX_UTTERANCES: usize = 20_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TranscriptProvider {
    Teams,
    Slack,
}
impl TranscriptProvider {
    pub fn name(self) -> &'static str {
        match self {
            Self::Teams => "teams",
            Self::Slack => "slack",
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TranscriptImportRequest {
    pub provider: TranscriptProvider,
    pub source_id: Option<String>,
    pub title: String,
    pub content: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct TranscriptUtterance {
    pub text: String,
    pub speaker: Option<String>,
    pub start_secs: Option<f64>,
    pub end_secs: Option<f64>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TranscriptImportResult {
    pub id: String,
    pub created: bool,
    pub utterance_count: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TranscriptOrigin {
    pub provider: String,
    pub source_id: String,
    pub content_sha256: String,
    pub original_content: String,
    pub imported_at: String,
}

fn invalid(message: impl std::fmt::Display) -> CoreError {
    CoreError::IoError(format!("Transcript import: {message}"))
}

fn time(value: &str) -> Result<f64, CoreError> {
    let parts: Vec<&str> = value.split(':').collect();
    let (hours, minutes, seconds) = match parts.as_slice() {
        [m, s] => ("0", *m, *s),
        [h, m, s] => (*h, *m, *s),
        _ => return Err(invalid("Invalid VTT timestamp")),
    };
    let (secs, millis) = seconds
        .split_once('.')
        .ok_or_else(|| invalid("VTT timestamps require milliseconds"))?;
    if minutes.len() != 2
        || secs.len() != 2
        || millis.len() != 3
        || [hours, minutes, secs, millis]
            .iter()
            .any(|v| v.is_empty() || !v.bytes().all(|b| b.is_ascii_digit()))
    {
        return Err(invalid("Invalid VTT timestamp"));
    }
    let h: u32 = hours.parse().map_err(invalid)?;
    let m: u32 = minutes.parse().map_err(invalid)?;
    let s: u32 = secs.parse().map_err(invalid)?;
    let ms: u32 = millis.parse().map_err(invalid)?;
    if h > 168 || m >= 60 || s >= 60 {
        return Err(invalid("Timestamp outside supported range"));
    }
    Ok(f64::from(h) * 3600.0 + f64::from(m) * 60.0 + f64::from(s) + f64::from(ms) / 1000.0)
}

fn unescape(text: &str) -> String {
    text.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&amp;", "&")
}

fn parse_vtt(content: &str) -> Result<Vec<TranscriptUtterance>, CoreError> {
    let normalized = content.trim_start_matches('\u{feff}').replace("\r\n", "\n");
    let mut lines = normalized.lines();
    let header = lines.next().ok_or_else(|| invalid("Empty VTT"))?;
    if header != "WEBVTT" && !header.starts_with("WEBVTT ") && !header.starts_with("WEBVTT\t") {
        return Err(invalid("Expected WEBVTT header"));
    }
    let voice = Regex::new(r"<v(?:\.[^\s>]+)*\s+([^>]+)>").map_err(invalid)?;
    let markup = Regex::new(r"<[^>]*>").map_err(invalid)?;
    let mut blocks = Vec::new();
    let mut block = Vec::new();
    for line in lines.chain(std::iter::once("")) {
        if line.trim().is_empty() {
            if !block.is_empty() {
                blocks.push(std::mem::take(&mut block));
            }
        } else {
            block.push(line);
        }
    }
    let mut utterances = Vec::new();
    for block in blocks {
        let Some(first) = block.first() else {
            continue;
        };
        if *first == "NOTE" || first.starts_with("NOTE ") || *first == "STYLE" || *first == "REGION"
        {
            continue;
        }
        let Some(position) = block.iter().position(|line| line.contains("-->")) else {
            return Err(invalid("VTT block has no timing line"));
        };
        let timing = block
            .get(position)
            .ok_or_else(|| invalid("Missing timing line"))?;
        let (start, end) = timing
            .split_once("-->")
            .ok_or_else(|| invalid("Invalid cue"))?;
        let end = end
            .split_whitespace()
            .next()
            .ok_or_else(|| invalid("Missing cue end"))?;
        let text = block
            .iter()
            .skip(position + 1)
            .copied()
            .collect::<Vec<_>>()
            .join("\n");
        let speakers = voice
            .captures_iter(&text)
            .filter_map(|c| c.get(1).map(|s| unescape(s.as_str())))
            .collect::<Vec<_>>();
        if speakers.len() > 1 {
            return Err(invalid("Multiple voice tags in one cue are not supported"));
        }
        let text = unescape(&markup.replace_all(&text, ""));
        if text.trim().is_empty() {
            continue;
        }
        utterances.push(TranscriptUtterance {
            text,
            speaker: speakers.into_iter().next(),
            start_secs: Some(time(start.trim())?),
            end_secs: Some(time(end)?),
        });
    }
    Ok(utterances)
}

fn parse_slack(content: &str) -> Result<Vec<TranscriptUtterance>, CoreError> {
    let value: serde_json::Value = serde_json::from_str(content).map_err(invalid)?;
    let file = value.get("file").unwrap_or(&value);
    let transcript = file.get("huddle_transcription").unwrap_or(file);
    let lines = transcript
        .get("lines")
        .and_then(|v| v.as_array())
        .ok_or_else(|| {
            invalid(
                "Expected Slack Huddle transcription lines; a notes summary is not a transcript",
            )
        })?;
    if lines.len() > MAX_UTTERANCES {
        return Err(invalid("Too many utterances"));
    }
    lines
        .iter()
        .map(|line| {
            let text = line
                .get("text")
                .or_else(|| line.get("contents"))
                .and_then(|v| v.as_str())
                .ok_or_else(|| {
                    invalid("Unsupported Slack line: expected text or string contents")
                })?;
            let speaker = line.get("user_id").or_else(|| line.get("speaker"));
            if speaker.is_some_and(|v| !v.is_null() && !v.is_string()) {
                return Err(invalid("Invalid Slack speaker"));
            }
            let milliseconds = |name: &str| -> Result<Option<f64>, CoreError> {
                match line.get(name) {
                    None | Some(serde_json::Value::Null) => Ok(None),
                    Some(v) => v
                        .as_f64()
                        .filter(|v| v.is_finite())
                        .map(|v| Some(v / 1000.0))
                        .ok_or_else(|| invalid("Invalid Slack timestamp")),
                }
            };
            Ok(TranscriptUtterance {
                text: text.into(),
                speaker: speaker.and_then(|v| v.as_str()).map(str::to_owned),
                start_secs: milliseconds("start_time_ms")?,
                end_secs: milliseconds("end_time_ms")?,
            })
        })
        .collect()
}

pub fn parse_transcript(
    request: &TranscriptImportRequest,
) -> Result<Vec<TranscriptUtterance>, CoreError> {
    if request.content.len() > MAX_CONTENT_BYTES || request.content.contains('\0') {
        return Err(invalid("Invalid or oversized content"));
    }
    if request.title.trim().is_empty()
        || request.title.contains(['\0', '\n', '\r'])
        || request.title.len() > 1024
        || request.source_id.as_ref().is_some_and(|id| {
            id.trim().is_empty() || id.len() > 4096 || id.contains(['\0', '\n', '\r'])
        })
    {
        return Err(invalid("Invalid title or source ID"));
    }
    let utterances = match request.provider {
        TranscriptProvider::Teams => parse_vtt(&request.content)?,
        TranscriptProvider::Slack => parse_slack(&request.content)?,
    };
    if utterances.is_empty() || utterances.len() > MAX_UTTERANCES {
        return Err(invalid("Expected 1–20000 utterances"));
    }
    for u in &utterances {
        if u.text.trim().is_empty()
            || u.text.len() > 65536
            || u.text.contains('\0')
            || u.speaker.as_ref().is_some_and(|s| {
                s.trim().is_empty() || s.len() > 512 || s.contains(['\n', '\r', '\0'])
            })
        {
            return Err(invalid("Invalid utterance text or speaker"));
        }
        match (u.start_secs, u.end_secs) {
            (None, None) => {}
            (Some(start), Some(end))
                if start.is_finite()
                    && end.is_finite()
                    && start >= 0.0
                    && end > start
                    && end <= 604800.0 => {}
            _ => return Err(invalid("Expected a valid timestamp pair, or no timestamps")),
        }
    }
    Ok(utterances)
}

impl Storage {
    pub(crate) fn migrate_transcript_imports(&self) -> Result<(), CoreError> {
        self.conn.execute_batch("CREATE TABLE IF NOT EXISTS transcript_origins (
            transcription_id TEXT PRIMARY KEY REFERENCES transcriptions(id) ON DELETE CASCADE,
            provider TEXT NOT NULL, source_id TEXT NOT NULL, content_sha256 TEXT NOT NULL,
            original_content TEXT NOT NULL, imported_at TEXT NOT NULL, utterances TEXT NOT NULL,
            UNIQUE(provider,source_id,content_sha256));
            CREATE TABLE IF NOT EXISTS transcript_speaker_aliases (
            transcription_id TEXT NOT NULL REFERENCES transcriptions(id) ON DELETE CASCADE,
            original TEXT NOT NULL, display_name TEXT NOT NULL, PRIMARY KEY(transcription_id,original));").map_err(invalid)
    }

    pub fn import_transcript(
        &self,
        request: &TranscriptImportRequest,
    ) -> Result<TranscriptImportResult, CoreError> {
        let utterances = parse_transcript(request)?;
        let count = u32::try_from(utterances.len()).map_err(invalid)?;
        let hash = crate::util::hex_lower(&Sha256::digest(request.content.as_bytes()));
        let source_id = request.source_id.as_deref().unwrap_or(&hash);
        let tx = self.conn.unchecked_transaction().map_err(invalid)?;
        let existing: Option<String> = self.conn.query_row("SELECT transcription_id FROM transcript_origins WHERE provider=?1 AND source_id=?2 AND content_sha256=?3", params![request.provider.name(),source_id,hash], |r| r.get(0)).optional().map_err(invalid)?;
        if let Some(id) = existing {
            return Ok(TranscriptImportResult {
                id,
                created: false,
                utterance_count: count,
            });
        }
        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now().to_rfc3339();
        let text = utterances
            .iter()
            .map(|u| {
                u.speaker
                    .as_ref()
                    .map_or_else(|| u.text.clone(), |s| format!("{s}: {}", u.text))
            })
            .collect::<Vec<_>>()
            .join("\n\n");
        let segments: Vec<_> = utterances
            .iter()
            .filter_map(|u| {
                Some(TimestampedSegment {
                    text: u.text.clone(),
                    speaker: u.speaker.clone(),
                    start_secs: u.start_secs?,
                    end_secs: u.end_secs?,
                })
            })
            .collect();
        let duration_secs = segments.iter().map(|s| s.end_secs).fold(0.0, f64::max);
        self.save_complete_inner(
            &StoredTranscription {
                id: id.clone(),
                created_at: now.clone(),
                duration_secs,
                source: "import".into(),
                mode: "dictation".into(),
                audio_source: Some(request.provider.name().into()),
                app_context: None,
                title: Some(request.title.clone()),
                text: text.clone(),
            },
            &segments,
            &ProcessingSummary {
                recognized_text: text,
                status: "completed".into(),
            },
        )?;
        self.conn
            .execute(
                "INSERT INTO transcript_origins VALUES(?1,?2,?3,?4,?5,?6,?7)",
                params![
                    id,
                    request.provider.name(),
                    source_id,
                    hash,
                    request.content,
                    now,
                    serde_json::to_string(&utterances).map_err(invalid)?
                ],
            )
            .map_err(invalid)?;
        tx.commit().map_err(invalid)?;
        Ok(TranscriptImportResult {
            id,
            created: true,
            utterance_count: count,
        })
    }

    pub fn transcript_origin(&self, id: &str) -> Result<TranscriptOrigin, CoreError> {
        self.conn.query_row("SELECT provider,source_id,content_sha256,original_content,imported_at FROM transcript_origins WHERE transcription_id=?1",[id],|r| Ok(TranscriptOrigin {provider:r.get(0)?,source_id:r.get(1)?,content_sha256:r.get(2)?,original_content:r.get(3)?,imported_at:r.get(4)?})).map_err(invalid)
    }

    pub fn imported_utterances(&self, id: &str) -> Result<Vec<TranscriptUtterance>, CoreError> {
        let json: String = self
            .conn
            .query_row(
                "SELECT utterances FROM transcript_origins WHERE transcription_id=?1",
                [id],
                |r| r.get(0),
            )
            .map_err(invalid)?;
        let mut utterances: Vec<TranscriptUtterance> =
            serde_json::from_str(&json).map_err(invalid)?;
        let mut statement = self.conn.prepare("SELECT original,display_name FROM transcript_speaker_aliases WHERE transcription_id=?1").map_err(invalid)?;
        let aliases = statement
            .query_map([id], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
            })
            .map_err(invalid)?
            .collect::<Result<std::collections::HashMap<_, _>, _>>()
            .map_err(invalid)?;
        for u in &mut utterances {
            if let Some(alias) = u.speaker.as_ref().and_then(|s| aliases.get(s)) {
                u.speaker = Some(alias.clone());
            }
        }
        Ok(utterances)
    }

    pub fn set_speaker_alias(
        &self,
        id: &str,
        original: &str,
        display: &str,
    ) -> Result<(), CoreError> {
        let raw: String = self
            .conn
            .query_row(
                "SELECT utterances FROM transcript_origins WHERE transcription_id=?1",
                [id],
                |r| r.get(0),
            )
            .map_err(invalid)?;
        let utterances: Vec<TranscriptUtterance> = serde_json::from_str(&raw).map_err(invalid)?;
        if !utterances
            .iter()
            .any(|u| u.speaker.as_deref() == Some(original))
            || display.len() > 512
            || display.contains(['\n', '\r', '\0'])
        {
            return Err(invalid("Invalid speaker correction"));
        }
        if display.trim().is_empty() {
            self.conn.execute("DELETE FROM transcript_speaker_aliases WHERE transcription_id=?1 AND original=?2",params![id,original]).map_err(invalid)?;
        } else {
            self.conn.execute("INSERT INTO transcript_speaker_aliases VALUES(?1,?2,?3) ON CONFLICT(transcription_id,original) DO UPDATE SET display_name=excluded.display_name",params![id,original,display.trim()]).map_err(invalid)?;
        }
        Ok(())
    }
}
