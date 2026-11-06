"""Check that normal-startup verification rejects crashes and missing callbacks."""

from pathlib import Path
import plistlib
import tempfile
import unittest

from startup_check import check_normal_startup


class StartupTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.app = Path(directory.name) / "Fixture.app"
        executable = self.app / "Contents/MacOS/Parakatt"
        executable.parent.mkdir(parents=True)
        with (self.app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleShortVersionString": "1.2.3"}, stream)
        self.executable = executable

    def program(self, code):
        self.executable.write_text("#!/usr/bin/env python3\nimport os, sys, time\n" + code)
        self.executable.chmod(0o755)

    def test_normal_launch_checks_engine_and_notification_callback(self):
        self.program(
            "assert 'PARAKATT_SMOKE_TEST' not in os.environ\n"
            "assert os.environ['PARAKATT_DATA_ROOT']\n"
            "assert sys.argv[-1] == '1.2.3'\n"
            "print('[Parakatt] Engine created', flush=True)\n"
            "print('[Parakatt] Normal startup complete', flush=True)\n"
            "print('[Parakatt] Notification permission granted: 0', flush=True)\n"
            "time.sleep(60)\n"
        )
        report = check_normal_startup(self.app, timeout=2, settle_seconds=0.05)
        self.assertEqual(report, {"started": True, "mode": "normal", "notification_callback": True})

    def test_a_crash_cannot_pass_even_after_startup_messages(self):
        self.program(
            "print('[Parakatt] Engine created', flush=True)\n"
            "print('[Parakatt] Normal startup complete', flush=True)\n"
            "print('[Parakatt] Notification permission granted: 0', flush=True)\n"
            "sys.exit(5)\n"
        )
        with self.assertRaisesRegex(RuntimeError, "exited with 5"):
            check_normal_startup(self.app, timeout=2)

    def test_startup_without_a_notification_callback_does_not_pass(self):
        self.program(
            "print('[Parakatt] Engine created', flush=True)\n"
            "print('[Parakatt] Normal startup complete', flush=True)\n"
            "time.sleep(60)\n"
        )
        with self.assertRaisesRegex(RuntimeError, "did not finish"):
            check_normal_startup(self.app, timeout=0.3, settle_seconds=0)


if __name__ == "__main__":
    unittest.main()
