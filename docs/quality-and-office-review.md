# Quality and office-work review

Implementation has started; see [current capabilities and integration setup](transcript-imports.md). Scope is confirmed as Teams meetings and Slack Huddles, with limited, explained administrator-approved work-account access. The audit below records the pre-implementation baseline.

Reviewed 2026-11-10 against the current workspace, including the uncommitted Linux prototype. This is an audit and proposed implementation sequence, not a claim that the changes below are implemented. The macOS references have since been supplied; the Linux alignment is documented in [the UX review](linux-ux.md). No account was connected and no meeting data was accessed.

## Evidence and scope

Inspected Rust/Swift/Python sources, build configuration, CI workflows, coverage policy, and the existing improvement backlog. Checked current official Teams and Slack documentation. Ran the current Linux Ruff checks and all 11 platform/backend unit tests: both pass. Ran isolated Pyright 1.1.414 in strict mode over the four handwritten Linux application modules: 1,033 diagnostics, predominantly unknown/missing types. These are not 1,033 confirmed runtime defects; dynamic imports and Qt/FFI boundaries need explicit contracts before the count becomes a useful gate. Generated binding definitions were available but excluded as diagnostic targets.

An exploratory Ruff pass adding ANN, I, SIM, and RUF reports 234 findings across Linux sources/tests; most are missing annotations. This is a proposed ruleset assessment, not a production gate. The Pyright report and temporary configuration are in `target/quality-review/`. Audit tooling was installed separately under `target/audit-tools`.

Swift builds, macOS sanitizers, and live Teams/Slack integration were not executed in this Linux workspace. Existing CI configuration is evidence of intended checks, not evidence that remote checks currently pass. This is a targeted first review, not an exhaustive security audit.

## Concrete findings

| Priority | Finding | Evidence and consequence | Proposed acceptance check |
| --- | --- | --- | --- |
| High | Worker completion depends on successful cleanup | `linux/parakatt_linux/backend.py:610`: when saving the paused import state raises, `finished.set()` and `import_done` are skipped. Reproduced with an injected storage failure: completion flag false, completion event absent. The UI clears its active importer only on that event. Recording cleanup has similar unguarded finalization calls requiring review. | Disk-full, database failure, cancellation, and subprocess failure must always terminate the worker and deliver exactly one completion event. Preserve the primary error and any recoverable transcript. |
| High | Python data and event boundaries are untyped | Strict Pyright reports widespread unknown types; `Events.event` at `app.py:63` also conflicts with inherited `QObject.event`. This overrides a Qt method name and is flagged by Pyright; no Qt event-dispatch failure was reproduced. | Typed native adapter, typed preferences, enums/dataclasses for worker messages, validated optional widget access, and a signal name that does not shadow QObject methods. |
| Medium | Corrupt Linux settings prevent startup | `backend.py:145`: invalid `linux.json` produces an uncaught `JSONDecodeError`. Reproduced using a temporary isolated application directory. | Preserve the corrupt file, report the issue, and start with validated safe defaults. Reject unsupported versions/types and test interrupted writes. |
| Medium | Model verification can block the UI | `app.py:1200` calls `list_models()` synchronously; Rust's `models.rs:102` verifies every file on a cache miss. This can hash gigabytes before returning. Static call-path finding; this review did not measure a freeze. | Verify off the GUI thread, show loading status, cache results appropriately, and test GUI responsiveness during a cold-cache check. |
| Medium | Python dependency/tool coverage is incomplete | Python has no type-check gate or dependency vulnerability gate. Top-level application dependencies are pinned but transitive dependencies and the build environment are not fully locked. | Lock supported dependency sets, pin development tools, audit production dependencies, and test an installed wheel in an isolated environment. |
| Medium | Strong test gates cover selected contracts | Rust coverage policy protects six modules from regression; Swift policy specifies four functions. Mutation checks are similarly selected. Linux device capture is replaced by an injected source in its native recording test. | Extend contract coverage to capture lifecycle, transcript parsers, speaker mappings, exports, migrations, and failure recovery. Use a virtual audio server in CI and retain a real-device release checklist. |

## What is already strict

- Rust: pinned toolchain and lockfile, rustfmt, Clippy with warnings denied in CI, explicit unsafe/production panic-related restrictions, dependency audits, license/source policy, fuzzing, mutation tests, and selected coverage regression gates.
- Swift: Swift 6, complete strict concurrency, compiler warnings as errors, selected SwiftLint correctness rules and analyzer rules, plus address/thread sanitizer jobs.
- Python: pinned Ruff version, formatting/lint checks, unit tests, and Linux integration tests. These currently provide much weaker static assurances than Rust/Swift.

