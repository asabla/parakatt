# CI build inputs

The Test workflow prepares two independent sets of native inputs in parallel:

- **Swift inputs:** the Rust framework, generated Swift bindings, pinned XcodeGen (including its settings presets), and SwiftLint.
- **Media inputs:** the prepared media executables, playback framework, licenses, and corresponding source archives.

The normal, Thread Sanitizer, and Address Sanitizer jobs download the same inputs, then generate their own Xcode project and build/test independently. No DerivedData or test results are shared. Rust tests, coverage gates, source/dependency checks, fuzzing, mutation tests, release packaging, and playback validation remain enabled.

## Cache boundaries

- Native caches include architecture, Xcode version/build, SDK version/build, and deployment target. Rust framework keys also cover the pinned toolchain, Cargo manifests/lockfile, native manifests, source files, build configuration, and binding generator inputs.
- Media keys include both dependency manifests, preparation scripts, runtime entitlements, and vendored notices. Only finished outputs are cached; Python environments, compiler work directories, and VLCKit unpacking trees are not shared.
- Download caches use exact manifest keys: some upstream filenames stay the same across versions, so falling back to a different manifest would restore stale files. Preparation still checks every downloaded file against its pinned checksum. Native framework caches likewise have no fallback to a different source/toolchain configuration.
- Tool cache keys include the pinned installation scripts and workflow. Source lint runs even when tool/framework caches hit.

Artifacts are tar archives inside GitHub artifacts to preserve executable permissions and framework symlinks. Restoration checks the commit, native environment, bundle type, and allowed paths before extraction. All test variants and release packaging receive the full media license/source set.

A failed shared-preparation job explicitly fails the existing Swift checks rather than leaving required checks skipped. Superseded pull-request runs are cancelled; main-branch commits and tagged release runs are not cancelled by this rule.

## Validation and timing

Run the offline checks with:

```sh
python3 -m unittest discover -s scripts -p 'test_*.py'
target/tools/bin/actionlint
target/tools/bin/ruff check scripts
target/tools/bin/ruff format --check scripts
```

Compare the first CI run (cold caches) with a subsequent Swift-only commit (warm caches). Inspect the two preparation jobs, artifact transfer, and each Swift build separately. Warm runs should skip Rust/binding compilation and media builds. The overall PR duration can still be limited by mutation tests or release packaging; measure those before changing their coverage or scheduling.
