//! End-to-end integration tests for the cache-aware streaming
//! preview pipeline.
//!
//! These tests use a `ScriptedStreamingProvider` injected into a
//! real `Engine` via `install_streaming_provider`. We then drive
//! `start_streaming_session` / `feed_streaming_chunk` /
//! `finish_streaming_session` exactly as the Swift side does and
//! assert that the LocalAgreement-2 commit policy plus the engine
//! glue produce the right `committed_text` / `tentative_text`
//! progression.
//!
//! The point of these tests is to catch regressions like:
//!   - silence breaks LA-2
//!   - empty deltas leak into committed text
//!   - long sessions blow up memory
//!   - reset doesn't actually reset
//!   - concurrent sessions share state
//!   - flicker scenarios commit prematurely
//!
//! Each scenario is named after the failure mode it guards against
//! so a future regression points us straight at the cause.

use parakatt_core::engine::Engine;
use parakatt_core::stt::ScriptedStreamingProvider;
use parakatt_core::EngineConfig;

/// Create a fresh `Engine` rooted in a unique temp directory and
/// install a `ScriptedStreamingProvider` configured with the given
/// hypothesis sequence.
fn engine_with_script(test_name: &str, hypotheses: Vec<&str>) -> Engine {
    let tmp = std::env::temp_dir().join(format!(
        "parakatt-streaming-e2e-{}-{}",
        test_name,
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::create_dir_all(&tmp).unwrap();

    let config = EngineConfig {
        models_dir: tmp.join("models").to_string_lossy().to_string(),
        config_dir: tmp.join("config").to_string_lossy().to_string(),
        active_stt_model: None,
        active_llm_provider: None,
        active_mode: "dictation".to_string(),
    };

    let engine = Engine::new(config).expect("Engine should construct");
    let provider = Box::new(ScriptedStreamingProvider::new(hypotheses));
    engine
        .install_streaming_provider(provider)
        .expect("Provider install should succeed");
    engine
}

// =====================================================
// T3: happy path — multi-chunk session, stable progression
// =====================================================

#[test]
fn t3_happy_path_progressive_commits() {
    let engine = engine_with_script(
        "happy",
        vec![
            "hello",
            "hello world",
            "hello world this",
            "hello world this is",
            "hello world this is a test",
        ],
    );
    engine.start_streaming_session("s1".into()).unwrap();

    // Pass 1: nothing committed yet (LA-2 needs at least two
    // matching passes to commit anything).
    let r1 = engine
        .feed_streaming_chunk("s1".into(), vec![0.0; 8000])
        .unwrap();
    assert_eq!(r1.committed_text, "", "no commits on first pass");
    assert_eq!(r1.tentative_text, "hello");

    // Pass 2: "hello" appeared in both passes → committed.
    // "world" is now tentative.
    let r2 = engine
        .feed_streaming_chunk("s1".into(), vec![0.0; 8000])
        .unwrap();
    assert_eq!(r2.committed_text, "hello");
    assert_eq!(r2.tentative_text, "world");

    // Pass 3: "world" stable → committed. "this" tentative.
    let r3 = engine
        .feed_streaming_chunk("s1".into(), vec![0.0; 8000])
        .unwrap();
    assert_eq!(r3.committed_text, "hello world");
    assert_eq!(r3.tentative_text, "this");

    // Pass 4: "this" stable → committed. "is" tentative.
    let r4 = engine
        .feed_streaming_chunk("s1".into(), vec![0.0; 8000])
        .unwrap();
    assert_eq!(r4.committed_text, "hello world this");
    assert_eq!(r4.tentative_text, "is");

    // Pass 5: "is" stable → committed. "a test" tentative.
    let r5 = engine
        .feed_streaming_chunk("s1".into(), vec![0.0; 8000])
        .unwrap();
    assert_eq!(r5.committed_text, "hello world this is");
    assert_eq!(r5.tentative_text, "a test");

    // Finish takes the model's full transcript as canonical.
    let final_text = engine.finish_streaming_session("s1".into()).unwrap();
    assert_eq!(final_text, "hello world this is a test");
}

// =====================================================
// T4: flicker scenarios — alternates at various positions
// =====================================================

#[test]
fn t4_flicker_at_tail_only_commits_through_stable_prefix() {
    // The classic "good warning" / "good morning" flicker. The
    // diverging tail token must NEVER make it into committed text
    // until two consecutive passes agree.
    let engine = engine_with_script(
        "flicker_tail",
        vec![
            "welcome everyone good warning",
            "welcome everyone good morning",
            "welcome everyone good morning today",
        ],
    );
    engine.start_streaming_session("s1".into()).unwrap();

    let r1 = engine.feed_streaming_chunk("s1".into(), vec![0.0; 8000]).unwrap();
    assert_eq!(r1.committed_text, "");

    let r2 = engine.feed_streaming_chunk("s1".into(), vec![0.0; 8000]).unwrap();
    // "welcome everyone good" stable across both → committed.
    // The flicker word ("warning" vs "morning") is NOT committed yet.
    assert_eq!(r2.committed_text, "welcome everyone good");
    assert!(
        !r2.committed_text.contains("warning"),
        "warning leaked into committed text"
    );
    assert!(
        !r2.committed_text.contains("morning"),
        "morning leaked into committed text on first agreement"
    );

    let r3 = engine.feed_streaming_chunk("s1".into(), vec![0.0; 8000]).unwrap();
    // Now "morning" appeared in two passes (2 and 3) → committed.
    assert_eq!(r3.committed_text, "welcome everyone good morning");
    assert!(!r3.committed_text.contains("warning"));
}

#[test]
fn t4_flicker_in_middle_freezes_commit_at_divergence() {
    let engine = engine_with_script(
        "flicker_mid",
        vec![
            "the meeting started with introductions",
            "the meeting started with introduction", // diverges at word 5
            "the meeting started with introductions and then",
        ],
    );
    engine.start_streaming_session("s1".into()).unwrap();
    let _ = engine.feed_streaming_chunk("s1".into(), vec![0.0; 8000]).unwrap();
    let r2 = engine.feed_streaming_chunk("s1".into(), vec![0.0; 8000]).unwrap();
    // "the meeting started with" stable; word 5 diverges so it's
    // tentative.
    assert_eq!(r2.committed_text, "the meeting started with");
    let r3 = engine.feed_streaming_chunk("s1".into(), vec![0.0; 8000]).unwrap();
    // Now "introductions" appears in passes 1 and 3 — but they're
    // not CONSECUTIVE passes. LA-2 needs the *previous* hypothesis
    // (pass 2 = "introduction") to agree with the current
    // (pass 3 = "introductions"). They don't, so word 5 is still
    // tentative.
    assert_eq!(r3.committed_text, "the meeting started with");
}

// =====================================================
// T5: silence handling — empty hypotheses
// =====================================================

#[test]
fn t5_empty_hypotheses_leave_committed_unchanged() {
    // Real silence: the model returns the same hypothesis for
    // many consecutive chunks because no new audio came in.
    let engine = engine_with_script(
        "silence",
        vec![
            "hello world",
            "hello world", // silence — no new tokens
            "hello world", // silence
            "hello world", // silence
            "hello world", // silence
            "hello world more text",
        ],
    );
    engine.start_streaming_session("s1".into()).unwrap();

    let r1 = engine.feed_streaming_chunk("s1".into(), vec![0.0; 8000]).unwrap();
    assert_eq!(r1.committed_text, "");

    let r2 = engine.feed_streaming_chunk("s1".into(), vec![0.0; 8000]).unwrap();
    assert_eq!(r2.committed_text, "hello world");
    assert_eq!(r2.tentative_text, "");

    // Three more silent passes — committed must NOT regress, NOT
    // grow, and NOT churn.
    for _ in 0..3 {
        let r = engine.feed_streaming_chunk("s1".into(), vec![0.0; 8000]).unwrap();
        assert_eq!(r.committed_text, "hello world");
        assert_eq!(r.tentative_text, "");
        assert_eq!(r.newly_committed_text, "", "no new commits during silence");
    }

    // Speech resumes — new tokens land.
    let rN = engine.feed_streaming_chunk("s1".into(), vec![0.0; 8000]).unwrap();
    assert_eq!(rN.committed_text, "hello world");
    assert_eq!(rN.tentative_text, "more text");
}

#[test]
fn t5_completely_empty_session_works() {
    // Pathological: model returns the empty string forever.
    let engine = engine_with_script("empty", vec!["", "", ""]);
    engine.start_streaming_session("s1".into()).unwrap();
    for _ in 0..3 {
        let r = engine.feed_streaming_chunk("s1".into(), vec![0.0; 8000]).unwrap();
        assert_eq!(r.committed_text, "");
        assert_eq!(r.tentative_text, "");
    }
    assert_eq!(engine.finish_streaming_session("s1".into()).unwrap(), "");
}

// =====================================================
// T6: speech-resume after long silence
// =====================================================

#[test]
fn t6_speech_resume_after_silence_appends_correctly() {
    // 2 chunks of speech, 10 chunks of silence, 3 more chunks of
    // speech that extends the transcript.
    let mut hypotheses: Vec<String> = vec![
        "first sentence".to_string(),
        "first sentence".to_string(),
    ];
    for _ in 0..10 {
        hypotheses.push("first sentence".to_string());
    }
    hypotheses.extend([
        "first sentence and now more".to_string(),
        "first sentence and now more text".to_string(),
        "first sentence and now more text here".to_string(),
    ]);
    let h_refs: Vec<&str> = hypotheses.iter().map(|s| s.as_str()).collect();

    let engine = engine_with_script("resume", h_refs);
    engine.start_streaming_session("s1".into()).unwrap();

    for _ in 0..hypotheses.len() {
        let _ = engine.feed_streaming_chunk("s1".into(), vec![0.0; 8000]).unwrap();
    }

    let final_text = engine.finish_streaming_session("s1".into()).unwrap();
    assert!(
        final_text.contains("first sentence"),
        "lost the pre-silence segment: {final_text}"
    );
    assert!(
        final_text.contains("more text here"),
        "lost the post-silence segment: {final_text}"
    );
}

// =====================================================
// T7: long session memory — many chunks, no leak
// =====================================================

#[test]
fn t7_long_session_doesnt_grow_unboundedly() {
    // Build a 200-step progression. We don't measure RSS but we DO
    // verify that the committed transcript only ever grows
    // monotonically and that we never panic or hang.
    let mut hypotheses: Vec<String> = Vec::new();
    let words: Vec<String> = (0..200).map(|i| format!("word{i}")).collect();
    let mut acc = String::new();
    for w in &words {
        if !acc.is_empty() {
            acc.push(' ');
        }
        acc.push_str(w);
        hypotheses.push(acc.clone());
    }
    let h_refs: Vec<&str> = hypotheses.iter().map(|s| s.as_str()).collect();

    let engine = engine_with_script("long", h_refs);
    engine.start_streaming_session("s1".into()).unwrap();

    let mut last_committed_len = 0;
    for _ in 0..hypotheses.len() {
        let r = engine.feed_streaming_chunk("s1".into(), vec![0.0; 8000]).unwrap();
        assert!(
            r.committed_text.len() >= last_committed_len,
            "committed text shrank!"
        );
        last_committed_len = r.committed_text.len();
    }

    let final_text = engine.finish_streaming_session("s1".into()).unwrap();
    assert!(final_text.contains("word0"));
    assert!(final_text.contains("word199"));
}

// =====================================================
// T8: concurrent sessions are isolated
// =====================================================

#[test]
fn t8_concurrent_sessions_are_isolated() {
    let engine = engine_with_script(
        "concurrent",
        vec!["alpha", "alpha bravo", "alpha bravo charlie"],
    );
    engine.start_streaming_session("a".into()).unwrap();
    engine.start_streaming_session("b".into()).unwrap();

    // Drive session A two passes.
    let _ = engine.feed_streaming_chunk("a".into(), vec![0.0; 8000]).unwrap();
    let a2 = engine.feed_streaming_chunk("a".into(), vec![0.0; 8000]).unwrap();
    assert_eq!(a2.committed_text, "alpha");

    // Session B is still empty.
    let b1 = engine.feed_streaming_chunk("b".into(), vec![0.0; 8000]).unwrap();
    assert_eq!(b1.committed_text, "", "session B got A's committed text");

    let b2 = engine.feed_streaming_chunk("b".into(), vec![0.0; 8000]).unwrap();
    assert_eq!(b2.committed_text, "alpha");

    let a_final = engine.finish_streaming_session("a".into()).unwrap();
    let b_final = engine.finish_streaming_session("b".into()).unwrap();
    assert_eq!(a_final, b_final, "both sessions saw the same script");
}

// =====================================================
// T9: reset mid-session clears state
// =====================================================

#[test]
fn t9_reset_clears_model_and_la2_state() {
    let engine = engine_with_script(
        "reset",
        vec!["foo", "foo bar", "foo bar baz"],
    );
    engine.start_streaming_session("s1".into()).unwrap();

    let _ = engine.feed_streaming_chunk("s1".into(), vec![0.0; 8000]).unwrap();
    let r2 = engine.feed_streaming_chunk("s1".into(), vec![0.0; 8000]).unwrap();
    assert_eq!(r2.committed_text, "foo");

    engine.reset_streaming_session("s1".into()).unwrap();

    // After reset, the next pass should start fresh and commit nothing.
    let r3 = engine.feed_streaming_chunk("s1".into(), vec![0.0; 8000]).unwrap();
    assert_eq!(r3.committed_text, "", "reset did not clear committed");
    assert_eq!(r3.tentative_text, "foo");
}

// =====================================================
// T10: error injection
// =====================================================

#[test]
fn t10_provider_error_propagates_session_recoverable() {
    let tmp = std::env::temp_dir().join(format!("parakatt-streaming-e2e-error-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::create_dir_all(&tmp).unwrap();

    let config = EngineConfig {
        models_dir: tmp.join("models").to_string_lossy().to_string(),
        config_dir: tmp.join("config").to_string_lossy().to_string(),
        active_stt_model: None,
        active_llm_provider: None,
        active_mode: "dictation".to_string(),
    };
    let engine = Engine::new(config).expect("Engine ok");
    let provider = Box::new(
        ScriptedStreamingProvider::new(vec!["a", "a b", "a b c"])
            .with_error_at(1),
    );
    engine.install_streaming_provider(provider).unwrap();

    engine.start_streaming_session("s1".into()).unwrap();
    let r1 = engine.feed_streaming_chunk("s1".into(), vec![0.0; 8000]).unwrap();
    assert_eq!(r1.tentative_text, "a");

    // Second feed errors.
    let r2 = engine.feed_streaming_chunk("s1".into(), vec![0.0; 8000]);
    assert!(r2.is_err(), "expected error from scripted provider");

    // The session must still be usable: the third feed succeeds.
    let r3 = engine.feed_streaming_chunk("s1".into(), vec![0.0; 8000]).unwrap();
    // Note that the cursor advanced past the error so the third
    // hypothesis ("a b c") is what comes back.
    assert!(r3.committed_text.contains("a") || r3.tentative_text.contains("a"));

    // Cleanup must succeed.
    let _ = engine.finish_streaming_session("s1".into()).unwrap();
}

// =====================================================
// Lifecycle: missing model, double start, finish without start
// =====================================================

#[test]
fn lifecycle_streaming_without_model_returns_error() {
    let tmp = std::env::temp_dir().join(format!("parakatt-streaming-e2e-nomodel-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::create_dir_all(&tmp).unwrap();
    let config = EngineConfig {
        models_dir: tmp.join("models").to_string_lossy().to_string(),
        config_dir: tmp.join("config").to_string_lossy().to_string(),
        active_stt_model: None,
        active_llm_provider: None,
        active_mode: "dictation".to_string(),
    };
    let engine = Engine::new(config).expect("Engine ok");
    // No streaming provider installed → should fail.
    assert!(engine.start_streaming_session("s1".into()).is_err());
}

#[test]
fn lifecycle_double_start_same_id_errors() {
    let engine = engine_with_script("double_start", vec!["a"]);
    engine.start_streaming_session("s1".into()).unwrap();
    assert!(engine.start_streaming_session("s1".into()).is_err());
}

#[test]
fn lifecycle_feed_unknown_session_errors() {
    let engine = engine_with_script("unknown_feed", vec!["a"]);
    assert!(engine.feed_streaming_chunk("nope".into(), vec![]).is_err());
}

#[test]
fn lifecycle_finish_unknown_session_errors() {
    let engine = engine_with_script("unknown_finish", vec!["a"]);
    assert!(engine.finish_streaming_session("nope".into()).is_err());
}

#[test]
fn lifecycle_cancel_is_idempotent() {
    let engine = engine_with_script("cancel", vec!["a"]);
    engine.cancel_streaming_session("never_existed".into());
    engine.start_streaming_session("s1".into()).unwrap();
    engine.cancel_streaming_session("s1".into());
    // Now we can start a new session with the same id.
    engine.start_streaming_session("s1".into()).unwrap();
}

// =====================================================
// Buffered preview path lifecycle (Nemotron-absent fallback)
// =====================================================

#[test]
fn buffered_preview_double_start_errors() {
    let engine = engine_with_script("bp_double", vec!["a"]);
    engine.buffered_preview_start("s1".into()).unwrap();
    assert!(engine.buffered_preview_start("s1".into()).is_err());
}

#[test]
fn buffered_preview_finish_unknown_errors() {
    let engine = engine_with_script("bp_unknown", vec!["a"]);
    assert!(engine.buffered_preview_finish("nope".into()).is_err());
}

#[test]
fn buffered_preview_cancel_idempotent() {
    let engine = engine_with_script("bp_cancel", vec!["a"]);
    engine.buffered_preview_cancel("never".into());
    engine.buffered_preview_start("s1".into()).unwrap();
    engine.buffered_preview_cancel("s1".into());
    engine.buffered_preview_start("s1".into()).unwrap();
}

#[test]
fn buffered_preview_update_without_stt_errors() {
    // No Parakeet model loaded → buffered_preview_update must fail
    // cleanly with "No STT model loaded".
    let engine = engine_with_script("bp_no_stt", vec!["a"]);
    engine.buffered_preview_start("s1".into()).unwrap();
    let res = engine.buffered_preview_update(
        "s1".into(),
        vec![0.5; 8000],
        16_000,
    );
    assert!(res.is_err());
    let msg = format!("{:?}", res.unwrap_err());
    assert!(
        msg.contains("STT") || msg.contains("model"),
        "expected 'no STT model' error, got: {msg}"
    );
}

#[test]
fn buffered_preview_finish_returns_la2_committed() {
    // Without an STT model we can't actually feed it audio, but
    // we can verify that finish returns the empty committed text
    // for a fresh session.
    let engine = engine_with_script("bp_finish", vec!["a"]);
    engine.buffered_preview_start("s1".into()).unwrap();
    let r = engine.buffered_preview_finish("s1".into()).unwrap();
    assert_eq!(r, "");
}

#[test]
fn buffered_preview_reset_clears_committed() {
    let engine = engine_with_script("bp_reset", vec!["a"]);
    engine.buffered_preview_start("s1".into()).unwrap();
    // Reset on an empty session is a no-op but must not error.
    engine.buffered_preview_reset("s1".into()).unwrap();
    let r = engine.buffered_preview_finish("s1".into()).unwrap();
    assert_eq!(r, "");
}
