import json
import tempfile
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from parakatt_linux.backend import Importer, Recording
from parakatt_linux.preferences import load_preferences, save_preferences


class ReliabilityTests(unittest.TestCase):
    def test_corrupt_settings_are_preserved_and_defaults_allow_startup(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "linux.json"
            path.write_text("{bad json")
            preferences, warnings = load_preferences(path)
            self.assertTrue(preferences["copy"])
            self.assertTrue(warnings)
            backups = list(path.parent.glob("linux.invalid-*.json"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_text(), "{bad json")

    def test_wrong_types_recover_but_failed_save_keeps_original(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "linux.json"
            path.write_text(json.dumps({"copy": "false"}))
            self.assertTrue(load_preferences(path)[1])
            save_preferences(path, {"copy": False})
            with (
                patch("parakatt_linux.preferences.os.replace", side_effect=OSError("disk full")),
                self.assertRaises(OSError),
            ):
                save_preferences(path, {"copy": True})
            self.assertFalse(load_preferences(path)[0]["copy"])
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertFalse(list(path.parent.glob("*.tmp")))

    def test_import_completion_survives_failed_pause_persistence(self):
        def failure(*_):
            raise RuntimeError("simulated disk full")

        events = []
        backend = SimpleNamespace(
            engine=SimpleNamespace(set_import_state=failure), load_model=lambda: None
        )
        job = SimpleNamespace(
            id="job", kind="file", input="/missing", attachment=SimpleNamespace(path="")
        )
        worker = Importer(backend, job, lambda *event: events.append(event))
        worker.pause_event.set()
        worker._run()
        self.assertTrue(worker.finished.is_set())
        self.assertEqual(sum(event[0] == "import_done" for event in events), 1)
        self.assertTrue(any(event[0] == "error" for event in events))

    def test_recording_completion_survives_cleanup_failure(self):
        def failure(*_):
            raise RuntimeError("model unavailable")

        events = []
        backend = SimpleNamespace(
            engine=SimpleNamespace(), load_model=failure, capture_active=threading.Event()
        )
        worker = Recording(backend, False, "dictation", lambda *event: events.append(event))
        backend.capture_active.set()
        worker.stop = failure
        worker._run()
        self.assertFalse(backend.capture_active.is_set())
        self.assertEqual(sum(event[0] == "recording_done" for event in events), 1)


if __name__ == "__main__":
    unittest.main()
