"""Keep shared preparation from accidentally weakening the existing CI gates."""

from pathlib import Path
import os
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.test = (ROOT / ".github/workflows/test.yml").read_text()

    def job(self, name, workflow=None):
        match = re.search(
            rf"^  {name}:\n(.*?)(?=^  [\w-]+:|\Z)", workflow or self.test, re.MULTILINE | re.DOTALL
        )
        self.assertIsNotNone(match, name)
        return match.group(1)

    def test_preparation_is_shared_and_runs_independently(self):
        for name in ("swift-inputs", "media-inputs"):
            job = self.job(name)
            self.assertNotIn("    needs:", job)
            self.assertRegex(job, r"actions/cache(?:/restore)?@")
            self.assertIn("actions/upload-artifact@", job)
        swift = self.job("swift")
        self.assertIn("needs: [swift-inputs, media-inputs]", swift)
        self.assertIn("xcodegen generate", swift)
        for repeated_work in (
            "make rust",
            "make swift-package",
            "make media-tools",
            "make xcode",
            "cargo install",
        ):
            self.assertNotIn(repeated_work, swift)

    def test_failed_preparation_fails_required_checks_instead_of_skipping_them(self):
        swift = self.job("swift")
        self.assertIn("if: ${{ !cancelled() }}", swift)
        self.assertIn('test "$SWIFT_INPUTS_RESULT" = success', swift)
        self.assertIn('test "$MEDIA_INPUTS_RESULT" = success', swift)
        self.assertIn("&& 'macos-15' || 'ubuntu-24.04'", swift)

    def test_native_and_download_caches_do_not_restore_different_input_keys(self):
        for name in ("swift-inputs", "media-inputs"):
            job = self.job(name)
            self.assertNotIn("restore-keys:", job)
            self.assertIn("steps.environment.outputs.environment", job)
        self.assertIn("config/media-tools.json", self.job("media-inputs"))
        self.assertIn("rust-toolchain.toml", self.job("swift-inputs"))

    def test_tool_cache_is_saved_before_rust_post_job_cleanup(self):
        swift = self.job("swift-inputs")
        tools = swift.split("- name: Cache pinned build tools", 1)[1].split(
            "- name: Cache generated Rust framework", 1
        )[0]
        self.assertIn("actions/cache/restore@", tools)
        self.assertNotIn(
            "actions/cache@", tools, "Post-job saving would cache a pruned target directory"
        )
        save = swift.index("uses: actions/cache/save@")
        self.assertLess(swift.index("test -x target/ci-tools/bin/cargo-swift"), save)
        self.assertLess(save, swift.index("- name: Check Swift sources"))
        self.assertIn("key: ${{ steps.tools.outputs.cache-primary-key }}", swift)
        self.assertIn("macos-ci-tools-v2-", tools, "Do not reuse the previously pruned cache")

    def test_unrelated_workflow_edits_do_not_invalidate_native_build_caches(self):
        swift = self.job("swift-inputs")
        self.assertNotIn("'.github/workflows/test.yml'", swift)
        self.assertIn("env.CARGO_SWIFT_VERSION", swift)
        self.assertIn('--version "$CARGO_SWIFT_VERSION"', swift)

    def test_quality_checks_are_parallel_and_keep_the_required_aggregate(self):
        workflow = (ROOT / ".github/workflows/quality.yml").read_text()
        aggregate = self.job("quality", workflow)
        self.assertIn("name: Source and Dependency Policy", aggregate)
        self.assertIn("needs: [source-policy, fuzz, mutation]", aggregate)
        self.assertIn("if: ${{ !cancelled() }}", aggregate)
        for name in ("SOURCE", "FUZZ", "MUTATION"):
            self.assertIn(f'test "${name}_RESULT" = success', aggregate)
        for name in ("source-policy", "fuzz", "mutation"):
            self.assertNotIn("    needs:", self.job(name, workflow))
        fuzz = self.job("fuzz", workflow)
        self.assertIn('workspaces: "fuzz -> target"', fuzz)
        self.assertIn("quality-fuzz-nightly-2026-11-04", fuzz)
        self.assertIn("make fuzz-check", fuzz)
        self.assertIn("make mutation-check", self.job("mutation", workflow))
        self.assertIn(
            "cargo deny --manifest-path fuzz/Cargo.toml", self.job("source-policy", workflow)
        )

    def test_mutation_target_runs_without_a_preexisting_build_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "VERSION").write_text("0.0.0\n")
            binaries = root / "bin"
            binaries.mkdir()
            cargo = binaries / "cargo"
            cargo.write_text(
                '#!/bin/sh\n[ -d target ] || exit 42\nprintf "%s\\n" "$@" > arguments.txt\n'
            )
            cargo.chmod(0o755)
            subprocess.run(
                ["make", "-f", str(ROOT / "Makefile"), "mutation-check"],
                cwd=root,
                env=os.environ
                | {
                    "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
                    "SDKROOT": os.environ.get("SDKROOT", ""),
                },
                check=True,
                capture_output=True,
            )
            self.assertIn("target/mutation-contracts", (root / "arguments.txt").read_text())

    def test_sanitizers_coverage_packaging_and_playback_remain_enabled(self):
        swift = self.job("swift")
        for flag in (
            "-enableCodeCoverage YES",
            "-enableThreadSanitizer YES",
            "-enableAddressSanitizer YES",
        ):
            self.assertIn(flag, swift)
        for gate in (
            "make swift-analysis",
            "coverage_gate.py swift",
            "make package",
            "prepare_release.py",
            "smoke-media.py",
        ):
            self.assertIn(gate, swift)
        self.assertIn("COVERAGE_BASE_SHA", self.job("rust"))
        self.assertIn("cargo audit", self.job("rust"))

    def test_only_superseded_pull_request_runs_are_cancelled(self):
        for name in ("test", "quality", "cli"):
            workflow = (ROOT / f".github/workflows/{name}.yml").read_text()
            self.assertIn("github.event.pull_request.number || github.sha", workflow)
            self.assertIn(
                "cancel-in-progress: ${{ github.event_name == 'pull_request' }}", workflow
            )


if __name__ == "__main__":
    unittest.main()
