"""Keep shared preparation from accidentally weakening the existing CI gates."""

from pathlib import Path
import os
import re
import subprocess
import tempfile
import textwrap
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

    def test_normal_swift_tests_reuse_preparation_on_the_same_runner(self):
        swift = self.job("swift")
        self.assertNotIn("    needs:", swift)
        self.assertIn("name: Swift Build & Tests\n", swift)
        self.assertIn("run: make swift-package", swift)
        self.assertIn("run: make media-tools", swift)
        self.assertIn("xcodebuild test", swift)
        self.assertIn("swift-build-inputs", swift)
        self.assertIn("media-build-inputs", swift)
        self.assertNotIn("actions/download-artifact@", swift)
        self.assertIn("xcodegen generate", swift)
        sanitizers = self.job("swift-sanitizers")
        self.assertIn("needs: [swift]", sanitizers)
        for repeated_work in (
            "make rust",
            "make swift-package",
            "make media-tools",
            "make xcode",
            "cargo install",
        ):
            self.assertNotIn(repeated_work, sanitizers)

    def test_failed_preparation_fails_required_checks_instead_of_skipping_them(self):
        swift = self.job("swift-sanitizers")
        self.assertIn("if: ${{ !cancelled() }}", swift)
        self.assertIn('test "$INPUTS_READY" = true', swift)
        self.assertIn("&& 'macos-15' || 'ubuntu-24.04'", swift)
        normal = self.job("swift")
        self.assertLess(normal.index("name: media-build-inputs"), normal.index("id: inputs-ready"))
        self.assertLess(normal.index("id: inputs-ready"), normal.index("- name: Run Swift tests"))

    def test_native_and_download_caches_do_not_restore_different_input_keys(self):
        job = self.job("swift")
        self.assertNotIn("restore-keys:", job)
        self.assertIn("steps.environment.outputs.environment", job)
        self.assertIn("config/media-tools.json", job)
        self.assertIn("steps.environment.outputs.native_sources", job)

    def test_tool_cache_is_saved_before_rust_post_job_cleanup(self):
        swift = self.job("swift")
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
        for cache, following in (
            ("Cache prepared media binaries", "Cache checksum-verified"),
            ("Cache checksum-verified", "Test media dependency downloads"),
        ):
            restore = swift.split(f"- name: {cache}", 1)[1].split(f"- name: {following}", 1)[0]
            self.assertIn("actions/cache/restore@", restore)
            self.assertNotIn("actions/cache@", restore)
        for name in ("media", "media-downloads"):
            self.assertIn(f"key: ${{{{ steps.{name}.outputs.cache-primary-key }}}}", swift)

    def test_unrelated_workflow_edits_do_not_invalidate_native_build_caches(self):
        swift = self.job("swift")
        self.assertNotIn("'.github/workflows/test.yml'", swift)
        self.assertIn("env.CARGO_SWIFT_VERSION", swift)
        self.assertIn('--version "$CARGO_SWIFT_VERSION"', swift)
        bindings = swift.split("- name: Cache generated Rust framework", 1)[1].split(
            "- name: Cache Rust build dependencies", 1
        )[0]
        self.assertIn("steps.environment.outputs.native_sources", bindings)
        self.assertNotIn("Makefile", bindings)
        self.assertNotIn(".cargo/**", bindings)
        self.assertIn('python3 scripts/native_build_inputs.py >> "$GITHUB_OUTPUT"', swift)

    def test_quality_checks_are_parallel_and_keep_the_required_aggregate(self):
        workflow = (ROOT / ".github/workflows/quality.yml").read_text()
        aggregate = self.job("quality", workflow)
        self.assertIn("name: Source and Dependency Policy", aggregate)
        self.assertIn("needs: [changes, source-policy, fuzz, mutation]", aggregate)
        self.assertIn("if: ${{ !cancelled() }}", aggregate)
        for name in ("SOURCE", "CHANGES", "FUZZ", "MUTATION"):
            self.assertIn(f'test "${name}_RESULT" = success', aggregate)
        self.assertNotIn("    needs:", self.job("source-policy", workflow))
        for name in ("fuzz", "mutation"):
            self.assertIn("needs: [changes]", self.job(name, workflow))
            self.assertIn(
                "if: needs.changes.outputs.rust_checks == 'true'", self.job(name, workflow)
            )
        fuzz = self.job("fuzz", workflow)
        self.assertIn('workspaces: "fuzz -> target"', fuzz)
        self.assertIn("quality-fuzz-nightly-2026-11-04", fuzz)
        self.assertIn("make fuzz-check", fuzz)
        self.assertIn("make mutation-check", self.job("mutation", workflow))
        self.assertIn(
            "cargo deny --manifest-path fuzz/Cargo.toml", self.job("source-policy", workflow)
        )

    def test_quality_aggregate_only_accepts_intentional_skips(self):
        workflow = (ROOT / ".github/workflows/quality.yml").read_text()
        command = textwrap.dedent(self.job("quality", workflow).split("run: |\n", 1)[1])
        baseline = {
            "SOURCE_RESULT": "success",
            "CHANGES_RESULT": "success",
            "RUST_CHECKS": "true",
            "FUZZ_RESULT": "success",
            "MUTATION_RESULT": "success",
        }
        for changes, expected in (
            ({}, True),
            (
                {"RUST_CHECKS": "false", "FUZZ_RESULT": "skipped", "MUTATION_RESULT": "skipped"},
                True,
            ),
            ({"SOURCE_RESULT": "failure"}, False),
            ({"CHANGES_RESULT": "failure", "RUST_CHECKS": "false"}, False),
            ({"RUST_CHECKS": ""}, False),
            ({"FUZZ_RESULT": "failure"}, False),
            ({"MUTATION_RESULT": "failure"}, False),
            ({"MUTATION_RESULT": "skipped"}, False),
            (
                {"RUST_CHECKS": "false", "FUZZ_RESULT": "failure", "MUTATION_RESULT": "skipped"},
                False,
            ),
        ):
            with self.subTest(changes=changes):
                result = subprocess.run(
                    ["bash", "-e", "-c", command], env=os.environ | baseline | changes
                )
                self.assertEqual(result.returncode == 0, expected)

    def test_all_mutation_shards_are_required_without_reducing_the_suite(self):
        workflow = (ROOT / ".github/workflows/quality.yml").read_text()
        mutation = self.job("mutation", workflow)
        self.assertIn("shard: [0, 1]", mutation)
        self.assertIn("fail-fast: false", mutation)
        self.assertIn("--shard $MUTATION_SHARD/2 --no-shuffle", mutation)
        self.assertNotIn("--baseline=skip", mutation)

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
                [
                    "make",
                    "-f",
                    str(ROOT / "Makefile"),
                    "mutation-check",
                    "MUTATION_FLAGS=--shard 0/2 --no-shuffle",
                ],
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
            self.assertIn("--shard\n0/2\n--no-shuffle", (root / "arguments.txt").read_text())

    def test_sanitizers_coverage_packaging_and_playback_remain_enabled(self):
        swift = self.job("swift")
        self.assertIn("-enableCodeCoverage YES", swift)
        sanitizers = self.job("swift-sanitizers")
        for flag in ("-enableThreadSanitizer", "-enableAddressSanitizer"):
            self.assertIn(flag, sanitizers)
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

    def test_only_release_work_is_conditional_and_ordinary_prs_keep_runtime_checks(self):
        swift = self.job("swift")
        for name in (
            "Analyze Swift declarations and imports",
            "Build and verify release package",
            "Verify DMG and prepare release metadata",
            "Save release candidate",
        ):
            step = swift.split(f"- name: {name}\n", 1)[1].split("- name:", 1)[0]
            self.assertIn("if: github.event_name == 'push'", step)
            self.assertIn("startsWith(github.head_ref, 'codex/release-')", step)
            self.assertIn("startsWith(github.head_ref, 'release/')", step)
        for name in (
            "Run Swift tests",
            "Check bundled video playback",
        ):
            step = swift.split(f"- name: {name}\n", 1)[1].split("- name:", 1)[0]
            self.assertNotIn("        if:", step)
        self.assertIn('python3 scripts/smoke-app.py "$APP"', swift)
        release = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn("make package", release)

    def test_only_superseded_pull_request_runs_are_cancelled(self):
        for name in ("test", "quality", "cli"):
            workflow = (ROOT / f".github/workflows/{name}.yml").read_text()
            self.assertIn("github.event.pull_request.number || github.sha", workflow)
            self.assertIn(
                "cancel-in-progress: ${{ github.event_name == 'pull_request' }}", workflow
            )


if __name__ == "__main__":
    unittest.main()
