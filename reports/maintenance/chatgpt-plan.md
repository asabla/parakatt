# ChatGPT plan integration

The macOS app and file CLI use OpenAI's documented local-client Sign in with ChatGPT flow. This adds an optional text-processing provider. Speech recognition remains local. Existing API-key providers and ordinary CLI transcription retain their behavior.

## Account and request contract

- Initial registration uses `dynamic_agent_client`, the stable installation host ID, and `agent_name_hint=Parakatt`. Returning sign-in uses the saved issued client ID. Account/workspace registrations remain separate even when email addresses match.
- OAuth uses PKCE S256, state, nonce, a loopback callback, and verified OpenAI ID-token signatures and claims. Identity-only grants are retained with plan processing disabled. No client secret or partner API key is used.
- macOS credentials are in Keychain under service `com.parakatt.chatgpt`, account `accounts-v1`. Linux uses owner-only files under the Parakatt config directory. The shared account directory contains the OS lock. Refresh and replacement credentials are serialized across processes.
- The public Responses endpoint receives text input as an array with `stream=true` and `store=false`. This provider omits unsupported generation settings. It does not use ChatGPT private endpoints or credentials from Codex.
- Only a completed, non-empty response can replace recognized text. A plan-limit error pauses the account across processes. A user must select Retry ChatGPT plan in Settings or make a new explicit CLI processing request to retry. There is no provider or billing fallback.
- Provider changes and account epoch changes stop pending processing. Sign-out invalidates the local session before remote revocation. Unconfirmed remote revocation is reported; the user can disconnect Parakatt in ChatGPT settings.

## Validation

Local results and commands are kept under `target/chatgpt-*`; generated build and test artifacts are not release evidence for a different machine.

- Rust workspace: 263 tests passed, 3 ignored. Coverage includes mock OAuth/JWKS, token rotation across processes, text requests, streamed usage-limit errors, interrupted output, active/queued transcript preservation, CLI JSON/text output, and profile reference persistence. A separate delayed-callback test passed after correcting accepted-socket blocking mode on macOS.
- Rust Clippy with all targets and features; Swift source lint; dependency license/source checks and advisory audit.
- macOS build and 14 account coordinator, settings, and credential migration tests passed with isolated account fixtures. These tests do not connect to a real ChatGPT account.
- Linux ARM64 in an isolated Debian Trixie container: 20 account tests, 14 CLI tests, Clippy, and the CLI build passed. The CLI help/status commands returned success without loading a model. The existing `help_and_version_need_no_model_or_state` test failed because the native ONNX Runtime prints an Unknown CPU vendor warning to stderr in this VM; that failure is retained in `target/chatgpt-linux/cli-all.log`. The other CLI tests were then run with only that case excluded.
- The Debian Bookworm image could not link the pinned ONNX Runtime because its C++ runtime is too old. The hosted Ubuntu 24.04 workflow has not been run for these changes.

### PR preparation (2026-11-11)

- Re-ran `cargo test --locked --workspace` and `cargo test --locked --workspace --all-features`: each passed 263 tests, with 3 ignored.
- Re-ran `make quality`: formatting, all-target/all-feature Clippy, Swift lint, Python lint/format, workflow lint, and both dependency license/source checks passed.
- Re-ran the critical Rust module coverage comparison against `origin/main`: all six modules stayed at or above baseline.
- Ran all Python maintenance tests: 44 passed.
- Rebuilt the Rust/Swift bindings and Xcode project, then ran the full macOS Swift suite: 86 tests executed, 1 skipped, no failures. Playback tests used the headless fixture setting.
- Rebuilt again after the stream-error fix and repeated the full Swift suite with coverage: 86 executed, 1 skipped, no failures. All four protected settings functions reached the required 100% coverage. The skipped case is the opt-in Instruments workload.
- Swift declaration/import analysis passed with no violations across 82 files.
- Bounded input-contract fuzzing completed 2,000 runs without a crash. Fuzz formatting and locked dependency metadata checks also passed.
- `cargo audit` reported no vulnerabilities and unmaintained-package warnings for `basic-toml` and `paste`.
- Built the release CLI and passed English/Swedish CPU recognition with pinned public FLEURS fixtures, matching text/JSON output, sentence timelines, and unchanged isolated application state (`target/chatgpt-pr-cli-smoke.json`).
- Fixed top-level Responses `error` event handling so usage-limit codes and parameters are preserved; the regression checks account pausing, transcript preservation, and explicit retry for HTTP errors, `response.failed`, and `error` events.
- These automated checks did not sign in to a real ChatGPT account or send text to OpenAI. Hosted CI, sanitizer/mutation jobs, real-account acceptance, and minimum-OS/release packaging checks remain separate validation.

### macOS settings design follow-up

