"""Change selection must fail closed and account for removed and renamed Rust inputs."""

from pathlib import Path
import os
import subprocess
import tempfile
import unittest

from ci_changes import needs_rust_checks

SCRIPT = Path(__file__).with_name("ci_changes.py")


class ChangeSelectionTests(unittest.TestCase):
    def test_swift_only_and_documentation_changes_do_not_need_rust_mutations(self):
        self.assertFalse(
            needs_rust_checks(
                [
                    "Parakatt/App/AppState.swift",
                    "Tests/RecordingOverlayTests.swift",
                    "Launcher/main.swift",
                    "project.yml",
                    ".swiftlint.yml",
                    "docs/ci.md",
                    "README.md",
                ]
            )
        )

    def test_every_native_build_test_and_ci_input_requires_full_checks(self):
        for name in (
            "crates/parakatt-core/src/engine.rs",
            "crates/parakatt-core/tests/config.rs",
            "crates/parakatt-cli/src/main.rs",
            "vendor/parakeet-rs/Cargo.toml",
            "Cargo.toml",
            "Cargo.lock",
            "rust-toolchain.toml",
            "fuzz/Cargo.lock",
            "fuzz/seeds/input",
            ".cargo/mutants.toml",
            "Makefile",
            ".github/workflows/quality.yml",
            "scripts/ci_changes.py",
            "scripts/test_ci_changes.py",
            "config/coverage.json",
            "unknown/new-input",
        ):
            with self.subTest(name=name):
                self.assertTrue(needs_rust_checks(["Parakatt/App/AppState.swift", name]))

    def test_main_and_other_events_always_request_full_checks(self):
        for event in ("push", "schedule", "workflow_dispatch"):
            result = subprocess.run(
                ["python3", str(SCRIPT)],
                env=os.environ | {"GITHUB_EVENT_NAME": event},
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.stdout.strip(), "rust_checks=true")

    def test_missing_base_fails_instead_of_skipping_checks(self):
        result = subprocess.run(
            ["python3", str(SCRIPT)],
            env=os.environ | {"GITHUB_EVENT_NAME": "pull_request"},
            capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)

    def test_git_diff_includes_removed_and_renamed_rust_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)

            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root, text=True).strip()

            git("init", "-q")
            git("config", "user.name", "CI Test")
            git("config", "user.email", "ci@example.invalid")
            (root / "engine.rs").write_text("fn main() {}\n")
            git("add", ".")
            git("commit", "-qm", "base")
            base = git("rev-parse", "HEAD")
            (root / "engine.rs").rename(root / "notes.md")
            git("add", "-A")
            git("commit", "-qm", "rename")
            result = subprocess.run(
                ["python3", str(SCRIPT), "--base", base],
                cwd=root,
                env=os.environ | {"GITHUB_EVENT_NAME": "pull_request"},
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.stdout.strip(), "rust_checks=true")
