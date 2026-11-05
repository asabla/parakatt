"""Do not promote partial, stale, or differently versioned build environments."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from media_build_environment import prepare_build_environment


class EnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.build = Path(self.directory.name)
        self.calls = []
        self.fail_bootstrap = False

        def run(command, **kwargs):
            self.calls.append(command)
            if "venv" in command:
                environment = Path(command[-1])
                (environment / "bin").mkdir(parents=True, exist_ok=True)
                for tool in ("python", "meson", "ninja"):
                    (environment / "bin" / tool).touch()
            if "ensurepip" in command and self.fail_bootstrap:
                raise subprocess.CalledProcessError(1, command)
            return subprocess.CompletedProcess(command, 0)

        self.run = self.enterContext(
            patch("media_build_environment.subprocess.run", side_effect=run)
        )

    def test_complete_environment_is_verified_before_reuse(self):
        environment = prepare_build_environment(self.build)
        self.assertEqual(environment.parent, self.build)
        self.calls.clear()
        self.assertEqual(prepare_build_environment(self.build), environment)
        self.assertEqual(len(self.calls), 1)
        self.assertIn("importlib.metadata", self.calls[0][2])

    def test_failed_bootstrap_has_no_success_marker_and_retries_cleanly(self):
        self.fail_bootstrap = True
        with self.assertRaises(subprocess.CalledProcessError):
            prepare_build_environment(self.build)
        self.assertEqual(list(self.build.glob("*/parakatt-build-environment.json")), [])
        self.fail_bootstrap = False
        environment = prepare_build_environment(self.build)
        self.assertTrue((environment / "parakatt-build-environment.json").is_file())
        self.assertTrue(
            all(
                "--clear" in command and "--without-pip" in command
                for command in self.calls
                if "venv" in command
            )
        )

    def test_changed_interpreter_does_not_reuse_the_previous_environment(self):
        first = prepare_build_environment(self.build)
        with patch("media_build_environment.sys.executable", "/different/python"):
            second = prepare_build_environment(self.build)
        self.assertNotEqual(first, second)
        self.assertTrue(first.is_dir())
        self.assertTrue(second.is_dir())

    def test_corrupt_marker_is_not_accepted(self):
        environment = prepare_build_environment(self.build)
        (environment / "parakatt-build-environment.json").write_text("incomplete JSON")
        self.calls.clear()
        prepare_build_environment(self.build)
        self.assertIn("venv", self.calls[0])
        self.assertIsInstance(
            json.loads((environment / "parakatt-build-environment.json").read_text()), dict
        )


if __name__ == "__main__":
    unittest.main()
