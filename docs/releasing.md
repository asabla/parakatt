# Release process

The packaged Parakatt release targets Apple Silicon and macOS 14 or later. The experimental Linux desktop is built from source. Pushing a `vX.Y.Z` tag starts `.github/workflows/release.yml` and publishes a GitHub release after its checks pass. Use a pull request for release preparation. Complete the acceptance checks before pushing the tag.

## Prepare the version

`VERSION` contains the app and Rust package version. `BUILD_NUMBER` contains the integer app build number.

```sh
./scripts/sync-version.sh 0.7.0
./scripts/sync-version.sh --check
```

The script updates `project.yml`, `Parakatt/Info.plist`, the core manifest, the CLI and fuzz manifests that depend on the core, and both Cargo lockfiles. A new version increases the build number by one. To use a specific higher build number, add `--build-number N`. Repeating the same version does not increase the number. Make reads `VERSION` directly. Dependency versions are not changed.

Update `CHANGELOG.md` and `RELEASE_NOTES.md`. The first release-note line must be `# Parakatt X.Y.Z`. The changelog must contain `## X.Y.Z`. The release workflow checks both before building.

The source cask in `homebrew/parakatt.rb` describes a published release. Version preparation does not change it. A new cask needs the checksum of the exact published DMG.

## Build and verify

Use the pinned Rust toolchain and XcodeGen 2.46.0. Swift bindings come from the workspace-pinned UniFFI generator; `xcodebuild` assembles the versioned framework and Swift package. Install `create-dmg` on the build machine to make the DMG. End users do not need these tools.

CI selects Python 3.13 explicitly. Media build environments are keyed by the
selected interpreter, its version, and the pinned Meson/Ninja/packaging versions.
An incomplete environment is cleared before bootstrap. Pip bootstrap runs as a
separate command so its errors are visible. These are build-only dependencies.

```sh
python3 scripts/test_release_tools.py
python3 scripts/test_media_tool_downloads.py
python3 scripts/test_media_build_environment.py
python3 scripts/test_benchmark_gates.py
python3 scripts/test_benchmark_worker.py
cargo fmt --check
cargo clippy --locked --all-targets --all-features -- -D warnings
cargo test --locked
make swift-package
make xcode
xcodebuild test -project Parakatt.xcodeproj -scheme Parakatt \
  -derivedDataPath target/xcode -destination 'platform=macOS' \
  -only-testing:ParakattTests CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO
make package
hdiutil verify "dist/Parakatt-$(cat VERSION)-arm64.dmg"
python3 scripts/prepare_release.py
```

`make package` builds the launcher with the app, signs nested code before sealing the completed bundle, and verifies the bundle with `codesign --verify --deep --strict`. It checks version and deployment targets, runs isolated startup, and builds the ZIP and DMG. By default it creates a sealed ad-hoc candidate for local tests and pull requests. The Release workflow requires Developer ID signing and notarization.

Run local playback with a real window:

```sh
APP="$(python3 scripts/build-products.py Release)/Parakatt.app"
python3 scripts/smoke-media.py "$APP" /absolute/path/to/video.mkv --playback
```

CI sets `TEST_RUNNER_PARAKATT_TEST_HEADLESS_PLAYBACK=1` for Swift tests and uses `--headless` for packaged playback. These checks prove decoding and controls. They do not prove display output. Local playback acceptance must report `video_output=window`.

The real-model and media-transcription checks require installed model files and attributed fixtures. Follow `reports/maintenance/README.md` and `reports/maintenance/video-import.md`. Provider checks use synthetic text:

```sh
cargo run --locked --release --example provider_smoke -- \
  lmstudio http://localhost:1234 selected-model-id
```

Use the corresponding provider, URL, and selected model for Ollama, OpenAI, or Anthropic. Remote credentials are read from `PARAKATT_PROVIDER_KEY`. Do not write credentials to reports or command arguments.

Release preparation branches named `codex/release-*` in this repository also run the candidate on GitHub's Apple Silicon `macos-14` image. This job downloads the candidate from the successful Swift job, checks its asset hashes, verifies the bundle, loads the checksum-pinned Parakeet model on CPU, transcribes one attributed English and Swedish fixture each, and checks headless playback. Its JSON reports are saved as `parakatt-macos14-runtime`. It does not test display output, live capture, or an installed update.

