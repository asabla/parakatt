# Release process

Parakatt releases target Apple Silicon and macOS 14 or later. Pushing a `vX.Y.Z` tag starts `.github/workflows/release.yml` and publishes a GitHub release after its checks pass. Use a pull request for release preparation. Complete the acceptance checks before pushing the tag.

## Prepare the version

`VERSION` contains the app and Rust package version. `BUILD_NUMBER` contains the integer app build number.

```sh
./scripts/sync-version.sh 0.7.0
./scripts/sync-version.sh --check
```

The script updates `project.yml`, `Parakatt/Info.plist`, the core manifest, and the core entry in `Cargo.lock`. A new version increases the build number by one. To use a specific higher build number, add `--build-number N`. Repeating the same version does not increase the number. Make reads `VERSION` directly. Dependency versions are not changed.

Update `CHANGELOG.md` and `RELEASE_NOTES.md`. The first release-note line must be `# Parakatt X.Y.Z`. The changelog must contain `## X.Y.Z`. The release workflow checks both before building.

The source cask in `homebrew/parakatt.rb` describes a published release. Version preparation does not change it. A new cask needs the checksum of the exact published DMG.

## Build and verify

Use the pinned Rust toolchain, XcodeGen 2.46.0, and cargo-swift 0.11.1. Install `create-dmg` on the build machine to make the DMG. End users do not need these tools.

```sh
python3 scripts/test_release_tools.py
python3 scripts/test_media_tool_downloads.py
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

`make package` reuses `bin/parakatt-launcher`, checks its recorded signature identity, checks app version/build fields and native dependencies, checks bundled helpers and notices, and runs isolated startup. Do not run `make launcher` as a routine release step. Changing the launcher or its signing identity requires a separate installed-update permission test.

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

## Acceptance before publication

Record the commit, hardware, OS, result, and evidence for these checks in the release report:

- Install the packaged app on an actual macOS 14 system. Start it and test transcription and original-video playback. A deployment-target check does not replace this test.
- Update an existing installation. Verify Microphone, Accessibility, and system-audio permissions. Check recording and paste after the update. An unchanged launcher hash alone does not prove permission persistence.
- Check microphone capture, system-audio capture, pause/resume, and recording controls with live input. Check initial model loading and silent or missing input.
- Check complete synthetic responses with configured local and remote LLM providers. Use **Test selected model** with the model that will be used. Mock servers do not prove live provider compatibility.
- Check local window playback, seeking, cancellation, subtitles, and transcript behavior after the video is removed.
- Require passing hosted CI on the exact preparation commit. Retain its release candidate and dependency audit. Historical reports identify earlier checks and must not be presented as checks of the new release.

Record unavailable checks as pending. Do not mark the release fully qualified while required checks remain pending. Keep new backend combinations disabled until their validation is recorded.

## Publish

After the preparation pull request is merged and acceptance is complete, tag its verified main commit:

```sh
./scripts/sync-version.sh --check --tag "v$(cat VERSION)"
git tag -a "v$(cat VERSION)" -m "Release $(cat VERSION)"
git push origin "v$(cat VERSION)"
```

Monitor the Release workflow. It runs Rust formatting, Clippy, tests, dependency audit, Swift tests, `make package`, headless playback, and DMG verification. It publishes the app ZIP, DMG, corresponding media source ZIP, SHA256SUMS, generated cask, dependency audit, and validation reports. Release text comes from `RELEASE_NOTES.md`.

## Homebrew

The release workflow generates `parakatt.rb` from the same DMG it uploads. It does not reuse a local candidate checksum.

For automated tap pull requests, configure the `HOMEBREW_TAP_TOKEN` repository secret. The token needs contents and pull-request write access to `asabla/homebrew-tap`. The workflow creates or updates a version-specific branch and opens a pull request. It does not merge the pull request. If the secret is absent, the workflow gives a warning and leaves the exact cask attached to the release.

To prepare an update manually, download the release assets and verify the DMG checksum. Copy the attached `parakatt.rb` to `Casks/parakatt.rb` in the tap, review the version/checksum, and submit the tap change. Copy the published cask back to `homebrew/parakatt.rb` for the next source update.

## Signing

This repository currently distributes ad-hoc signed builds. Developer ID signing and Apple notarization are not configured. The release notes must state that limit.

Enabling notarization requires an Apple Developer account, a Developer ID Application certificate/private key, and notarization credentials. This also changes the launcher signing identity. Prepare that as a separate change, validate all nested code, notarize and staple the app and DMG, and verify permission persistence with the previously installed release. Do not claim that an unsigned launcher hash proves behavior after this transition.
