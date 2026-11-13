"""Cache keys must ignore unrelated checks but invalidate on real native inputs."""

import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from native_build_inputs import REQUIRED_FILES, source_fingerprint

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("swift_package", ROOT / "scripts/swift-package.py")
SWIFT_PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SWIFT_PACKAGE)


class NativeBuildInputTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        for name in REQUIRED_FILES:
            self.write(name, name)
        self.write("crates/parakatt-core/src/lib.rs", "pub fn native() {}")

    def write(self, name, contents):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)

    def test_unrelated_makefile_ci_and_mutation_edits_keep_the_cache_key(self):
        before = source_fingerprint(self.root)
        for name in ("Makefile", ".cargo/mutants.toml", ".github/workflows/test.yml", "docs/ci.md"):
            self.write(name, "unrelated check changed")
        self.assertEqual(source_fingerprint(self.root), before)

    def test_real_native_inputs_and_build_recipe_invalidate_the_key(self):
        for name in (
            *REQUIRED_FILES,
            ".cargo/config",
            ".cargo/config.toml",
            "crates/parakatt-core/src/lib.rs",
            "crates/parakatt-core/build.rs",
            "crates/parakatt-core/native-runtime-manifest.json",
            "crates/parakatt-core/Cargo.toml",
            "crates/parakatt-core/api.udl",
            "vendor/parakeet-rs/src/lib.rs",
            "vendor/parakeet-rs/Cargo.toml",
        ):
            with self.subTest(name=name):
                before = source_fingerprint(self.root)
                self.write(name, "changed native input")
                self.assertNotEqual(source_fingerprint(self.root), before)

    def test_removing_native_sources_invalidates_the_key(self):
        before = source_fingerprint(self.root)
        (self.root / "crates/parakatt-core/src/lib.rs").unlink()
        self.assertNotEqual(source_fingerprint(self.root), before)

    def test_missing_recipe_fails_instead_of_restoring_an_unverifiable_cache(self):
        (self.root / "scripts/build-native-core.sh").unlink()
        with self.assertRaises(FileNotFoundError):
            source_fingerprint(self.root)

    def test_local_binding_fingerprint_uses_the_same_source_boundaries(self):
        with (
            patch.object(SWIFT_PACKAGE, "ROOT", self.root),
            patch.dict(os.environ, {}, clear=True),
            patch.object(
                SWIFT_PACKAGE.subprocess, "check_output", return_value=b"pinned toolchain"
            ),
        ):
            before = SWIFT_PACKAGE.fingerprint()
            self.write("Makefile", "mutation flags changed")
            self.write(".cargo/mutants.toml", "different mutation filters")
            self.assertEqual(SWIFT_PACKAGE.fingerprint(), before)
            self.write("scripts/build-native-core.sh", "different native compiler flags")
            self.assertNotEqual(SWIFT_PACKAGE.fingerprint(), before)

    def test_native_recipe_preserves_locked_build_and_empty_feature_selection(self):
        binaries = self.root / "bin"
        binaries.mkdir()
        cargo = binaries / "cargo"
        cargo.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > arguments.txt\n')
        cargo.chmod(0o755)
        for features in ("webgpu", ""):
            with self.subTest(features=features):
                subprocess.run(
                    ["sh", str(ROOT / "scripts/build-native-core.sh")],
                    cwd=self.root,
                    env=os.environ
                    | {
                        "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
                        "SDKROOT": str(self.root),
                        "PARAKATT_SPEECH_FEATURES": features,
                    },
                    check=True,
                )
                self.assertEqual(
                    (self.root / "arguments.txt").read_text().splitlines(),
                    [
                        "build",
                        "--locked",
                        "--release",
                        "--target",
                        "aarch64-apple-darwin",
                        "-p",
                        "parakatt-core",
                        "--features",
                        features,
                    ],
                )

    def test_make_native_target_delegates_to_the_hashed_recipe(self):
        result = subprocess.check_output(["make", "-n", "rust"], cwd=ROOT, text=True)
        self.assertEqual(result.strip(), "sh scripts/build-native-core.sh")
