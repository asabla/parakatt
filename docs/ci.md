# CI build inputs

The Test workflow's **Swift Build & Tests** job prepares native inputs and runs the normal Swift tests on the **same macOS runner**. It does not queue for another runner between preparation and testing. Prepared inputs include:

- **Swift inputs:** the Rust framework, generated Swift bindings, pinned XcodeGen (including its settings presets), and SwiftLint.
- **Media inputs:** the prepared media executables, playback framework, licenses, and corresponding source archives.

The normal job uploads these inputs for the Thread Sanitizer and Address Sanitizer jobs, which remain enabled on every PR and build/test independently. No DerivedData or test results are shared. Sanitizers depend on the normal job's completion; if preparation fails they report failure on Linux rather than waiting for macOS. If preparation succeeds but normal tests fail, sanitizers still run against the prepared inputs.

Every PR retains SwiftLint, Swift tests/coverage, both sanitizers, Rust/CLI tests and coverage, dependency checks, and app startup/video-playback smoke checks. Full Swift declaration/import analysis runs on main pushes and release PRs, rather than blocking ordinary PR sanitizers. This deliberately defers those analyzer findings until main/release validation. Analysis took roughly five to six minutes of actual work in measured runs, not tool installation; its results are not reused from another commit.

DMG creation, release metadata, release-candidate uploads, and the packaged launcher's startup checks run on main pushes and release PRs (`codex/release-*` or `release/*`), not ordinary PRs. Ordinary PRs smoke-test the Debug app already built by the test scheme; release runs smoke-test the Release app. Tagged release packaging remains in `.github/workflows/release.yml`.

## Cache boundaries

- Native caches include architecture, Xcode version/build, SDK version/build, and deployment target. `scripts/native_build_inputs.py` defines the source hash shared by CI and the local binding generator: pinned toolchain, Cargo manifests/lockfile, Rust sources, native manifests, Cargo build configuration, binding generator, and `scripts/build-native-core.sh`. The native Makefile target delegates to that hashed recipe. Unrelated Makefile targets, `.cargo/mutants.toml`, and workflow edits do not invalidate native frameworks.
- Media keys include both dependency manifests, preparation scripts, runtime entitlements, and vendored notices. Only finished outputs are cached; Python environments, compiler work directories, and VLCKit unpacking trees are not shared.
- Download caches use exact manifest keys: some upstream filenames stay the same across versions, so falling back to a different manifest would restore stale files. Preparation still checks every downloaded file against its pinned checksum. Native framework caches likewise have no fallback to a different source/toolchain configuration.
- Tool cache keys include the pinned installation scripts, Rust toolchain, and cargo-swift version. Native/tool keys do not include the entire workflow, so unrelated workflow edits do not rebuild them. Source lint runs even when tool/framework caches hit.
- Tools and media/download caches are explicitly saved before the Rust cache's post-job cleanup prunes `target/`. Do not switch these to post-job saving: it can save almost-empty caches even though the build succeeded.

Artifacts are tar archives inside GitHub artifacts to preserve executable permissions and framework symlinks. Restoration checks the commit, native environment, bundle type, and allowed paths before extraction. All test variants and release packaging receive the full media license/source set.

Superseded pull-request runs are cancelled; main-branch commits and tagged release runs are not cancelled by this rule.

## Quality checks

Source/dependency policy always runs. `scripts/ci_changes.py` conservatively selects bounded fuzzing and contract mutation testing from the **entire PR diff against its base**, including deletions and renames. Only Swift source changes under `Parakatt/`, `Launcher/`, and `Tests/`, documentation, and the explicitly listed Swift project/lint configuration can skip these Rust checks. Unknown paths, Rust sources/tests, native manifests, dependencies, scripts, Makefile, and CI configuration run the full checks. Main pushes always run everything. A failed diff calculation fails CI rather than skipping checks.

Mutation testing uses two shards (`0/2`, `1/2`) with identical filters and `--no-shuffle`. Together they cover the complete configured mutation set; each retains its baseline tests. Neither sampling nor changed-line filtering is used. This increases total runner work slightly in exchange for shorter wall time. Both shards must pass.

Each quality job has its own Rust cache; fuzzing caches `fuzz/target` with the pinned nightly in its key. The existing **Source and Dependency Policy** required check aggregates selection, source policy, fuzzing, and both mutation shards. It only accepts skipped Rust checks when selection succeeded and explicitly determined they were unnecessary. A Rust-containing PR continues to require them even if its latest update only changes Swift.

## Validation and timing

Run the offline checks with:

```sh
python3 -m unittest discover -s scripts -p 'test_*.py'
target/tools/bin/actionlint
target/tools/bin/ruff check scripts
target/tools/bin/ruff format --check scripts
```

Compare cold and warm runs separately. Warm runs should skip Rust/binding compilation and media builds. Cold preparation now occurs on one runner and may take longer than the former parallel preparation; the main gain is removing the second macOS allocation from the normal test path. Check selection uses the whole PR diff, so use a Swift-only PR (not just a Swift-only update to a Rust-containing PR) to measure intentionally skipped Rust contract checks.

Measure runner queue time separately from execution, along with preparation, Swift tests, sanitizer jobs, and each mutation shard. Full analysis and packaging should be absent on ordinary PRs. The first run after migrating to the shared native source hash populates a new cache once; use a same-commit workflow rerun to measure warm behavior without changing inputs again. The goal is materially faster warm PR feedback, not a guaranteed duration: macOS queues and cold builds remain constraints; main/release validation also includes full analysis and packaging.