Keep these checks. Avoid spending time re-adding tools already configured, or claiming that all lints improve correctness equally.

## Proposed strictness policy

1. **Python types first.** Add strict Pyright as a pinned CI tool, beginning with fully typed preferences, import parsing, and the native adapter, then capture/workers and UI. Expand the enforced scope as each module is fixed. Do not hide the existing unknown-type debt behind broad ignores or `Any` casts. Exclude generated code from diagnostics while retaining its type information.
2. **Curated Ruff expansion.** Add import sorting, comprehensions, suspicious constructs, annotation rules, and selected security rules. Use narrow, justified exceptions for normal subprocess usage and test fixtures. Align the Python 3.12 runtime requirement with lint/type-check settings. Do not activate every style/security rule indiscriminately.
3. **Swift consistency.** Add a pinned formatter with a check-only CI mode and expand correctness-focused SwiftLint rules beyond the current eight-rule allowlist. Preserve Swift 6 concurrency enforcement. Confirm any formatter configuration against existing macOS code before introducing a whole-repository formatting diff.
4. **Rust contracts.** Extend warnings-as-errors to applicable workspace build/check jobs. Review selected pedantic Clippy rules individually. Represent internal import states/source kinds as enums and validated types, retaining compatible FFI representations. Exercise default and optional feature configurations. Extend fuzz/property tests for new transcript parsers, invalid timestamps, speaker references, and UTF-8 boundaries.
5. **Supply chain.** Add audited Python dependency locks, automated dependency update proposals, workflow action SHA pinning, and commit hooks using the same versions as CI. Scan for accidental credentials. Keep updates reviewable and make required CI checks branch-protected where repository administration permits.
6. **Operational reliability.** Give capture/import workers explicit state transitions and cancellation semantics. Guarantee completion even when persistence fails. Bound subprocess output and shutdown time; test mid-download cancellation, missing devices, disk-full, database contention, and process crashes. Split the 1,415-line Linux UI from application controllers; split large Rust orchestration modules incrementally around clear contracts.

Enable gates only when their scoped baseline passes. Exceptions should identify a reason and location, not suppress whole categories. Measure changed-code/failure-path coverage rather than chasing a single whole-project percentage.

## Speaker attribution

The existing system is source-labelled, not person-labelled. `crates/parakatt-core/src/session.rs:408` maps microphone audio to **Me** and all system audio to one **Speaker 1** placeholder. `TimestampedSegment` stores an optional speaker string, but no stable participant identity or attribution provenance.

Three separate capabilities are required:

1. **Attendance:** who joined the meeting. Invitations are not proof of attendance.
2. **Diarization:** which speech intervals belong to distinct voices, including overlap and uncertainty.
3. **Attribution:** a supported association between an interval and a named participant.

A roster cannot reliably assign names to mixed system audio. A room device may represent several people; a microphone is not always only the local user. Keep unknown speakers unknown and allow per-meeting correction. Do not let an LLM invent names or infer owners from a participant list alone.

### Teams

