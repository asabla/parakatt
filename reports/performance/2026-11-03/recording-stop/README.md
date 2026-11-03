# App Stop-to-final-state replay

The preview scheduling fix removes avoidable optional work ahead of required
transcription. On this Mac, the Swedish CPU case with preloaded incremental
work and preview fell from 1.325 s to 0.991 s median (25.22%). The other CPU
conditions were effectively unchanged. Automatic WebGPU conditions measured
about 0.70–0.73 s after the fix. These are five-trial diagnostic measurements,
not a general latency or accuracy qualification.

## Conditions and observations

All runs used Apple M3 Max, macOS 27.0.1 build `26A434`, the verified production
Parakeet v3 model, four CPU threads, and the same native WebGPU library.
Baseline source is `7ef96fa`; the first fixed run is `9169d9b`; the repeated
fixed run with a backend check after every trial is `d2b7205`. Every run used
a clean checkout. Their launcher, dependency lock, model manifest, native
runtime, and normalized fixture hashes match. The framework hashes differ
with the source changes. See the three `*-provenance.json` receipts.

Each run retained 60 CPU and 60 automatic-WebGPU observations. Each language
used three shapes, preview off/on, a warmup per condition, and five retained
trials. All 120 baseline/repeated-fix pairs have identical final text hashes.
The first fixed run also matches all 120 baseline text hashes and is retained
as supplementary evidence. All preview off/on and repeat results within each
run matched text. This does not replace corpus accuracy acceptance.

Median Stop-to-final-state time in milliseconds:

| Fixture/path | CPU alone before / after | CPU preview before / after | WebGPU alone before / after | WebGPU preview before / after |
| --- | ---: | ---: | ---: | ---: |
| English 3 s, single-shot | 791.8 / 786.6 | 788.5 / 791.6 | 701.5 / 704.9 | 702.9 / 704.4 |
| English 8 s, incremental tail | 1016.4 / 1016.3 | 1015.6 / 1017.3 | 734.1 / 724.7 | 722.9 / 727.6 |
| English 20 s, queued incremental | 989.4 / 990.9 | 990.0 / 989.6 | 729.6 / 722.4 | 731.3 / 724.1 |
| Swedish 3 s, single-shot | 790.8 / 791.6 | 789.5 / 790.7 | 706.5 / 705.4 | 701.1 / 699.0 |
| Swedish 8 s, incremental tail | 1011.1 / 1013.5 | 1012.3 / 1014.0 | 735.1 / 730.3 | 729.6 / 729.1 |
| Swedish 20 s, queued incremental | 990.4 / 990.3 | 1324.8 / 990.7 | 727.9 / 733.0 | 732.2 / 729.6 |

[Every comparison](comparison.json), all six observation reports, and all
three provenance receipts are retained here. Baseline and first-fix runs
checked the backend at model load. Their warn-level Rust logs contain no
persistent CPU-fallback warning; the log hashes are retained in the comparison.
The repeated fix additionally checks the actual backend after every trial,
including warmups, and fails if it changes. No fallback occurred in that run.
Raw logs and immutable measured apps remain in ignored
`target/recording-latency`.

## What the measurement includes

The opt-in app entry loads public audio into the app's buffer, then calls the
normal `AppState.stopRecording()`. It includes the unchanged 600 ms capture
drain, serial queue wait, Rust inference and processing, history save, and
publication of final app state. State is sampled on the main actor at 1 ms
intervals. It does not open capture devices, paste text, use an LLM, or measure
the compositor. The synchronous Stop handler returned within 0.102 ms in the
repeated fixed run; this is not physical button-to-display latency.

The 3 s case deliberately selects the single-shot path. The 8 s case leaves
one incremental tail. The 20 s case starts with a full preloaded buffer and
dispatches a 12 s chunk before Stop, leaving an 8 s tail. It is a queued-work
stress case, not a real-time 20 s recording. Preview gets a 10 ms head start;
the reports retain whether a request was still in flight at Stop. Skipping
optional work when a required chunk is already reserved is part of the fix.

The model and input shapes are warm. Baseline and fixed phases ran sequentially,
without task builds or other task benchmarks. Ordinary applications and the
existing virtualization workload were not controlled. No OS or GPU cache was
cleared. Small differences do not establish a statistically significant change.
The 78% inference reduction in the parent report does not describe app
Stop-to-final time, which includes the capture drain.

## Implementation and regression evidence

Swift skips buffered preview when required work is reserved and ends its
session immediately at Stop. Rust uses a nonblocking model lock for optional
preview and checks a per-session cancellation token before inference and
before publishing its result. Finish, cancel, and reset invalidate the token;
reusing an ID cannot accept an old result. Swift also checks recording and
session identity. A busy-model response allows the same audio to be retried.
An already running native inference call is not preempted.

The ended-session test failed against the baseline: recognition ran once
instead of zero times. It passes after the fix. Further deterministic Rust
tests hold the model lock and block inference to check busy, finish, cancel,
reset, and reused-ID behavior. Swift tests check same-audio retry and immediate
Stop with late completion. The full Rust suite passed 199 tests; Swift executed
54 tests with one opt-in test skipped and no failures. Rust formatting and
strict all-target/all-feature Clippy passed.

## Reproduction and attribution

Use `scripts/measure-recording-latency.py` as described in
[the benchmark instructions](../../../../benchmarks/README.md). Use a saved app
built from the recorded clean source commit and preserve the normal stable
launcher replacement. Run CPU and automatic configurations sequentially.

The six derived inputs repeat or trim the first English and Swedish files in
the pinned FLEURS manifest and convert them to mono 16 kHz little-endian float
samples with bundled FFmpeg. [Fixture metadata](fixtures.json) records the
original and derived hashes without machine paths. Dataset revision is
`70bb2e84b976b7e960aa89f1c648e09c59f894dd`. Attribution: Conneau et al.,
*FLEURS: Few-shot Learning Evaluation of Universal Representations of Speech*
(2022), Google, CC BY 4.0. See [the fixture notice](../../../maintenance/fixtures.md).
No audio, model weights, private history, or credentials are committed.
