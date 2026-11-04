use parakatt_core::{session::SessionManager, ChunkSource, TimestampedSegment};

fn sentence(text: &str, start: f64, end: f64) -> TimestampedSegment {
    TimestampedSegment {
        text: text.into(),
        start_secs: start,
        end_secs: end,
        speaker: None,
    }
}

#[test]
fn overlap_must_keep_new_speech_in_a_sentence_that_crosses_the_overlap() {
    let mut manager = SessionManager::new();
    manager.start("audit").unwrap();
    manager
        .add_chunk_with_overlap(
            "audit",
            "Earlier speech.",
            30.0,
            0.0,
            vec![sentence("Earlier speech.", 0.0, 29.0)],
        )
        .unwrap();
    let next = manager
        .add_chunk_with_overlap(
            "audit",
            "Repeated tail and NEW CONTENT.",
            30.0,
            2.0,
            vec![sentence("Repeated tail and NEW CONTENT.", 0.5, 12.0)],
        )
        .unwrap();
    assert!(
        next.text.contains("NEW CONTENT"),
        "Accepted text: {:?}",
        next.text
    );
}

#[test]
fn dual_source_overlap_must_keep_new_speech_in_a_crossing_sentence() {
    let mut manager = SessionManager::new();
    manager.start("audit").unwrap();
    manager
        .add_chunk_with_source(
            "audit",
            ChunkSource::Mic,
            0,
            "Earlier speech.",
            30.0,
            0.0,
            vec![sentence("Earlier speech.", 0.0, 29.0)],
        )
        .unwrap();
    let next = manager
        .add_chunk_with_source(
            "audit",
            ChunkSource::Mic,
            1,
            "Repeated tail and NEW CONTENT.",
            30.0,
            2.0,
            vec![sentence("Repeated tail and NEW CONTENT.", 0.5, 12.0)],
        )
        .unwrap();
    assert!(
        next.text.contains("NEW CONTENT"),
        "Accepted text: {:?}",
        next.text
    );
}
