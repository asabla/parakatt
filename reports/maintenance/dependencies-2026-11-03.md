# Dependency update, 2026-11-03

Base commit: `1989ec72132f977b929136a0d462e08acfbcd989` (Parakatt 0.7.0).

This report records the initial dependency checks. Subsequent versioned release and installation work is recorded in [the 0.7.1 preparation report](../releases/0.7.1.md).

## Updated dependencies

| Component | Previous | Updated |
| --- | --- | --- |
| Rust | 1.94.1 | 1.99.1 |
| rusqlite | 0.40.2 | 0.41.1 |
| SHA-2 | 0.10.9 | 0.11.1 |
| Tokio | 1.53.1 | 1.54.1 |
| tokio-util | 0.7.19 | 0.7.20 |
| TOML | 1.1.6 | 1.1.8 |
| yt-dlp | 2026.08.19 | 2026.10.26 |
| Deno | 2.9.7 | 2.9.8 |
| FFmpeg | 8.0.1 | 9.0.2 |
| dav1d | 1.5.1 | 1.5.4 |
| Meson | 1.9.1 | 1.12.1 |
| Ninja | 1.13.0 | 1.13.2 |
| Python packaging | 25.0 | 26.3 |
| actions/upload-artifact | 7.0.1 | 7.0.2 |
| actions/download-artifact | 8.0.1 | 8.0.2 |

The Cargo lockfile also refreshes compatible indirect dependencies. CI uses the same Rust version as local builds. The Rust cache action is pinned to 2.9.3.

The SQLite backup calls specify their callback type for the new API. SHA-256 output keeps its existing lowercase, zero-padded encoding. A fixed SHA-256 test checks that format. The new Clippy checks also require small changes to byte-array iteration and formatting arguments.

Media downloads use exact SHA-256 pins. The yt-dlp and Deno binary hashes match their official release asset digests. Source archives and Deno dependency notices match the new versions. Deno still uses rusty_v8 150.4.0 with the same Cargo checksum and TypeScript 6.0.3, so the existing native notices remain applicable.

The media build uses a separate dav1d installation directory for each version and a virtual environment for the pinned build tools. A changed build removes the previous completion stamp, media-tool sources, and notices before preparing the new set. It preserves the separate playback source bundle. A regression test covers this boundary. This prevents reuse of an older dav1d library or inclusion of stale sources and notices.

Xcode 27.1 requires the buffered-preview completion flag to change on the main queue. The completion now dispatches that change to the main queue on success and failure.

## Retained pins

- UniFFI 0.31.1: cargo-swift 0.11.1 requires exactly uniffi_bindgen 0.31.1. Updating only the library would break binding generation.
- parakeet-rs 0.3.8 and ORT rc.13: the vendored speech frontend has a measured accuracy patch and a pinned native WebGPU runtime. A runtime upgrade needs separate English and Swedish accuracy acceptance and matching runtime checks. This update does not change those pins or promote backend combinations.
- VLCKit 3.7.3: the official stable binary remains at this version. The available 4.0 builds are prereleases.
- HotKey 0.2.1, XcodeGen 2.46.0, cargo-swift 0.11.1, and cargo-audit 0.22.2 remain at their current stable releases.

## Validation

Local validation uses Apple Silicon, macOS 27.0.1 (`26A434`), Xcode 27.1, and Rust 1.99.1. Detailed logs and temporary fixtures are in the ignored `target/dependency-updates` directory.

- Release-tool tests: 12 passed. Media download and rebuild tests: 9 passed.
- Rust formatting and strict Clippy with all targets and features passed. Rust tests: 196 passed; one real-model test and two documentation examples are opt-in.
- The explicit real-model test also passed with one English and one Swedish FLEURS fixture. This checks transcription, not full accuracy acceptance.
- Refreshed RustSec audit: zero reported vulnerabilities. Informational unmaintained warnings remain for `basic-toml` through UniFFI and `paste` through tokenizers/parakeet-rs. Neither warning is suppressed.
- Media tools rebuilt with matching sources and 1,048 verified Deno dependency notices. Tool version checks, Deno evaluation, and AV1 decoding through dav1d passed.
- The public YouTube download check used the app's options with no cookies, plugins, self-update, or remote components. YouTube rejected the request with “Sign in to confirm you're not a bot.” Live YouTube download compatibility could not be confirmed from this host.
- Swift bindings regenerated and compiled. The Swift suite executed 52 tests, with one opt-in test skipped and no failures. Xcode still reports concurrency and CFString pointer warnings in existing code; this update does not complete a Swift concurrency migration.
- The release app, ZIP, DMG, and corresponding source ZIP were built. Package checks passed for the stable launcher, version/build fields, all 11 Mach-O deployment targets, bundled helpers, playback framework, and notices. `hdiutil verify` passed.
- Source ZIP contents were checked against every pinned media source and playback/contrib source hash.
- Isolated packaged startup loaded the installed Parakeet model on CPU. A retained 19.028-second AV1 video completed transcription and subtitle export with four segments and a maximum audio block of 304,448 samples. The report identifies the updated tool versions. The source was already local; this does not complete the blocked live download check.
- Packaged playback used a real window (`video_output=window`), displayed frames after three seeks, left the source unchanged, and created no playback copy.

Local artifacts are in `dist`. They retain the existing development version and are not newly published release assets:

| Local artifact | SHA-256 |
| --- | --- |
| `Parakatt-0.7.0-arm64.zip` | `be077504e343f2c68cb666b53ba4e7f1872be0c0a2482126a22c5fdfcf90bce4` |
| `Parakatt-0.7.0-arm64.dmg` | `c65cd2d2526f2dcb69d0fa7e9b3d948d2fdabd2dda94aa18b38f02d966529a36` |
| `Parakatt-0.7.0-media-sources.zip` | `2de2ee27ec2c9d279ee2aa90a2256651572469806782f08772b186ab3d19041a` |

## Evidence limits

These are local dependency-update checks. They do not qualify a new release, establish new speech accuracy or performance results, test live capture or installed-update permissions, or prove macOS 14 runtime behavior. Hosted CI has not run for this change. No release was published and the installed application was not replaced. Version and build metadata remain at 0.7.0, build 2.

Upstream references: [Rust releases](https://blog.rust-lang.org/releases/), [FFmpeg releases](https://ffmpeg.org/download.html), [yt-dlp 2026.10.26](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.10.26), [Deno 2.9.8](https://github.com/denoland/deno/releases/tag/v2.9.8), [dav1d releases](https://download.videolan.org/pub/videolan/dav1d/), and [VLCKit binaries](https://download.videolan.org/pub/cocoapods/prod/).
