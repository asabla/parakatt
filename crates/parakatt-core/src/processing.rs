//! Ordered recognized chunks with a bounded, cancellable polishing worker.
use crate::{
    llm::{LlmProvider, LlmRequest},
    ChunkSource, CoreError,
};
use std::{
    collections::{BTreeMap, VecDeque},
    sync::{Arc, Condvar, Mutex},
};
use tokio_util::sync::CancellationToken;

#[derive(Debug, Clone, uniffi::Enum)]
pub enum ProcessingState {
    Recognized,
    Processing,
    Processed,
    Failed,
    Finished,
}
#[derive(Debug, Clone, uniffi::Record)]
pub struct TranscriptionEvent {
    pub session_id: String,
    pub chunk_id: u32,
    pub source: ChunkSource,
    pub revision: u32,
    pub state: ProcessingState,
    pub text: String,
    pub error: Option<String>,
}
#[derive(Debug, Clone, uniffi::Record)]
pub struct ProcessingSummary {
    pub recognized_text: String,
    pub status: String,
}
type Key = (u32, u8);
fn key(index: u32, source: ChunkSource) -> Key {
    (
        index,
        match source {
            ChunkSource::Mixed => 0,
            ChunkSource::Mic => 1,
            ChunkSource::System => 2,
        },
    )
}
struct Chunk {
    raw: String,
    text: String,
    source: ChunkSource,
    error: Option<String>,
}
struct Job {
    key: Key,
    provider: Arc<dyn LlmProvider>,
    request: LlmRequest,
}
#[derive(Default)]
struct State {
    chunks: BTreeMap<Key, Chunk>,
    pending: VecDeque<Job>,
    events: VecDeque<TranscriptionEvent>,
    active: bool,
    closing: bool,
    finished: bool,
}
pub struct ProcessingSession {
    id: String,
    pub operation: Mutex<()>,
    state: Mutex<State>,
    wake: Condvar,
    cancellation: CancellationToken,
}
impl ProcessingSession {
    pub fn new(id: String) -> Arc<Self> {
        let session = Arc::new(Self {
            id,
            operation: Mutex::new(()),
            state: Mutex::new(State::default()),
            wake: Condvar::new(),
            cancellation: CancellationToken::new(),
        });
        let worker = session.clone();
        std::thread::spawn(move || worker.run());
        session
    }
    pub fn contains(&self, index: u32, source: ChunkSource) -> bool {
        self.state
            .lock()
            .unwrap()
            .chunks
            .contains_key(&key(index, source))
    }
    fn emit(&self, state: &mut State, key: Key, kind: ProcessingState, revision: u32) {
        let chunk = &state.chunks[&key];
        let event = TranscriptionEvent {
            session_id: self.id.clone(),
            chunk_id: key.0,
            source: chunk.source,
            revision,
            state: kind,
            text: chunk.text.clone(),
            error: chunk.error.clone(),
        };
        if state.events.len() >= 1024 {
            state.events.pop_front();
        }
        state.events.push_back(event);
    }
    pub fn enqueue(
        &self,
        index: u32,
        source: ChunkSource,
        raw: String,
        work: Option<(Arc<dyn LlmProvider>, LlmRequest)>,
        skip: Option<String>,
    ) -> Result<(), CoreError> {
        let mut state = self.state.lock().unwrap();
        if state.closing || self.cancellation.is_cancelled() {
            return Err(CoreError::TranscriptionFailed("Session is closed".into()));
        }
        let key = key(index, source);
        if state.chunks.contains_key(&key) {
            return Err(CoreError::TranscriptionFailed(
                "Duplicate chunk identity".into(),
            ));
        }
        state.chunks.insert(
            key,
            Chunk {
                text: raw.clone(),
                raw,
                source,
                error: None,
            },
        );
        self.emit(&mut state, key, ProcessingState::Recognized, 0);
        if let Some(message) = skip {
            state.chunks.get_mut(&key).unwrap().error = Some(message);
            self.emit(&mut state, key, ProcessingState::Failed, 1);
        } else if let Some((provider, request)) = work {
            if state.pending.len() >= 8 {
                state.chunks.get_mut(&key).unwrap().error =
                    Some("Polishing skipped: queue is full".into());
                self.emit(&mut state, key, ProcessingState::Failed, 1);
            } else {
                state.pending.push_back(Job {
                    key,
                    provider,
                    request,
                });
                self.wake.notify_all();
            }
        } else {
            self.emit(&mut state, key, ProcessingState::Processed, 1);
        }
        Ok(())
    }
    fn run(&self) {
        loop {
            let job = {
                let mut state = self.state.lock().unwrap();
                while state.pending.is_empty()
                    && !state.closing
                    && !self.cancellation.is_cancelled()
                {
                    state = self.wake.wait(state).unwrap();
                }
                if self.cancellation.is_cancelled() || (state.closing && state.pending.is_empty()) {
                    state.finished = true;
                    self.wake.notify_all();
                    return;
                }
                let job = state.pending.pop_front().unwrap();
                state.active = true;
                self.emit(&mut state, job.key, ProcessingState::Processing, 1);
                job
            };
            let result =
                job.provider
                    .process_cancellable(&job.request, &self.cancellation, &|_| {});
            let mut state = self.state.lock().unwrap();
            state.active = false;
            if !self.cancellation.is_cancelled() {
                let chunk = state.chunks.get_mut(&job.key).unwrap();
                let kind = match result {
                    Ok(text) if !text.trim().is_empty() => {
                        chunk.text = text;
                        ProcessingState::Processed
                    }
                    Ok(_) => {
                        chunk.error = Some("Empty processing result".into());
                        ProcessingState::Failed
                    }
                    Err(error) => {
                        chunk.error = Some(error.to_string());
                        ProcessingState::Failed
                    }
                };
                self.emit(&mut state, job.key, kind, 2);
            }
            self.wake.notify_all();
        }
    }
    pub fn events(&self) -> Vec<TranscriptionEvent> {
        self.state.lock().unwrap().events.drain(..).collect()
    }
    pub fn text(&self) -> String {
        self.state
            .lock()
            .unwrap()
            .chunks
            .values()
            .map(|c| c.text.as_str())
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join("\n\n")
    }
    pub fn finish(&self) -> Result<(String, ProcessingSummary, Option<String>), CoreError> {
        let mut state = self.state.lock().unwrap();
        state.closing = true;
        self.wake.notify_all();
        while !state.finished {
            state = self.wake.wait(state).unwrap();
        }
        if self.cancellation.is_cancelled() {
            return Err(CoreError::TranscriptionFailed("Session cancelled".into()));
        }
        let text = state
            .chunks
            .values()
            .map(|c| c.text.as_str())
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join("\n\n");
        let raw = state
            .chunks
            .values()
            .map(|c| c.raw.as_str())
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join("\n\n");
        let errors = state
            .chunks
            .values()
            .filter_map(|c| c.error.as_deref())
            .collect::<Vec<_>>()
            .join("; ");
        state.events.push_back(TranscriptionEvent {
            session_id: self.id.clone(),
            chunk_id: 0,
            source: ChunkSource::Mixed,
            revision: 0,
            state: ProcessingState::Finished,
            text: text.clone(),
            error: None,
        });
        Ok((
            text,
            ProcessingSummary {
                recognized_text: raw,
                status: if errors.is_empty() {
                    "completed"
                } else {
                    "degraded"
                }
                .into(),
            },
            (!errors.is_empty()).then_some(errors),
        ))
    }
    pub fn cancel(&self) {
        self.cancellation.cancel();
        self.state.lock().unwrap().pending.clear();
        self.wake.notify_all();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn orders_by_identity_and_rejects_duplicates() {
        let s = ProcessingSession::new("test".into());
        s.enqueue(1, ChunkSource::Mic, "second".into(), None, None)
            .unwrap();
        s.enqueue(0, ChunkSource::Mic, "first".into(), None, None)
            .unwrap();
        assert!(s
            .enqueue(0, ChunkSource::Mic, "duplicate".into(), None, None)
            .is_err());
        let (text, summary, _) = s.finish().unwrap();
        assert_eq!(text, "first\n\nsecond");
        assert_eq!(text, summary.recognized_text);
        assert!(s
            .enqueue(2, ChunkSource::Mic, "late".into(), None, None)
            .is_err());
    }
    #[test]
    fn cancelled_session_rejects_finish_and_callbacks() {
        let s = ProcessingSession::new("cancel".into());
        s.cancel();
        assert!(s.finish().is_err());
    }
}

#[cfg(test)]
mod worker_tests {
    use super::*;
    use std::{sync::mpsc, time::Duration};
    struct HeldProvider {
        entered: mpsc::Sender<()>,
        release: Arc<(Mutex<bool>, Condvar)>,
    }
    impl LlmProvider for HeldProvider {
        fn name(&self) -> &str {
            "held"
        }
        fn is_available(&self) -> bool {
            true
        }
        fn process(&self, request: &LlmRequest) -> Result<String, CoreError> {
            self.process_cancellable(request, &CancellationToken::new(), &|_| {})
        }
        fn process_cancellable(
            &self,
            request: &LlmRequest,
            cancel: &CancellationToken,
            _: &(dyn Fn(&str) + Send + Sync),
        ) -> Result<String, CoreError> {
            let _ = self.entered.send(());
            let (lock, wake) = &*self.release;
            let mut released = lock.lock().unwrap();
            while !*released {
                if cancel.is_cancelled() {
                    return Err(CoreError::LlmError("cancelled".into()));
                }
                released = wake
                    .wait_timeout(released, Duration::from_millis(10))
                    .unwrap()
                    .0;
            }
            Ok(request.text.to_uppercase())
        }
    }
    fn request(index: u32) -> LlmRequest {
        LlmRequest {
            text: format!("chunk {index}"),
            system_prompt: "polish".into(),
            context: None,
        }
    }
    #[test]
    fn queue_has_one_active_and_eight_waiting_and_preserves_skipped_text() {
        let (tx, rx) = mpsc::channel();
        let release = Arc::new((Mutex::new(false), Condvar::new()));
        let provider: Arc<dyn LlmProvider> = Arc::new(HeldProvider {
            entered: tx,
            release: release.clone(),
        });
        let s = ProcessingSession::new("bounded".into());
        s.enqueue(
            0,
            ChunkSource::Mixed,
            "chunk 0".into(),
            Some((provider.clone(), request(0))),
            None,
        )
        .unwrap();
        rx.recv_timeout(Duration::from_secs(2)).unwrap();
        for index in 1..=9 {
            s.enqueue(
                index,
                ChunkSource::Mixed,
                format!("chunk {index}"),
                Some((provider.clone(), request(index))),
                None,
            )
            .unwrap();
        }
        assert!(s
            .events()
            .iter()
            .any(|e| e.chunk_id == 9 && matches!(e.state, ProcessingState::Failed)));
        assert!(rx.try_recv().is_err(), "only one request can be active");
        *release.0.lock().unwrap() = true;
        release.1.notify_all();
        let (text, summary, error) = s.finish().unwrap();
        assert!(text.starts_with("CHUNK 0"));
        assert!(text.ends_with("chunk 9"));
        assert!(summary.recognized_text.starts_with("chunk 0"));
        assert!(error.is_some());
    }
    #[test]
    fn cancellation_aborts_active_request_and_suppresses_completion() {
        let (tx, rx) = mpsc::channel();
        let release = Arc::new((Mutex::new(false), Condvar::new()));
        let s = ProcessingSession::new("cancel-active".into());
        s.enqueue(
            0,
            ChunkSource::Mic,
            "raw".into(),
            Some((
                Arc::new(HeldProvider {
                    entered: tx,
                    release,
                }),
                request(0),
            )),
            None,
        )
        .unwrap();
        rx.recv_timeout(Duration::from_secs(2)).unwrap();
        s.events();
        s.cancel();
        assert!(s.finish().is_err());
        assert!(!s
            .events()
            .iter()
            .any(|e| matches!(e.state, ProcessingState::Processed)));
    }
    #[test]
    fn over_limit_input_is_kept_in_full() {
        let s = ProcessingSession::new("limit".into());
        let raw = "recognized ".repeat(20000);
        s.enqueue(
            0,
            ChunkSource::Mixed,
            raw.clone(),
            None,
            Some("input limit".into()),
        )
        .unwrap();
        let (text, summary, _) = s.finish().unwrap();
        assert_eq!(text, raw);
        assert_eq!(summary.recognized_text, raw);
    }
}
