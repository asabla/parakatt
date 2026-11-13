# Contributing to Parakatt

## Getting Started

1. Fork and clone the repository
2. Install prerequisites: Rust toolchain, Xcode 16+, `xcodegen` (brew), `cargo-swift` (cargo install)
3. Run `make all` for a full build

See `CLAUDE.md` for detailed build commands and architecture overview.

## Development Workflow

1. Create a branch from `main`
2. Make your changes with tests where applicable
3. Run `cargo test` before committing
4. Open a pull request against `main`

## Code Style

### Rust
- Follow standard Rust conventions (enforced by `cargo fmt` and `cargo clippy`)
- Use `map_err()` on Mutex locks, never `.unwrap()`
- Follow the documented lock ordering in `engine.rs`
- Errors should use `CoreError` variants with descriptive messages

### Swift
- Follow standard Swift conventions
- Use `[weak self]` in closures that capture `self`
- Update `@Published` properties on the main thread
- Prefix log messages with `[Parakatt]` and a category (e.g., `[Parakatt] Engine`, `[Parakatt] Mic`)

## Architecture

- **Rust core** (`crates/parakatt-core/`): All compute-heavy work (STT, LLM, storage)
- **Swift app** (`Parakatt/`): macOS integration (audio capture, UI, accessibility)
- **FFI boundary**: UniFFI proc-macros in Rust, generated Swift package in `ParakattCore/`

Changes to the Rust public API require regenerating Swift bindings (`make swift-package`).

## Testing

- `make test` runs Rust unit tests
- `make test-integration` requires a downloaded model (~2.5GB)
- CI runs `cargo fmt --check`, `cargo clippy --all-targets --all-features`, `cargo test`, and the Swift `ParakattTests` bundle via `xcodebuild test`

## Pull Request Guidelines

- Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) for PR titles and commit subjects, for example `feat(linux): add meeting controls`.
- Keep the PR body self-contained and readable in terminal clients: explain the problem, resulting behavior, and validation.
- Put screenshots and other change-related images in separate PR comments, not in the PR body.
- Keep PRs focused on a single change
- Include a description of what changed and why
- Don't push directly to `main`
- Ensure CI passes before requesting review
