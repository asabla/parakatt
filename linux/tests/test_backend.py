import json
import os
import queue
import struct
import tempfile
import threading
import unittest
from array import array
from dataclasses import dataclass
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from parakatt_linux.backend import (
    RATE,
    Importer,
    Paths,
    Recording,
    decode_samples,
    default_monitor,
    diagnostics,
    fingerprint,
    probe,
    subtitle_text,
)


class PlatformTests(unittest.TestCase):
    def test_xdg_paths_and_isolated_override(self):
        with patch.dict(
            os.environ, {"XDG_DATA_HOME": "/tmp/data", "XDG_CONFIG_HOME": "/tmp/config"}
        ):
            paths = Paths.discover()
            self.assertEqual(paths.models, Path("/tmp/data/parakatt/models"))
            self.assertEqual(paths.config, Path("/tmp/config/parakatt"))
            paths = Paths.discover("/models", "/isolated")
            self.assertEqual(paths.config, Path("/isolated/config"))
            self.assertEqual(paths.models, Path("/models"))

    def test_pcm_endianness_and_partial_sample(self):
        self.assertEqual(decode_samples(struct.pack("<fff", -1, 0, 0.5)), [-1, 0, 0.5])
        with self.assertRaisesRegex(RuntimeError, "partial"):
            decode_samples(b"123")

    def test_subtitle_timing_rollover_and_speaker(self):
        segment = SimpleNamespace(start_secs=59.9999, end_secs=3600.25, text="Hello", speaker="Me")
        self.assertIn("00:01:00,000 --> 01:00:00,250\nMe: Hello", subtitle_text([segment]))
        text = subtitle_text([segment], True)
        self.assertTrue(text.startswith("WEBVTT\n\n"))
        self.assertIn("00:01:00.000", text)

    def test_monitor_discovery_requires_existing_source(self):
        with patch("parakatt_linux.backend.run_tool", return_value=b"speaker\n"):
            with patch(
                "parakatt_linux.backend.audio_sources", return_value=[("speaker.monitor", "Output")]
            ):
                self.assertEqual(default_monitor(), "speaker.monitor")
            with (
                patch("parakatt_linux.backend.audio_sources", return_value=[]),
                self.assertRaisesRegex(RuntimeError, "No monitor"),
            ):
                default_monitor()

    def test_probe_rejects_no_audio_and_unbounded_duration(self):
        for info in (
            {"streams": [], "format": {"duration": "2"}},
            {"streams": [{"codec_type": "audio"}], "format": {"duration": "inf"}},
        ):
            with (
                patch("parakatt_linux.backend.run_tool", return_value=json.dumps(info).encode()),
                self.assertRaises(RuntimeError),
            ):
                probe("source.mkv")

    def test_fingerprint_detects_source_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "video"
            path.write_bytes(b"original")
            first = fingerprint(path)
            path.write_bytes(b"changed")
            self.assertNotEqual(first, fingerprint(path))

    def test_queue_overflow_marks_audio_gap(self):
        gaps = []
        backend = SimpleNamespace(
            engine=SimpleNamespace(mark_capture_gap=lambda *args: gaps.append(args))
        )
        recording = Recording(backend, False, "dictation", lambda *_: None)
        recording.chunks = queue.Queue(maxsize=1)
        recording._enqueue("mic", 0, struct.pack("<f", 0.1))
        with self.assertRaisesRegex(RuntimeError, "cannot keep up"):
            recording._enqueue("mic", 1, struct.pack("<f", 0.1))
        self.assertEqual(gaps, [(recording.id, True)])

    def test_diagnostics_does_not_need_native_model(self):
        self.assertIn("ffmpeg", diagnostics()["tools"])


@dataclass
class Attachment:
    path: str = ""
    bookmark: bytes = b""
    fingerprint: str = ""
    review_path: str = ""
    audio_track: int = 0
    duration_secs: float = 0


class FakeCore:
    def __init__(self, job):
        self.job, self.offsets = job, []

    def attach_import_media(self, ident, attachment):
        if self.job.next_chunk and self.job.attachment.fingerprint != attachment.fingerprint:
            raise RuntimeError("The source changed")
        self.job.attachment = attachment
        return self.job

    def set_import_state(self, ident, state, message):
        self.job.state, self.job.message = state, message
        return self.job

    def process_import_chunk(self, ident, samples, offset):
        self.offsets.append(offset)
        self.job.next_chunk += 1
        self.job.processed_until = offset + len(samples) / RATE
        return self.job

    def process_import_text(self, ident):
        pass


class ImportTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "video with spaces.mkv"
        self.path.write_bytes(b"fixture")
        self.job = SimpleNamespace(
            id="job",
            input=str(self.path),
            kind="file",
            state="queued",
            message="",
            attachment=Attachment(),
            next_chunk=0,
            processed_until=0,
        )
        self.core = FakeCore(self.job)
        self.backend = SimpleNamespace(
            engine=self.core,
            api=SimpleNamespace(MediaAttachment=Attachment),
            load_model=lambda: None,
            inference=threading.RLock(),
            capture_active=threading.Event(),
            paths=SimpleNamespace(data=Path(self.directory.name)),
        )

    def decoder(self, arguments):
        offset = float(arguments[arguments.index("-ss") + 1])
        duration = float(arguments[arguments.index("-t") + 1])
        self.assertEqual(arguments[arguments.index("-i") + 1], str(self.path))
        self.assertEqual(offset, max(0, self.job.processed_until - 2))
        return array("f", [0.1] * round(duration * RATE)).tobytes()

    def test_pause_resume_uses_two_second_overlap_without_replaying_committed_chunks(self):
        events = []
        importer = Importer(
            self.backend,
            self.job,
            lambda key, value: (
                events.append(key),
                importer.pause() if key == "import_progress" else None,
            ),
        )
        with (
            patch("parakatt_linux.backend.probe", return_value=(65.0, [{}])),
            patch("parakatt_linux.backend.run_tool", side_effect=self.decoder),
        ):
            importer._run()
            self.assertEqual(self.job.state, "paused")
            self.assertEqual(self.core.offsets, [0])
            resumed = Importer(self.backend, self.job, lambda *_: None)
            resumed._run()
        self.assertEqual(self.core.offsets, [0, 28, 56])
        self.assertEqual(self.job.processed_until, 65)
        self.assertEqual(self.job.state, "completed")
        self.assertIn("import_done", events)

    def test_resume_rejects_replaced_source(self):
        self.job.next_chunk = 1
        self.job.attachment.fingerprint = "old fingerprint"
        events = []
        with patch("parakatt_linux.backend.probe", return_value=(65.0, [{}])):
            Importer(self.backend, self.job, lambda key, value: events.append((key, value)))._run()
        self.assertEqual(self.job.state, "failed")
        self.assertEqual(self.core.offsets, [])
        self.assertIn("source changed", self.job.message)

    def test_pause_before_decode_has_no_committed_chunks(self):
        importer = Importer(self.backend, self.job, lambda *_: None)
        importer.pause()
        with patch("parakatt_linux.backend.probe") as probe_mock:
            importer._run()
        probe_mock.assert_not_called()
        self.assertEqual(self.job.state, "paused")


if __name__ == "__main__":
    unittest.main()
