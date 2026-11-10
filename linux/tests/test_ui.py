import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


@unittest.skipUnless(
    os.environ.get("PARAKATT_TEST_QT"), "Set PARAKATT_TEST_QT=1 for desktop UI checks"
)
class DesktopTests(unittest.TestCase):
    def test_transcript_import_speaker_correction_and_minutes_export(self):
        from parakatt_linux.app import Window
        from parakatt_linux.backend import Backend, Paths

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "meeting.vtt"
            source.write_text(
                "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n<v Sam>Review the contract.</v>\n"
            )
            backend = Backend(Paths.discover(data=root / "app"))
            window = Window(backend)
            with patch(
                "parakatt_linux.app.QFileDialog.getOpenFileName",
                return_value=(str(source), "Teams WebVTT (*.vtt)"),
            ):
                window.import_transcript()
            for _ in range(3):
                window.pool.waitForDone()
                self.app.processEvents()
            window.history.setCurrentRow(0)
            self.assertIsNotNone(window.selected)
            with patch(
                "parakatt_linux.app.QInputDialog.getText",
                side_effect=[("Sam", True), ("Samantha", True)],
            ):
                window.correct_speaker()
            self.assertIn("Samantha:", window.transcript.toPlainText())
            backend.engine.add_meeting_action(window.selected, "Review contract", None, None, 0)
            exported = root / "minutes.md"
            with patch(
                "parakatt_linux.app.QFileDialog.getSaveFileName",
                return_value=(str(exported), "Markdown (*.md)"),
            ):
                window.export()
            self.assertIn("- [ ] Review contract", exported.read_text())
            self.assertIn("Samantha:", exported.read_text())
            window.timer.stop()
            window.pool.waitForDone()
            window.quitting = True
            window.close()

    @classmethod
    def setUpClass(cls):
        from PySide6.QtWidgets import QApplication

        cls.app = QApplication.instance() or QApplication([])

    def test_window_settings_clipboard_and_history_edit(self):
        from PySide6.QtCore import Qt

        from parakatt_linux.app import Settings, Window
        from parakatt_linux.backend import Backend, Paths

        with tempfile.TemporaryDirectory() as directory:
            backend = Backend(Paths.discover(data=directory))
            window = Window(backend)
            window.pool.waitForDone()
            self.app.processEvents()
            self.assertIn("History", [window.tabs.tabText(i) for i in range(window.tabs.count())])
            dialog = Settings(backend, window)
            dialog.chunk.setValue(20)
            dialog.copy.setChecked(False)
            dialog.add_rule(
                backend.api.ReplacementRule(
                    pattern="para cat",
                    replacement="Parakatt",
                    context_type="always",
                    context_value=None,
                    enabled=True,
                )
            )
            dialog.add_mode(
                backend.api.ModeConfig(
                    name="Linux custom",
                    stt_provider=None,
                    llm_provider=None,
                    system_prompt="Keep names intact.",
                    dictionary_enabled=True,
                )
            )
            dialog.save()
            self.assertEqual(backend.engine.get_chunk_duration(), 20)
            self.assertFalse(backend.preferences["copy"])
            self.assertEqual(backend.engine.get_dictionary_rules()[0].replacement, "Parakatt")
            self.assertIn("Linux custom", [mode.name for mode in backend.engine.list_modes()])
            self.app.clipboard().setText("Linux clipboard check")
            self.assertEqual(self.app.clipboard().text(), "Linux clipboard check")
            job = backend.engine.create_import_job("file", "/test.mkv", "Test history", "dictation")
            window.populate_history(backend.history())
            window.history.setCurrentRow(0)
            self.assertEqual(window.selected, job.id)
            self.assertEqual(window.history.item(0).data(Qt.ItemDataRole.UserRole), job.id)
            window.show()
            self.app.processEvents()
            screenshot = os.environ.get("PARAKATT_TEST_SCREENSHOT")
            if screenshot:
                Path(screenshot).parent.mkdir(parents=True, exist_ok=True)
                self.assertTrue(window.grab().save(screenshot))
            window.timer.stop()
            window.pool.waitForDone()
            window.player.stop()
            window.quitting = True
            window.close()

    @unittest.skipUnless(
        os.environ.get("PARAKATT_TEST_VIDEO"),
        "Set PARAKATT_TEST_VIDEO for original-source playback checks",
    )
    def test_media_player_decodes_and_seeks_original_video(self):
        from PySide6.QtCore import QEventLoop, QTimer, QUrl

        from parakatt_linux.app import Window
        from parakatt_linux.backend import Backend, Paths, fingerprint

        source = Path(os.environ["PARAKATT_TEST_VIDEO"]).resolve()
        before = fingerprint(source)
        with tempfile.TemporaryDirectory() as directory:
            window = Window(Backend(Paths.discover(data=directory)))
            frames = []
            loop = QEventLoop()
            window.video.videoSink().videoFrameChanged.connect(
                lambda frame: (
                    (frames.append(frame.isValid()), loop.quit()) if frame.isValid() else None
                )
            )
            window.player.setSource(QUrl.fromLocalFile(str(source)))
            window.player.play()
            QTimer.singleShot(10000, loop.quit)
            loop.exec()
            self.assertTrue(frames, window.player.errorString())
            window.player.setPosition(5000)
            frames.clear()
            QTimer.singleShot(10000, loop.quit)
            loop.exec()
            self.assertTrue(frames)
            self.assertGreaterEqual(window.player.position(), 4500)
            window.timer.stop()
            window.pool.waitForDone()
            window.player.stop()
            window.quitting = True
            window.close()
        self.assertEqual(fingerprint(source), before)


if __name__ == "__main__":
    unittest.main()
