"""Behavioral checks for the macOS-aligned Linux desktop workflows."""

import os
import struct
import tempfile
import threading
import unittest
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from parakatt_linux.backend import Backend, Paths, Recording


class CaptureControlTests(unittest.TestCase):
    def test_pause_excludes_audio_from_recognition_recovery_and_meter(self):
        checkpoints, events = [], []
        core = SimpleNamespace(
            get_chunk_duration=lambda: 10,
            append_capture_audio=lambda _id, _kind, samples: checkpoints.extend(samples),
        )
        backend = SimpleNamespace(
            engine=core, api=SimpleNamespace(ChunkSource=SimpleNamespace(MIC="mic"))
        )
        recording = Recording(backend, False, "dictation", lambda *event: events.append(event))
        recording.ready.set()
        reads = iter([(False, 0.1), (True, 0.8), (True, 0.9), (False, 0.2)])

        def read(size=None):
            if size is None:
                return b""
            value = next(reads, None)
            if value is None:
                recording.stop_event.set()
                return b""
            paused, sample = value
            recording.set_paused(paused)
            return struct.pack("<f", sample)

        process = MagicMock()
        process.stdout.read.side_effect = read
        process.poll.return_value = 0
        with patch("parakatt_linux.backend.subprocess.Popen", return_value=process):
            recording._capture("default", "mic")
        self.assertIsNone(recording.error)
        self.assertEqual(len(checkpoints), 2)
        self.assertAlmostEqual(checkpoints[0], 0.1)
        self.assertAlmostEqual(checkpoints[1], 0.2)
        _kind, _index, samples = recording.chunks.get_nowait()
        self.assertEqual(samples, checkpoints)
        self.assertEqual(sum(key == "audio_level" for key, _ in events), 2)

    def test_stop_during_process_start_still_terminates_capture(self):
        backend = SimpleNamespace(engine=SimpleNamespace(get_chunk_duration=lambda: 10))
        recording = Recording(backend, False, "dictation", lambda *_: None)
        process = MagicMock()
        alive = [True]
        process.poll.side_effect = lambda: None if alive[0] else 0
        process.send_signal.side_effect = lambda _signal: alive.__setitem__(0, False)
        process.stdout.read.return_value = b""

        def spawn(*_args, **_kwargs):
            recording.stop()
            return process

        with (
            patch("parakatt_linux.backend.subprocess.Popen", side_effect=spawn),
            patch("parakatt_linux.backend.threading.Timer"),
        ):
            recording._capture("default", "mic")
        process.send_signal.assert_called_once()
        self.assertIsNone(recording.error)
        self.assertFalse(alive[0])

    def test_recording_clock_excludes_pauses_and_freezes_on_stop(self):
        recording = Recording(SimpleNamespace(), False, "dictation", lambda *_: None)
        recording.started_at = 10.0
        recording.ready.set()
        with patch("parakatt_linux.backend.time.monotonic", return_value=15.0):
            recording.set_paused(True)
        with patch("parakatt_linux.backend.time.monotonic", return_value=25.0):
            self.assertEqual(recording.elapsed_seconds(), 5.0)
            recording.set_paused(False)
        with patch("parakatt_linux.backend.time.monotonic", return_value=28.0):
            recording.stop()
        with patch("parakatt_linux.backend.time.monotonic", return_value=50.0):
            self.assertEqual(recording.elapsed_seconds(), 8.0)

    def test_discard_cancels_session_and_removes_recovery_without_saving(self):
        core = MagicMock()
        core.get_streaming_preview_enabled.return_value = False
        backend = SimpleNamespace(
            engine=core,
            preferences={},
            api=SimpleNamespace(ChunkSource=SimpleNamespace(MIC="mic")),
            load_model=lambda: None,
            capture_active=threading.Event(),
        )
        events = []
        recording = Recording(backend, False, "dictation", lambda *event: events.append(event))
        recording._capture = lambda *_: recording.discard()
        recording._run()
        core.finish_session.assert_not_called()
        core.cancel_session.assert_called_once_with(recording.id)
        core.discard_recording_draft.assert_called_once_with(recording.id)
        self.assertEqual([key for key, _ in events].count("recording_done"), 1)
        self.assertNotIn("recorded", [key for key, _ in events])


