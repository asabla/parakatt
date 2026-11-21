"""Account lifecycle and cleanup regressions without live ChatGPT credentials."""

import os
import tempfile
import threading
import unittest
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from parakatt_linux.chatgpt import SignInRequest, account_name, account_status, cleanup_title


def account(ident="one", *, signed_in=True, plan_enabled=True, paused=False, active=True):
    return SimpleNamespace(
        id=ident,
        label=f"alex@example.test ({ident})",
        signed_in=signed_in,
        plan_enabled=plan_enabled,
        paused=paused,
        active=active,
    )


class AccountTests(unittest.TestCase):
    def test_cancel_before_begin_never_opens_a_callback(self):
        service = MagicMock()
        request = SignInRequest(service, None)
        request.cancel()
        self.assertIsNone(request.begin())
        service.begin_sign_in.assert_not_called()

    def test_cancel_while_beginning_cleans_up_late_attempt(self):
        started, release = threading.Event(), threading.Event()
        service = MagicMock()

        def begin(_):
            started.set()
            self.assertTrue(release.wait(3))
            return SimpleNamespace(id="late", authorization_url="https://auth.openai.com/test")

        service.begin_sign_in.side_effect = begin
        request = SignInRequest(service, None)
        results = []
        worker = threading.Thread(target=lambda: results.append(request.begin()))
        worker.start()
        self.assertTrue(started.wait(3))
        request.cancel()
        release.set()
        worker.join(3)
        self.assertFalse(worker.is_alive())
        self.assertEqual(results, [None])
        service.cancel_sign_in.assert_called_once_with("late")
        with self.assertRaisesRegex(RuntimeError, "cancelled"):
            request.complete()
        service.complete_sign_in.assert_not_called()

    def test_cancel_after_begin_cancels_native_callback(self):
        service = MagicMock()
        service.begin_sign_in.return_value = SimpleNamespace(id="attempt")
        request = SignInRequest(service, "one")
        request.begin()
        request.cancel()
        service.begin_sign_in.assert_called_once_with("one")
        service.cancel_sign_in.assert_called_once_with("attempt")

    def test_account_names_hide_ids_and_disambiguate_same_email(self):
        first, second = account(), account("two")
        self.assertEqual(account_name(first, [first]), "alex@example.test")
        self.assertEqual(account_name(second, [first, second]), "alex@example.test — Account 2")

    def test_status_never_claims_missing_permission_is_connected(self):
        self.assertEqual(account_status(None), "Not connected")
        self.assertEqual(account_status(account(signed_in=False)), "Not connected")
        self.assertEqual(account_status(account(plan_enabled=False)), "Permission needed")
        self.assertEqual(account_status(account(paused=True)), "Usage paused")
        self.assertEqual(account_status(account()), "Connected")
        self.assertEqual(cleanup_title("dictation"), "Off")
        self.assertEqual(cleanup_title("clean"), "Grammar + punctuation")
        self.assertEqual(cleanup_title("Office notes"), "Custom: Office notes")


