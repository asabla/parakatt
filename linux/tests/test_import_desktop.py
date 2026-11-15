"""Desktop import interactions, including canceled and stale requests."""

import os
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

from parakatt_linux.authentication import Account, DevicePrompt
from parakatt_linux.backend import Backend, Paths
from parakatt_linux.connections import Connection
from parakatt_linux.providers import MeetingSource, TranscriptSource
from parakatt_linux.transcript_service import TranscriptService

VTT = "WEBVTT\n\n00:00:00.000 --> 00:00:02.000\n<v Sam>Review the contract.</v>\n"


@unittest.skipUnless(os.environ.get("PARAKATT_TEST_QT"), "Set PARAKATT_TEST_QT=1")
class ImportDesktopTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from PySide6.QtWidgets import QApplication

        cls.app = QApplication.instance() or QApplication([])

    def setUp(self):
        from parakatt_linux.app import Window
        from parakatt_linux.transcript_dialog import TranscriptImportDialog

        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.backend = Backend(Paths.discover(data=self.directory.name))
        self.window = Window(self.backend)
        self.dialog = TranscriptImportDialog(self.backend, self.window)
        self.dialog.show()
        self.flush()
        self.addCleanup(self.close)

    def flush(self):
        for _ in range(4):
            self.window.pool.waitForDone()
            self.app.processEvents()

    def close(self):
        self.dialog.reject()
        self.window.timer.stop()
        self.window.pool.waitForDone()
        self.window.quitting = True
        self.window.close()

    def preview(self, title="Review"):
        return TranscriptService(self.backend).prepare("teams", title, VTT)

    def test_file_preview_requires_confirmation_and_cancel_keeps_history_empty(self):
        source = Path(self.directory.name) / "meeting.vtt"
        source.write_text(VTT)
        with patch(
            "parakatt_linux.transcript_dialog.QFileDialog.getOpenFileName",
            return_value=(str(source), ""),
        ):
            self.dialog.open_file()
        self.flush()
        self.assertEqual(self.backend.history(), [])
        self.assertTrue(self.dialog.import_button.isEnabled())
        self.assertEqual(self.dialog.table.model().rowCount(), 1)
        self.dialog.reject()
        self.assertEqual(self.backend.history(), [])

    def test_teams_account_and_transcript_selection_uses_explicit_choices(self):
        connection = Connection("teams", "teams", "Work", client_id="public-id")
        service = self.dialog.service
        prepared = self.preview()
        with (
            patch.object(
                service, "accounts", return_value=[Account("one", "One"), Account("two", "Two")]
            ),
            patch.object(
                service,
                "teams_sources",
                return_value=(
                    MeetingSource("M", "Review"),
                    [TranscriptSource("T1", "First"), TranscriptSource("T2", "Second")],
                ),
            ) as find,
            patch.object(service, "from_teams", return_value=prepared) as load,
        ):
            self.dialog.connections = [connection]
            self.dialog.refresh_connections(connection.id)
            self.dialog.source_type.setCurrentIndex(1)
            self.flush()
            self.assertIsNone(self.dialog.accounts.currentData())
            self.dialog.accounts.setCurrentIndex(2)
            self.dialog.meeting_reference.setText("M")
            self.dialog.load_teams_sources()
            self.flush()
            self.assertEqual(find.call_args.args[1], "two")
            self.assertEqual(self.dialog.teams_sources.count(), 2)
            self.dialog.teams_sources.setCurrentIndex(1)
            self.dialog.preview_teams()
            self.flush()
            self.assertEqual(load.call_args.args[1], "two")
            self.assertEqual(load.call_args.args[3].id, "T2")
            self.assertEqual(self.backend.history(), [])
            self.dialog.commit()
            self.flush()
            self.assertEqual(len(self.backend.history()), 1)
            self.assertFalse(self.dialog.isVisible())

    def test_canceled_request_cannot_restore_a_stale_preview(self):
        old, new = self.preview("Old"), self.preview("New")
        started = threading.Event()
        seen = []

        def delayed(cancel, _generation):
            seen.append(cancel)
            started.set()
            cancel.wait(2)
            return old

        self.dialog.run("prepared", delayed)
        self.assertTrue(started.wait(2))
        self.dialog.cancel_request_now()
        self.dialog.run("prepared", lambda cancel, generation: new)
        self.flush()
        self.assertTrue(seen[0].is_set())
        self.assertEqual(self.dialog.prepared.title, "New")
        self.assertEqual(self.backend.history(), [])

    def test_sign_in_prompt_can_open_browser_while_other_controls_are_disabled(self):
        self.dialog.source_type.setCurrentIndex(1)
        self.dialog.operation = "accounts"
        self.dialog.set_busy(True)
        self.dialog.on_result(
            self.dialog.generation,
            "device_prompt",
            DevicePrompt("TEST", "https://microsoft.com/devicelogin", "Enter TEST"),
        )
        self.assertTrue(self.dialog.open_sign_in.isEnabled())
        self.assertFalse(self.dialog.meeting_reference.isEnabled())
        with patch("parakatt_linux.transcript_dialog.QDesktopServices.openUrl") as open_url:
            self.dialog.open_device_sign_in()
        self.assertEqual(open_url.call_args.args[0].toString(), "https://microsoft.com/devicelogin")
        self.dialog.cancel_request_now()

    def test_import_in_progress_cannot_be_canceled_after_confirmation(self):
        self.dialog.show_preview(self.preview())
        self.dialog.operation = "committed"
        self.dialog.set_busy(True)
        self.dialog.reject()
        self.assertTrue(self.dialog.isVisible())
        self.assertFalse(self.dialog.close_button.isEnabled())
        self.dialog.set_busy(False)

    def test_editors_validate_rules_and_keep_builtin_mode_names_stable(self):
        from parakatt_linux.editors import ModeEditor, RuleEditor
        from parakatt_linux.settings import Settings

        settings = Settings(self.backend, self.window)
        editor = RuleEditor(settings)
        editor.pattern.setText("re:[")
        editor.validate()
        self.assertEqual(editor.result(), 0)
        self.assertTrue(editor.error.text())
        editor.pattern.setText("para cat")
        editor.replacement.setText("Parakatt")
        editor.validate()
        self.assertEqual(editor.result(), 1)
        mode = ModeEditor(settings, "dictation")
        self.assertTrue(mode.name.isReadOnly())
        duplicate = ModeEditor(settings)
        duplicate.name.setText("dictation")
        duplicate.validate()
        self.assertEqual(duplicate.result(), 0)
        self.assertTrue(duplicate.error.text())

    def test_utility_panels_disable_actions_without_selection(self):
        self.assertFalse(self.window.download_button.isEnabled())
        self.assertFalse(self.window.recover_text_button.isEnabled())
        self.assertFalse(self.window.discard_draft_button.isEnabled())
        self.assertEqual(
            [self.window.tools_tabs.tabText(i) for i in range(3)],
            ["Backups && profiles", "Recovery", "Diagnostics"],
        )
        self.window.models.setCurrentRow(0)
        self.assertTrue(self.window.download_button.isEnabled())
        self.assertFalse(self.window.diagnostic_details.isChecked())


if __name__ == "__main__":
    unittest.main()