GitHub [retires the macOS 14 image on 2 November 2026](https://github.com/actions/runner-images/issues/13518), with scheduled brownouts in October. After retirement, this automatic job is disabled and the Rust job gives a warning. Run minimum-OS acceptance on an actual macOS 14 machine before subsequent releases. A skipped check is not passing runtime evidence.

## Acceptance before publication

Keep the commit, hardware, OS, result, and evidence for these checks in ignored
local storage under `target/release-validation/<version>`. Local acceptance
records and unfinished work do not belong in release notes or tracked release
reports.

- Install the packaged app on an actual macOS 14 system. Start it and test transcription and original-video playback. A deployment-target check does not replace this test.
- Open the installed app through Finder or `open /Applications/Parakatt.app`. Check the app’s microphone and Accessibility status in Settings, record real microphone and system audio, and paste a dictation into a separate app. Repeat after updating without clearing the grants. Test the ad-hoc to Developer ID migration with one reauthorization if needed. Verify persistence separately across two releases signed by the same Apple team.
- Compare a Finder replacement and an in-place `brew upgrade --cask parakatt` in separate test runs. See [Homebrew’s upgrade FAQ](https://docs.brew.sh/FAQ#why-do-my-cask-apps-lose-their-dock-position--launchpad-position--permission-settings-when-i-run-brew-upgrade) for App Management and the reinstall fallback. Record the result for each permission and the actual capture or paste step.
- Check microphone capture, system-audio capture, pause/resume, and recording controls with live input. Check initial model loading and silent or missing input.
- Check complete synthetic responses with configured local and remote LLM providers. Use **Test selected model** with the model that will be used. Mock servers do not prove live provider compatibility.
- Check local window playback, seeking, cancellation, subtitles, and transcript behavior after the video is removed.
- Require passing hosted CI on the exact preparation commit. Retain its release candidate and dependency audit. Historical reports identify earlier checks and must not be presented as checks of the new release.

Keep unavailable checks and follow-up work in the local records. Release notes
describe shipped changes and installation requirements. Keep new backend
combinations disabled until their validation is recorded.

## Publish

After the preparation pull request is merged and acceptance is complete, tag its verified main commit:

```sh
./scripts/sync-version.sh --check --tag "v$(cat VERSION)"
git tag -a "v$(cat VERSION)" -m "Release $(cat VERSION)"
git push origin "v$(cat VERSION)"
```

Monitor the Release workflow. It runs Rust formatting, Clippy, tests, dependency audit, Swift tests, `make package`, headless playback, and DMG verification. It publishes the app ZIP, DMG, corresponding media source ZIP, SHA256SUMS, generated cask, and dependency audit. Local validation reports are not release assets. Release text comes from `RELEASE_NOTES.md`.

## Homebrew

The release workflow generates `parakatt.rb` from the same DMG it uploads. It does not reuse a local candidate checksum.

For automated tap pull requests, configure the `HOMEBREW_TAP_TOKEN` repository secret. The token needs contents and pull-request write access to `asabla/homebrew-tap`. The workflow creates or updates a version-specific branch and opens a pull request. It does not merge the pull request. If the secret is absent, the workflow gives a warning and leaves the exact cask attached to the release.

To prepare an update manually, download the release assets and verify the DMG checksum. Copy the attached `parakatt.rb` to `Casks/parakatt.rb` in the tap, review the version/checksum, and submit the tap change. Copy the published cask back to `homebrew/parakatt.rb` for the next source update.

## Signing

Tagged releases require a Developer ID Application certificate from the project’s Apple team and an App Store Connect team API key for notarization. Set `MACOS_TEAM_ID` as a GitHub Actions variable. Configure these Actions secrets using the repository’s secret manager:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | Base64 of the Developer ID Application identity export with its private key |
| `MACOS_CERTIFICATE_PASSWORD` | Password for the PKCS#12 export |
| `MACOS_NOTARY_KEY_BASE64` | Base64 of the notarization `.p8` key |
| `MACOS_NOTARY_KEY_ID` | App Store Connect API key ID |
| `MACOS_NOTARY_ISSUER_ID` | App Store Connect issuer ID |

Use single-line base64. The workflow imports the identity into a temporary keychain, checks the signed bundle against the expected Developer ID team and `com.parakatt.app`, submits the app and DMG to Apple, and staples both tickets. Release metadata is generated only after the shipped ZIP and DMG pass signature and ticket checks. The generated cask installs the notarized DMG with quarantine handling left to macOS and Homebrew.

For a signed candidate on a Mac with the identity installed and a `notarytool` keychain profile set up, run:

```sh
PARAKATT_CODESIGN_IDENTITY='Developer ID Application: Example (ABCDEFGHIJ)' \
PARAKATT_SIGNING_TEAM_ID=ABCDEFGHIJ \
PARAKATT_NOTARY_PROFILE=parakatt-release make package
python3 scripts/prepare_release.py --require-notarized
```

Record the signing requirement with `codesign --display -r - /Applications/Parakatt.app` before and after the test. The Debug build uses `com.parakatt.app.debug` and Launch Services, so day-to-day development uses separate macOS grants. Use the Release artifact for installed-upgrade tests.