Microsoft Graph provides transcript metadata/content. Its WebVTT format can contain timestamped speaker tags. Work-account permissions and tenant settings govern access, including whether speaker attribution is available. Treat access-denied and speaker-attribution-disabled as distinct outcomes. Preserve source attribution where supplied; do not replace it with guessed identities. See [Get callTranscript](https://learn.microsoft.com/en-us/graph/api/calltranscript-get?view=graph-rest-1.0).

For real-time platform speaker metadata, Microsoft's application-hosted media bots expose active/dominant speakers but require a Teams bot plus .NET/Windows Server infrastructure. That is a separate service architecture, not a small local desktop enhancement. Do not use screen-scraped Teams speaker indicators as a reliable identity feed. See [real-time media concepts](https://learn.microsoft.com/en-us/microsoftteams/platform/bots/calls-and-meetings/real-time-media-concepts).

Recommended first delivery: import attributed Teams transcripts after meetings. Investigate local diarization separately, with human-confirmed names, and measure it on English/Swedish office recordings before offering it as reliable.

### Slack

Slack's documented file object includes Huddle participant IDs, a transcript-file reference, and a `huddle_transcription` structure. This is a promising integration path, not proof that every app/token receives the transcript body or a guaranteed per-speaker schema. Verify retrieval using permitted sample data. See [Slack file object](https://docs.slack.dev/reference/objects/file-object/).

Slack AI Huddle notes can include an embedded transcript if administrators permit it. Availability depends on workspace settings and plan; notes and a verbatim transcript must remain different content types. See [Slack Huddle notes](https://slack.com/help/articles/31377193680019-Use-AI-to-take-huddle-notes-in-Slack).

## Transcript imports

The existing importer transcribes audio/video. It is not a general text-transcript importer. Add a shared Rust ingestion service so macOS and Linux follow the same rules and importing an existing transcript does not require a speech model.

Proposed shared representation:

- Source provider and source meeting/transcript IDs; source timestamps and import time.
- Meeting title and participants with provider IDs scoped to their tenant/workspace.
- Ordered utterances with optional start/end times, text, stable speaker reference, and attribution origin (provider, user correction, or diarization).
- Original imported content/version separate from user edits, processed summaries, and speaker-name corrections.
- Content kind: verbatim transcript, notes/summary, or chat. Never present these interchangeably.

First formats: Teams WebVTT, then actual Slack Huddle payloads or user-provided exports verified against samples. Support untimed/unnamed text honestly without manufacturing timestamps or names. Treat DOCX and archive-based formats as additional parsers with explicit size/decompression limits if real exports require them.

Required behavior: preview before import; preserve speaker tags and timestamps; validate encoding, sizes, timing and references; escape markup; avoid duplicate imports using provider IDs plus content revision/hash; commit transactionally; retain original provenance; round-trip speaker labels through exports; never execute imported content or treat instructions inside it as application commands.

Connected import comes after file-based ingestion. Use limited read permissions, secure token storage, pagination and rate-limit handling, retry without duplicates, and explicit account/workspace selection. Do not require tenant-wide access when a narrower supported scope meets the use case. Never post meeting content to Teams/Slack automatically.

## Office usefulness: proposed priorities

1. **Meeting record:** title, date, attendees, project/customer tags, and participant/source-aware search across local and imported transcripts.
2. **Useful follow-up:** editable decisions, action items, owners, and due dates, each linked to its supporting transcript passage. Missing owners/dates stay unset. Extract only with a configured local or explicitly selected cloud provider.
3. **Recurring meetings:** carry forward confirmed open actions and prepare an agenda from earlier notes. Keep items traceable to the meeting where they originated.
4. **Reusable office outputs:** meeting minutes, handover, stand-up, interview, and follow-up email templates building on the existing processing modes. Preview/copy/export first; no automatic messaging.
5. **Review and correction:** quick speaker renaming, uncertain-speaker review, bookmarks, and correcting text without losing the original source. Prioritize reliable search and correction before conversational Q&A over the archive.

These are product proposals, not assumed requirements. Their layout should follow the existing macOS app once reference screens are available.

## Delivery sequence and acceptance

| Slice | Deliverable | Done when |
| --- | --- | --- |
| 1. Reliability baseline | Worker cleanup fixes, corrupt-settings recovery, typed boundary modules, stricter scoped CI | Failure injection always completes; saved content survives; applicable checks pass with no broad new suppressions |
| 2. Transcript foundation | Shared schema and transactional Teams VTT ingestion | Named/timed sample imports without loading a speech model; malformed input is rejected; reimport does not duplicate records |
| 3. Speaker review | Stable participant references and reversible display-name corrections | Original attribution survives editing/export; unknown speakers remain unknown |
| 4. Teams connector | Limited authorized transcript retrieval | Test account permissions and tenant restrictions are understood; named and unnamed formats handled; retries/pagination tested |
| 5. Slack connector | Huddle transcript retrieval after a capability/sample spike | Authorized payload and speaker semantics verified; notes/transcript distinction maintained; unavailable access fails clearly |
| 6. Office follow-up | Source-linked minutes/actions and recurring-meeting workflow | User can verify/edit every proposed decision, owner, and due date before export |
| Later research | Live attribution and local diarization | A representative evaluation demonstrates acceptable speaker error and overlap handling; infrastructure and permissions accepted |

No dates are estimated before integration access and sample formats are established. Open questions: whether Slack means Huddles, chat history, or both; whether work-account integrations/admin-approved permissions are acceptable; and whether final named transcripts are sufficient or attribution must be live.
