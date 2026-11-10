# Transcript imports, meeting follow-up, and quality gates

This implementation adds shared Rust ingestion and persistence for Teams meeting transcripts and Slack Huddle transcripts. Chat/channel history is outside scope. Existing transcripts are imported without loading a speech model or sending text to an LLM. Speaker labels come from the source or explicit user corrections; the app does not identify voices or infer names from an attendee list.

## What is available

- **macOS:** `Import Transcript…` in the existing menu opens a Teams `.vtt` or structured Slack Huddle `.json` file. It imports through the same Rust engine and opens history. This hook needs a macOS CI build/runtime check; it was not executable in the Linux workspace.
- **Linux:** `Import transcript…` in Imports. History's More menu exposes speaker corrections and confirmed meeting actions. Markdown export includes source-attributed utterances, confirmed actions, supporting quotes, and saved edited notes.
- **Connector CLI:** `parakatt-import` supports file import, read-only Teams/Slack retrieval, reversible speaker corrections, explicit action items, and Markdown export. The connector commands are currently part of the Linux preview; macOS connected-account UI is not implemented.
- **Shared engine:** bounded parsing, transactional insertion, original-content retention, duplicate detection, speaker aliases, and source-linked action storage. Backups retain this metadata.

UI styling work remains paused until macOS references are available. These changes add functional entry points to the existing interfaces rather than introducing another visual design.

## Installation and local use

```sh
make linux-desktop
target/linux-venv/bin/parakatt-import --data-dir ./office-data \
  file --provider teams --title "Weekly review" meeting.vtt
target/linux-venv/bin/parakatt-import --data-dir ./office-data \
  file --provider slack huddle.json
```

Omit `--data-dir` to use the same default data/config directory as the desktop. Import commands return JSON containing the history record ID, whether a new record was created, and the utterance count. Reimporting the same source/content preserves the existing record and edits. Changed source content creates a separate revision record. Original timestamps/labels/content remain retrievable from the engine.

The source file limit is 8 MiB, with at most 20,000 nonempty utterances. Timestamp pairs must be finite and increasing within each utterance; overlaps between speakers are allowed. Untimed Slack lines remain untimed and are not fabricated as subtitle cues. Notes summaries are rejected as transcripts. Existing audio/video import remains a separate path.

Teams WebVTT supports optional cue IDs, voice tags, cue settings, multiline text, and NOTE/STYLE/REGION blocks. Multiple voice tags in a single cue are explicitly rejected rather than assigned to the wrong person. Speaker tags are source labels, not independently verified human identities.

Slack ingestion currently accepts a file-object response, an object containing `huddle_transcription`, or the transcription object itself. Each `lines` entry must have string `text` or `contents`, optional string `user_id`/`speaker`, and either both numeric `start_time_ms`/`end_time_ms` or neither. Example **synthetic fixture**, not a captured production payload:

```json
{"huddle_transcription":{"lines":[{"user_id":"U123","contents":"Review the contract.","start_time_ms":0,"end_time_ms":2000}]}}
```

Unknown rich-block/line variants fail explicitly. The adapter has not been verified against an authorized transcript from your Slack workspace; that sample is still needed to establish exact format compatibility. It does not scrape Slack's UI or silently substitute AI notes.

## Teams sign-in and permissions

A Microsoft Entra app registration is required; no registration or administrator grant has been created automatically. Ask the administrator to register a public-client desktop application, enable the device authorization/public-client flow, and approve the delegated Microsoft Graph permission **OnlineMeetingTranscript.Read.All**. The connector requests only that Graph scope; MSAL manages the standard sign-in/cache scopes. Tenant policy can prohibit device authorization, transcript access, or speaker attribution independently.

This is a delegated work-account flow, not application-wide background access with a client secret. It does not request mail, chat history, calendar writes, meeting creation, or message sending. Microsoft determines which meetings the signed-in account may access. Tenant approval requirements and the scope's breadth should be reviewed before installation.

```sh
target/linux-venv/bin/parakatt-import teams \
  --client-id YOUR_PUBLIC_CLIENT_ID --tenant YOUR_TENANT_ID \
  --meeting-id YOUR_GRAPH_MEETING_ID --transcript-id YOUR_TRANSCRIPT_ID \
  --title "Weekly review"
```

Follow the sign-in instructions shown in the terminal. The token cache is stored in Secret Service / GNOME Keyring, with no plaintext fallback. No client secret is accepted. Use the account that is authorized for the source; a cache containing multiple accounts is rejected rather than selecting one silently. The account/tenant-specific keyring entry can be removed to switch accounts.

The current connector imports **one explicitly selected transcript**. It does not discover meetings through calendars or scrape Teams join URLs. Graph meeting IDs and transcript IDs must be supplied; `--user-id` can select the source organizer/user route where needed. A meeting join code/URL is not interchangeable with a Graph meeting ID. Automatic meeting discovery is a later feature requiring a separate permission/design decision.

