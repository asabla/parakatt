"""Keep shared preparation from accidentally weakening the existing CI gates."""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.test = (ROOT / ".github/workflows/test.yml").read_text()

    def job(self, name):
        match = re.search(
            rf"^  {name}:\n(.*?)(?=^  [\w-]+:|\Z)", self.test, re.MULTILINE | re.DOTALL
        )
        self.assertIsNotNone(match, name)
        return match.group(1)

    def test_preparation_is_shared_and_runs_independently(self):
        for name in ("swift-inputs", "media-inputs"):
            job = self.job(name)
            self.assertNotIn("    needs:", job)
            self.assertIn("actions/cache@", job)
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

    def test_native_and_download_caches_do_not_restore_different_input_keys(self):
        for name in ("swift-inputs", "media-inputs"):
            job = self.job(name)
            self.assertNotIn("restore-keys:", job)
            self.assertIn("steps.environment.outputs.environment", job)
        self.assertIn("config/media-tools.json", self.job("media-inputs"))
        self.assertIn("rust-toolchain.toml", self.job("swift-inputs"))

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