@unittest.skipUnless(os.environ.get("PARAKATT_TEST_QT"), "Set PARAKATT_TEST_QT=1")
class AccountWidgetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from PySide6.QtWidgets import QApplication

        cls.app = QApplication.instance() or QApplication([])

    def setUp(self):
        from PySide6.QtCore import QThreadPool

        from parakatt_linux.chatgpt_settings import ChatGptSettings

        self.backend = MagicMock()
        self.backend.engine.get_chatgpt_account.return_value = "one"
        self.backend.engine.get_provider_settings.return_value.model = "model-a"
        self.service = MagicMock()
        self.service.list.return_value = [account()]
        self.service.models.return_value = [
            SimpleNamespace(slug="model-a", display_name="Model A"),
            SimpleNamespace(slug="model-b", display_name="Model B"),
        ]
        self.pool = QThreadPool()
        self.widget = ChatGptSettings(self.backend, self.pool, self.service)
        self.addCleanup(self.close_widget)

    def flush(self):
        for _ in range(4):
            self.pool.waitForDone(3000)
            self.app.processEvents()

    def close_widget(self):
        from PySide6.QtCore import QCoreApplication, QEvent

        self.widget.activate(False)
        self.pool.waitForDone(3000)
        self.widget.close()
        self.widget.deleteLater()
        QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)
        self.app.processEvents()

    def test_saved_model_requires_successful_discovery_and_account_permission(self):
        self.assertFalse(self.widget.valid_model())
        self.widget.activate(True)
        self.flush()
        self.assertEqual(self.widget.require_model(), "model-a")
        self.widget.models = []
        with self.assertRaises(ValueError):
            self.widget.require_model()
        self.widget.models = self.service.models.return_value
        self.widget.accounts = [account(plan_enabled=False)]
        self.assertFalse(self.widget.valid_model())

    def test_account_switch_clears_model_and_invalidates_applied_account(self):
        self.service.list.return_value = [account(), account("two", active=False)]
        self.widget.activate(True)
        self.flush()
        self.widget.account.setCurrentIndex(1)
        self.flush()
        self.service.select.assert_called_once_with("two")
        self.backend.engine.set_chatgpt_account.assert_called_once_with("two")
        self.assertIsNone(self.widget.model.currentData())
        self.assertFalse(self.widget.valid_model())

    def test_usage_pause_requires_explicit_retry_and_never_configures_api_provider(self):
        self.service.list.return_value = [account(paused=True)]
        self.widget.activate(True)
        self.flush()
        self.service.models.assert_not_called()
        self.assertEqual(self.widget.status.text(), "Usage paused")
        self.assertFalse(self.widget.test.isEnabled())
        self.service.list.return_value = [account()]
        self.widget.fetch_models(retry=True)
        self.flush()
        self.service.retry.assert_called_once_with("one")
        self.assertEqual(self.widget.status.text(), "Connected")
        self.backend.configure_llm.assert_not_called()

    def test_browser_failure_cancels_callback_and_displays_error(self):
        self.widget.active = True
        self.service.begin_sign_in.return_value = SimpleNamespace(
            id="attempt", authorization_url="https://auth.openai.com/test"
        )
        with patch("parakatt_linux.chatgpt_settings.QDesktopServices.openUrl", return_value=False):
            self.widget.start_sign_in()
            self.flush()
        self.service.cancel_sign_in.assert_called_once_with("attempt")
        self.service.complete_sign_in.assert_not_called()
        self.assertIn("Cannot open", self.widget.message.text())
        self.assertFalse(self.widget.busy)

    def test_closed_or_changed_provider_ignores_old_results(self):
        self.widget.active = True
        old = self.widget.revision
        self.widget.activate(False)
        self.widget.on_result(old, "signed_in", (account(), True))
        self.widget.on_result(old, "error_models", "old error")
        self.backend.engine.set_chatgpt_account.assert_not_called()
        self.assertNotIn("old error", self.widget.message.text())

    def test_successful_sign_in_applies_account_and_keeps_plan_confirmation_visible(self):
        self.widget.active = True
        self.service.begin_sign_in.return_value = SimpleNamespace(
            id="attempt", authorization_url="https://auth.openai.com/test"
        )
        self.service.complete_sign_in.return_value = account()
        self.service.take_plan_confirmation.return_value = True
        with patch("parakatt_linux.chatgpt_settings.QDesktopServices.openUrl", return_value=True):
            self.widget.start_sign_in()
            self.flush()
        self.service.complete_sign_in.assert_called_once_with("attempt")
        self.backend.engine.set_chatgpt_account.assert_called_once_with("one")
        self.service.take_plan_confirmation.assert_called_once_with("one")
        self.assertIn("using your ChatGPT plan", self.widget.notice.text())
        self.assertFalse(self.widget.notice.isHidden())
        self.assertFalse(self.widget.busy)
        self.assertIsNone(self.widget.model.currentData())

    def test_connection_test_uses_synthetic_pipeline_and_reports_usage_pause(self):
        self.widget.activate(True)
        self.flush()
        self.backend.engine.test_llm_pipeline.return_value = SimpleNamespace(
            connection="Passed",
            authentication="Accepted",
            model="Accepted",
            completion="Usage limit reached",
        )
        self.service.list.return_value = [account(paused=True)]
        self.widget.test_connection()
        self.flush()
        self.backend.configure_llm.assert_called_once_with("chatgpt", "", "model-a", None)
        self.backend.engine.test_llm_pipeline.assert_called_once()
        self.backend.engine.test_llm_connection.assert_not_called()
        self.assertIn("Usage limit reached", self.widget.message.text())
        self.assertEqual(self.widget.status.text(), "Usage paused")

    def test_cancel_during_completion_cannot_apply_the_late_account(self):
        self.widget.active = True
        started, release = threading.Event(), threading.Event()
        self.service.begin_sign_in.return_value = SimpleNamespace(
            id="attempt", authorization_url="https://auth.openai.com/test"
        )

        def complete(_):
            started.set()
            self.assertTrue(release.wait(3))
            return account()

        self.service.complete_sign_in.side_effect = complete
        with patch("parakatt_linux.chatgpt_settings.QDesktopServices.openUrl", return_value=True):
            self.widget.start_sign_in()
            self.pool.waitForDone(3000)
            self.app.processEvents()
            self.assertTrue(started.wait(3))
            self.widget.cancel_sign_in()
            release.set()
            self.flush()
        self.backend.engine.set_chatgpt_account.assert_not_called()
        self.assertEqual(self.widget.message.text(), "Sign-in cancelled.")

    def test_failed_model_fetch_refreshes_usage_status_without_retry_loop(self):
        self.widget.activate(True)
        self.flush()
        self.service.models.reset_mock()
        self.service.models.side_effect = RuntimeError("Usage limit reached")
        self.service.list.return_value = [account(paused=True)]
        self.widget.fetch_models()
        self.flush()
        self.service.models.assert_called_once()
        self.assertEqual(self.widget.status.text(), "Usage paused")
        self.assertIn("Usage limit", self.widget.message.text())
        self.assertFalse(self.widget.valid_model())