@unittest.skipUnless(os.environ.get("PARAKATT_TEST_QT"), "Set PARAKATT_TEST_QT=1")
class DesktopWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from PySide6.QtWidgets import QApplication

        cls.app = QApplication.instance() or QApplication([])

    def setUp(self):
        from parakatt_linux.app import Window

        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.backend = Backend(Paths.discover(data=self.directory.name))
        self.core = self.backend.engine
        self.window = Window(self.backend)
        self.flush()
        self.addCleanup(self.close_window)

    def close_window(self):
        self.window.timer.stop()
        self.window.search_timer.stop()
        self.window.pool.waitForDone()
        self.window.player.stop()
        self.window.quitting = True
        self.window.close()

    def flush(self):
        for _ in range(3):
            self.window.pool.waitForDone()
            self.app.processEvents()

    def import_meeting(self):
        return self.core.import_transcript(
            self.backend.api.TranscriptImportRequest(
                provider=self.backend.api.TranscriptProvider.TEAMS,
                source_id=None,
                title="Design review",
                content="WEBVTT\n\n00:00:00.000 --> 00:00:04.000\n<v Alex>Review the plan and review the schedule.</v>\n\n00:00:04.000 --> 00:00:09.000\n<v Morgan>Keep the meeting notes.</v>\n",
            )
        )

    def save_note(self, ident, source="push_to_talk"):
        self.core.save_transcription(
            self.backend.api.StoredTranscription(
                id=ident,
                created_at="2026-11-12T10:00:00Z",
                duration_secs=12.0,
                source=source,
                mode="dictation",
                audio_source=None,
                app_context=None,
                title=ident,
                text="A short office note.",
            )
        )

    def test_category_filters_include_provider_transcripts_and_reset_empty_selection(self):
        meeting = self.import_meeting()
        self.save_note("note")
        self.save_note("video", "import")
        self.window.filters.setCurrentIndex(2)
        self.flush()
        self.assertEqual(self.window.history.count(), 1)
        self.window.history.setCurrentRow(0)
        self.assertEqual(self.window.selected, meeting.id)
        self.assertEqual(self.window.detail_stack.currentIndex(), 1)
        self.window.filters.setCurrentIndex(1)
        self.flush()
        self.assertEqual(self.window.history.count(), 1)
        self.assertIsNone(self.window.selected)
        self.assertEqual(self.window.detail_stack.currentIndex(), 0)
        self.window.filters.setCurrentIndex(3)
        self.flush()
        self.assertEqual(self.window.history.item(0).text(), "video")
        self.window.search.setText("nonexistent")
        self.window.refresh_history()
        self.flush()
        self.assertEqual(self.window.history.count(), 0)
        self.assertFalse(self.window.history_empty.isHidden())

    def test_filtered_pagination_does_not_skip_records(self):
        for index in range(105):
            self.save_note(f"note-{index:03}")
        self.save_note("video", "import")
        first = self.backend.history(category="Notes")
        second = self.backend.history(offset=100, category="Notes")
        self.assertEqual((len(first), len(second)), (100, 5))
        self.assertFalse({row.id for row in first} & {row.id for row in second})
        self.assertEqual(len(self.backend.history(category="Videos")), 1)

    def test_find_timeline_navigation_and_explicit_edit_save(self):
        self.import_meeting()
        self.window.refresh_history()
        self.flush()
        self.window.history.setCurrentRow(0)
        self.assertTrue(self.window.transcript.isReadOnly())
        self.window.find.setText("review")
        self.assertEqual(len(self.window.find_matches), 2)
        self.window.next_match(1)
        self.assertEqual(self.window.transcript.textCursor().selectedText(), "Review")
        self.window.next_match(1)
        self.assertEqual(self.window.transcript.textCursor().selectedText(), "review")
        self.window.history_view.setCurrentIndex(1)
        self.assertEqual(self.window.transcript_stack.currentIndex(), 1)
        self.assertEqual(len(self.window.find_matches), 1)
        self.window.next_match(1)
        self.assertEqual(self.window.segments.currentRow(), 0)
        self.window.edit_transcript()
        self.assertFalse(self.window.transcript.isReadOnly())
        self.assertEqual(self.window.history_view.currentIndex(), 0)
        self.window.transcript.setPlainText("A corrected plan.")
        self.window.refresh_history()
        self.flush()
        self.assertEqual(self.window.transcript.toPlainText(), "A corrected plan.")
        selected = self.window.selected
        self.window.save_edit()
        self.flush()
        self.assertEqual(self.core.get_transcription(selected).text, "A corrected plan.")
        self.assertTrue(self.window.transcript.isReadOnly())
        self.window.original.setChecked(True)
        self.assertIn("Review the plan", self.window.transcript.toPlainText())

    def test_settings_tabs_and_unavailable_devices_survive_save(self):
        from parakatt_linux.app import Settings

        self.backend.preferences["microphone"] = "unavailable-device"
        with patch("parakatt_linux.settings.audio_sources", return_value=[]):
            dialog = Settings(self.backend, self.window)
        self.assertEqual(
            [dialog.tabs.tabText(index) for index in range(dialog.tabs.count())],
            ["Dashboard", "General", "Models", "LLM", "Dictionary", "Statistics"],
        )
        self.assertEqual(dialog.microphone.currentData(), "unavailable-device")
        dialog.overlay.setChecked(False)
        dialog.save()
        self.assertFalse(self.core.get_show_overlay())
        self.assertEqual(self.backend.preferences["microphone"], "unavailable-device")

    def test_auxiliary_windows_and_timeline_order(self):
        from parakatt_linux.desktop_widgets import add_segment

        self.window.show()
        self.app.processEvents()
        self.window.toggle_sidebar()
        self.assertTrue(self.window.history_pane.isHidden())
        self.window.toggle_sidebar()
        self.assertFalse(self.window.history_pane.isHidden())
        self.window.open_panel("imports")
        self.assertTrue(self.window.panel_windows["imports"].isVisible())
        self.window.panel_windows["imports"].close()
        timeline = self.window.live_window.timeline
        add_segment(timeline, 30.0, "Later system speech")
        add_segment(timeline, 5.0, "Earlier microphone speech")
        self.assertEqual(timeline.item(0).text(), "Earlier microphone speech")


if __name__ == "__main__":
    unittest.main()
