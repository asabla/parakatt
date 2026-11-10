"""Run against generated bindings; model inference is opt-in via environment paths."""

import os
import tempfile
import unittest
from pathlib import Path

from parakatt_linux.backend import (
    RATE,
    Backend,
    Importer,
    Paths,
    Recording,
    decode_samples,
    run_tool,
)

NATIVE = (Path(__file__).parents[1] / "parakatt_linux/_native/parakatt_core.py").exists()
MODELS = os.environ.get("PARAKATT_TEST_MODELS")
AUDIO = os.environ.get("PARAKATT_TEST_AUDIO")


@unittest.skipUnless(NATIVE, "Build Python bindings with make linux-native")
class NativeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.backend = Backend(Paths.discover(MODELS, self.directory.name))

    def test_shared_settings_profiles_and_history_survive_restart(self):
        core = self.backend.engine
        core.set_active_mode("clean")
        core.set_chunk_duration(20)
        core.save_profile("linux-test")
        core.set_active_mode("dictation")
        core.load_profile("linux-test")
        self.assertEqual(core.get_active_mode(), "clean")
        other = Backend(self.backend.paths)
        self.assertEqual(other.engine.get_chunk_duration(), 20)
        self.assertEqual(other.engine.get_active_mode(), "clean")
        self.assertEqual(other.history(), [])

    @unittest.skipUnless(MODELS and AUDIO, "Set PARAKATT_TEST_MODELS and PARAKATT_TEST_AUDIO")
    def test_real_media_import_recognition_edit_undo_and_subtitle_timestamps(self):
        core = self.backend.engine
        job = core.create_import_job(
            "file", str(Path(AUDIO).resolve()), "Linux native test", "dictation"
        )
        events = []
        importer = Importer(self.backend, job, lambda kind, value: events.append((kind, value)))
        importer.start()
        importer.thread.join(120)
        self.assertFalse(importer.thread.is_alive())
        self.assertEqual(core.get_import_job(job.id).state, "completed", events)
        row = core.get_transcription(job.id)
        self.assertTrue(row.text.strip())
        self.assertTrue(core.get_transcription_segments(job.id))
        core.edit_transcription(job.id, "Edited on Linux")
        self.assertEqual(core.get_transcription(job.id).text, "Edited on Linux")
        core.undo_transcription_edit(job.id)
        self.assertEqual(core.get_transcription(job.id).text, row.text)

    @unittest.skipUnless(MODELS and AUDIO, "Set PARAKATT_TEST_MODELS and PARAKATT_TEST_AUDIO")
    def test_recording_lifecycle_saves_history_and_recovery_checkpoints(self):
        self.backend.engine.set_recovery_audio(True)
        self.backend.engine.set_streaming_preview_enabled(False)
        samples = decode_samples(
            run_tool(
                [
                    "ffmpeg",
                    "-nostdin",
                    "-v",
                    "error",
                    "-i",
                    AUDIO,
                    "-ac",
                    "1",
                    "-ar",
                    str(RATE),
                    "-f",
                    "f32le",
                    "pipe:1",
                ]
            )
        )
        events = []

        class FixtureRecording(Recording):
            def _capture(inner, device, kind):
                for start in range(0, len(samples), RATE):
                    self.backend.engine.append_capture_audio(
                        inner.id, kind, samples[start : start + RATE]
                    )
                inner.chunks.put((kind, 0, samples))

        recording = FixtureRecording(
            self.backend, False, "dictation", lambda kind, value: events.append((kind, value))
        )
        recording.start()
        recording.thread.join(120)
        self.assertFalse(recording.thread.is_alive())
        self.assertFalse(self.backend.capture_active.is_set())
        self.assertFalse([v for k, v in events if k == "error"], events)
        self.assertTrue(self.backend.engine.get_transcription(recording.id).text)
        self.assertEqual(self.backend.engine.list_recording_drafts(), [])


if __name__ == "__main__":
    unittest.main()