Access-token injection through `PARAKATT_TEAMS_ACCESS_TOKEN` is available for a controlled integration runner. Never put tokens in command-line arguments, repository files, screenshots, or chat. Tenant transcript and speaker-attribution restrictions return actionable errors; the app does not manufacture missing names or work around the policy.

## Slack access

Install a Slack app in the intended workspace with **files:read**, subject to workspace approval and channel/file visibility. Obtain its appropriately scoped token through your administrator's approved installation process. Store it without echoing it:

```sh
target/linux-venv/bin/parakatt-import set-slack-token --workspace YOUR_WORKSPACE_ID
target/linux-venv/bin/parakatt-import slack --workspace YOUR_WORKSPACE_ID \
  --file-id YOUR_HUDDLE_FILE_OR_CANVAS_ID --title "Project Huddle"
```

This retrieves `files.info`, reads an accessible Huddle transcription, or follows its documented transcript-file reference once. It does not follow arbitrary download URLs with a Slack token, collect chat history, or send messages. Slack's available fields and workspace plan/admin settings determine whether a transcript is accessible. A summary-only canvas produces a clear error.

By default stable user IDs remain speaker labels. Optional `--resolve-names` requests name resolution through `users.info` and therefore needs **users:read** in addition to files access. Only user IDs and display names are retained from lookup responses; email/profile payloads are not stored. Manual speaker correction works without that optional scope. `PARAKATT_SLACK_ACCESS_TOKEN` supports controlled runners; ordinary desktop use should use the keyring.

Slack installation/token provisioning is currently manual, not a browser OAuth wizard. Live access and end-to-end speaker mapping still need testing with your authorized workspace.

## Speaker corrections and office follow-up

Use a provider-supplied speaker label/user ID as the original value:

```sh
target/linux-venv/bin/parakatt-import speaker --record-id RECORD_ID \
  --original U123 --name "Alex"
target/linux-venv/bin/parakatt-import action --record-id RECORD_ID \
  --text "Review the contract" --owner "Alex" --due-date 2026-11-20 \
  --source-utterance 0
target/linux-venv/bin/parakatt-import complete-action --record-id RECORD_ID \
  --action-id ACTION_ID
target/linux-venv/bin/parakatt-import export --record-id RECORD_ID --output minutes.md
```

Speaker corrections are scoped to one transcript and leave original attribution intact. An empty display name restores the original. Owner and due date are optional explicit inputs; missing information remains unset. The zero-based source utterance must exist, and the app stores an immutable supporting quote. Completed/open action state and quotes survive database backup/restore. Imported transcripts and completed local recordings with timestamped segments can support actions in the Linux desktop; the CLI's current transcript export path targets imported records.

This is a manual, verifiable follow-up workflow. Automatic action/decision extraction, recurring-meeting agendas, calendar integration, live named attribution, and local diarization are not included. No meeting content is automatically posted or emailed.

## Quality and reliability

- Import and recording workers deliver completion even when cleanup/persistence fails; failure-injection tests cover the regressions.
- Invalid Linux settings are preserved in an `invalid-*` backup and safe defaults are loaded. Writes are validated and replaced atomically using private temporary files.
- The worker signal no longer shadows `QObject.event`. Native bindings are imported directly so type tools can inspect their definitions.
- Model enumeration/verification runs off the Linux GUI thread. Settings consume the resulting model catalog.
- Ruff now checks import ordering, comprehensions, simplifications, async patterns, stale suppressions, and selected unsafe operations in addition to existing correctness checks.
- Strict Pyright is enforced on preferences, provider transport, and minutes rendering. The rest of the older prototype still needs a staged typing pass; this is not a claim that the whole UI is strict-clean. No broad type-check suppressions were added to obtain a passing baseline.
- Runtime dependencies have a complete hashed lockfile, and CI audits that set for published vulnerabilities. The selected MSAL release supports patched cryptography. The wheel build backend is pinned. Quality tools use a separate CI venv so they do not silently change application dependencies.
- Dependency update proposals and optional commit hooks are configured. Runtime dependencies still need their lock regenerated and audit rerun when versions change; updates are not auto-merged.
- The existing input fuzz harness now exercises both transcript parsers and checks accepted timestamp contracts.

```sh
python3 -m venv target/quality-venv
target/quality-venv/bin/python -m pip install -r requirements-quality.txt
target/quality-venv/bin/ruff check linux
target/quality-venv/bin/ruff format --check linux
target/quality-venv/bin/pyright --project linux/pyrightconfig.json
target/quality-venv/bin/pip-audit --strict --require-hashes --disable-pip -r linux/requirements.lock
target/quality-venv/bin/pre-commit install
make linux-test
```

Regenerate runtime pins with `uv pip compile --python-version 3.12 --generate-hashes linux/pyproject.toml -o linux/requirements.lock`, then install with `--require-hashes`, audit, and test. Existing Rust/macOS quality gates remain enabled; this change does not claim that every proposed formatter/lint or every module has been migrated to a stricter baseline.

Provider request tests use injected responses. Authentication tests mock the MSAL/keyring boundary; no real account was signed in. Swift import hooks and real tenant/workspace retrieval must be validated on the intended machines/accounts before release.