@unittest.skipUnless(os.environ.get("PARAKATT_TEST_QT"), "Set PARAKATT_TEST_QT=1")
class CleanupSettingsTests(unittest.TestCase):
    def test_cleanup_uses_stable_ids_and_preserves_custom_modes_and_legacy_context(self):
        from PySide6.QtWidgets import QApplication

        from parakatt_linux.app import Window
        from parakatt_linux.backend import Backend, Paths
        from parakatt_linux.settings import Settings

        app = QApplication.instance() or QApplication([])
        with tempfile.TemporaryDirectory() as directory:
            backend = Backend(Paths.discover(data=directory))
            core = backend.engine
            core.save_mode(
                backend.api.ModeConfig(
                    name="Office notes",
                    stt_provider=None,
                    llm_provider=None,
                    system_prompt="Keep notes",
                    dictionary_enabled=True,
                )
            )
            core.set_active_mode("Office notes")
            core.set_llm_context_enabled(False)
            window = Window(backend)
            settings = Settings(backend, window)
            try:
                self.assertEqual(settings.cleanup.currentData(), "Office notes")
                self.assertEqual(settings.cleanup.currentText(), "Custom: Office notes")
                self.assertEqual(
                    [settings.cleanup.itemText(index) for index in range(3)],
                    ["Off", "Punctuation", "Grammar + punctuation"],
                )
                settings.llm_cleanup.setCurrentIndex(settings.llm_cleanup.findData("punctuation"))
                self.assertEqual(settings.cleanup.currentData(), "punctuation")
                settings.save()
                self.assertEqual(core.get_active_mode(), "punctuation")
                self.assertFalse(core.get_llm_context_enabled())
                self.assertIn("Office notes", [mode.name for mode in core.list_modes()])
            finally:
                settings.reject()
                window.pool.waitForDone()
                app.processEvents()
                window.timer.stop()
                window.search_timer.stop()
                window.quitting = True
                window.close()
                settings.deleteLater()
                window.deleteLater()
                from PySide6.QtCore import QCoreApplication, QEvent

                QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)
