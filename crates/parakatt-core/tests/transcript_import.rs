use parakatt_core::{
    storage::Storage,
    transcript_import::{parse_transcript, TranscriptImportRequest, TranscriptProvider},
};

fn request(provider: TranscriptProvider, content: &str) -> TranscriptImportRequest {
    TranscriptImportRequest {
        provider,
        source_id: Some("meeting-1/transcript-1".into()),
        title: "Office meeting".into(),
        content: content.into(),
    }
}
const VTT: &str = "WEBVTT\n\n1\n00:00:00.100 --> 00:00:02.000\n<v Alice &amp; Bob>Hello <b>everyone</b>.</v>\n\n2\n00:00:01.500 --> 00:00:03.000 align:start\n<v Sam>Thanks.</v>\n";

#[test]
fn teams_keeps_names_timing_overlap_and_plain_text() {
    let cues = parse_transcript(&request(TranscriptProvider::Teams, VTT)).unwrap();
    assert_eq!(cues.len(), 2);
    assert_eq!(cues[0].speaker.as_deref(), Some("Alice & Bob"));
    assert_eq!(cues[0].text, "Hello everyone.");
    assert_eq!(cues[1].start_secs, Some(1.5));
}

#[test]
fn slack_keeps_stable_user_ids_and_does_not_invent_missing_times() {
    let data = r#"{"file":{"huddle_transcription":{"lines":[{"contents":"An untimed statement","user_id":"U123"},{"text":"Timed","user_id":"U456","start_time_ms":1200,"end_time_ms":2400}]}}}"#;
    let cues = parse_transcript(&request(TranscriptProvider::Slack, data)).unwrap();
    assert_eq!(cues[0].speaker.as_deref(), Some("U123"));
    assert_eq!(cues[0].start_secs, None);
    assert_eq!(cues[1].start_secs, Some(1.2));
}

#[test]
fn malformed_input_and_summaries_are_rejected() {
    let mut oversized = request(TranscriptProvider::Teams, VTT);
    oversized.content = "x".repeat(parakatt_core::transcript_import::MAX_CONTENT_BYTES + 1);
    assert!(parse_transcript(&oversized).is_err());
    let mut bad_title = request(TranscriptProvider::Teams, VTT);
    bad_title.title = "Bad\0title".into();
    assert!(parse_transcript(&bad_title).is_err());
    for data in [
        "Not VTT",
        "WEBVTT\n\n00:00:03.000 --> 00:00:02.000\nNo",
        "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n<v A>One</v><v B>Two</v>",
        "WEBVTT\n\n999999999999999999:00:00.000 --> 00:00:02.000\nBad",
    ] {
        assert!(
            parse_transcript(&request(TranscriptProvider::Teams, data)).is_err(),
            "{data}"
        );
    }
    for data in [
        r#"{"summary":"An AI summary"}"#,
        r#"{"lines":[{"text":"Hi","start_time_ms":-10,"end_time_ms":10}]}"#,
        r#"{"lines":[{"text":"Hi","start_time_ms":10}]}"#,
    ] {
        assert!(parse_transcript(&request(TranscriptProvider::Slack, data)).is_err());
    }
}

#[test]
fn import_is_atomic_idempotent_and_preserves_edits_originals_and_aliases() {
    let dir = tempfile::tempdir().unwrap();
    let storage = Storage::open(dir.path()).unwrap();
    let input = request(TranscriptProvider::Teams, VTT);
    let first = storage.import_transcript(&input).unwrap();
    assert!(first.created);
    storage
        .edit_transcription(&first.id, "User-edited minutes")
        .unwrap();
    let again = storage.import_transcript(&input).unwrap();
    assert_eq!(first.id, again.id);
    assert!(!again.created);
    assert_eq!(storage.get(&first.id).unwrap().text, "User-edited minutes");
    storage
        .set_speaker_alias(&first.id, "Sam", "Samantha")
        .unwrap();
    assert_eq!(
        storage.get_segments(&first.id).unwrap()[1]
            .speaker
            .as_deref(),
        Some("Samantha")
    );
    assert_eq!(
        storage.imported_utterances(&first.id).unwrap()[1]
            .speaker
            .as_deref(),
        Some("Samantha")
    );
    assert_eq!(
        storage
            .transcript_origin(&first.id)
            .unwrap()
            .original_content,
        VTT
    );
    storage.set_speaker_alias(&first.id, "Sam", "").unwrap();
    assert_eq!(
        storage.get_segments(&first.id).unwrap()[1]
            .speaker
            .as_deref(),
        Some("Sam")
    );
    assert!(storage
        .set_speaker_alias(&first.id, "Unknown", "Guessed name")
        .is_err());
    let bad = request(TranscriptProvider::Teams, "invalid");
    assert!(storage.import_transcript(&bad).is_err());
    drop(storage);
    let storage = Storage::open(dir.path()).unwrap();
    assert_eq!(
        storage.transcript_origin(&first.id).unwrap().source_id,
        "meeting-1/transcript-1"
    );
    storage.delete(&first.id).unwrap();
    assert!(storage.transcript_origin(&first.id).is_err());
}

#[test]
fn source_revision_is_a_new_record_and_untimed_import_needs_no_model() {
    let dir = tempfile::tempdir().unwrap();
    let storage = Storage::open(dir.path()).unwrap();
    let first = storage
        .import_transcript(&request(TranscriptProvider::Teams, VTT))
        .unwrap();
    let second = storage
        .import_transcript(&request(
            TranscriptProvider::Teams,
            &VTT.replace("Thanks.", "Changed."),
        ))
        .unwrap();
    assert_ne!(first.id, second.id);
    let untimed = request(
        TranscriptProvider::Slack,
        r#"{"lines":[{"text":"Review the contract","user_id":"U1"}]}"#,
    );
    let imported = storage.import_transcript(&untimed).unwrap();
    assert!(storage.get_segments(&imported.id).unwrap().is_empty());
    assert_eq!(
        storage.imported_utterances(&imported.id).unwrap()[0].start_secs,
        None
    );
}

#[test]
fn confirmed_actions_validate_evidence_and_dates_and_survive_backup() {
    let dir = tempfile::tempdir().unwrap();
    let mut storage = Storage::open(dir.path()).unwrap();
    let imported = storage
        .import_transcript(&request(TranscriptProvider::Teams, VTT))
        .unwrap();
    let action = storage
        .add_meeting_action(&imported.id, "Review contract", None, None, 0)
        .unwrap();
    assert_eq!(action.owner, None);
    assert_eq!(action.due_date, None);
    assert_eq!(action.source_quote, "Hello everyone.");
    assert!(storage
        .add_meeting_action(&imported.id, "Bad date", None, Some("2026-02-30".into()), 0)
        .is_err());
    assert!(storage
        .add_meeting_action(&imported.id, "No evidence", None, None, 999)
        .is_err());
    storage
        .complete_meeting_action(&imported.id, &action.id, true)
        .unwrap();
    let backup = dir.path().join("backup.db");
    storage.export_to(&backup).unwrap();
    storage.delete(&imported.id).unwrap();
    storage.import_from(&backup, dir.path()).unwrap();
    let actions = storage.meeting_actions(&imported.id).unwrap();
    assert_eq!(actions.len(), 1);
    assert!(actions[0].completed);
    assert_eq!(actions[0].source_quote, "Hello everyone.");
    assert_eq!(
        storage
            .transcript_origin(&imported.id)
            .unwrap()
            .original_content,
        VTT
    );
}