- Replaced the flat account form with Account, Model, and Processing groups matching the provider cards. Secondary account actions are in a menu; sign-in and usage recovery actions appear only when relevant.
- Account labels omit internal registration IDs while distinguishing registrations with the same email. Connection results use a compact status with technical details behind a disclosure.
- Retry refreshes the saved account state as well as the model catalog, so a cleared usage pause is reflected in the interface.
- Added presentation/identity-label, retry-state, and real SwiftUI layout tests using isolated account fixtures. The Swift suite passes 93 tests executed with one opt-in Instruments workload skipped. Light/dark snapshots cover connected, multiple-account, paused, consent-required, and signed-out states under `target/chatgpt-design-snapshots`.

### Optional Dictation punctuation follow-up

- Added **Fix punctuation with AI** under Settings > LLM > Dictation, shared by every provider and disabled by default. No provider is enabled automatically; normal CLI transcription remains unchanged.
- Recordings capture the setting at their start, including push-to-talk sessions created after capture. Profiles persist it; legacy configuration and import jobs default to disabled.
- Dictation uses a fixed punctuation-only prompt without application selection or domain-vocabulary rewrite hints. A conservative output policy checks ordered words, line boundaries, numeric punctuation, and protected symbols/identifiers before accepting any result. It may skip valid cosmetic edits rather than risk changing content.
- Live/meeting queues, imported media, and history retries all enforce the guard. Rejected results retain the pre-LLM text (including dictionary corrections); original recognition and timestamps remain separate.
- Validation: 271 Rust tests passed with 3 ignored; 93 Swift tests executed with 1 opt-in workload skipped and no failures. Source/dependency quality checks and both Rust/Swift coverage gates passed. Tests cover opt-in/session snapshots, save failures, profiles, Unicode, word/number/formatting changes, dictionary fallback, import timestamps, and history retry.
- No transcript was sent to a real ChatGPT account during this validation. A real-Luna punctuation smoke test remains manual acceptance.
- Rebuilt the final Rust/Swift package and repeated the full Swift suite successfully. Swift declaration/import analysis reported zero violations across 84 files.

### Unified provider and processing settings (current design)

- Replaced provider cards with a native dropdown, including None. Every provider shares Connection, Model, Test connection, Apply, and compact diagnostics. Connection controls adapt to local servers, API keys, or ChatGPT sign-in; unsupported generation controls stay hidden.
- Replaced the separate Dictation punctuation and preceding-context switches with one canonical mode selection: Off (`dictation`), Punctuation (`punctuation`), and Grammar + punctuation (`clean`). Settings, General, menu-bar choices, and imports use the same names. Email, Code, and custom modes remain alternatives, not extra passes.
- Enabled processing automatically receives bounded context from earlier chunks of the same speaker/source and recording. Off and None never start an AI processing request. The punctuation acceptance guard remains active for the dedicated mode.
- Legacy opted-in Dictation and per-app references migrate to Punctuation; plain Dictation, Clean, specialized selections, and provider credentials retain their behavior. A versioned migration preserves pre-existing custom modes called “punctuation” under a distinct custom name without losing their prompts or references. Merely loading configuration does not rewrite the source file.
- Provider switching disables the runtime provider until Apply succeeds; None keeps saved connection/model/key references. The UI reports the applied model rather than calling a selected-but-unapplied provider active.
- HTTP provider invalidation now cancels active and queued cleanup for Ollama, LM Studio, OpenAI API, and Anthropic too, rather than only ChatGPT. A local-server regression verifies that switching/disabling does not start the next queued request and keeps recognized text.
- Validation includes 275 passing Rust tests (3 ignored), 96 Swift tests executed (1 opt-in workload skipped), six critical Rust coverage comparisons, and full coverage of protected Swift settings functions. Isolated UI snapshots cover every provider/None and ChatGPT account/recovery states in light and dark mode under `target/llm-settings-unified-snapshots`.
- No real ChatGPT inference or account credentials were used by the new tests. Relaunch the rebuilt app to see this design; select and apply the provider/model, then choose the desired Text cleanup mode before starting a new recording.
- Final rebuilt-package validation repeated all 96 Swift tests successfully (1 skipped); declaration/import analysis found zero violations across 86 files. `make quality`, all-feature Rust tests, and the Rust baseline coverage comparison also passed after the provider-cancellation fix.

## Before release

Do not treat mock-server checks as real-account qualification. Record the result of each remaining acceptance check:

- Real OpenAI sign-in and consent, account model catalog, and a completed request charged to the selected ChatGPT plan.
- Returning sign-in, restart, refresh-token renewal, separate workspaces, and revoked access with real accounts.
- Access to the shared macOS Keychain entry from the signed app and CLI, including any Keychain access prompt.
- First-use confirmation, usage settings link, sign-out, and shared app/CLI account behavior in the desktop interface.
- Linux browser sign-in and a real text-processing request, plus the hosted Ubuntu 24.04 CLI workflow.
- Minimum supported macOS runtime and release packaging checks.

The current distribution is a local MIT-licensed app and CLI. Review eligibility separately before offering paid or remotely hosted distribution.

## Official contract references

- [Registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [Accounts and sessions](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)
- [Models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
- [Request limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
- [Errors and recovery](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery)
- [UI requirements](https://developers.openai.com/siwc/ui-ux-guidelines)
