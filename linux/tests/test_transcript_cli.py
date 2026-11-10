import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from parakatt_linux.import_cli import main, teams_token

NATIVE = (Path(__file__).parents[1] / "parakatt_linux/_native/parakatt_core.py").exists()


class AuthenticationTests(unittest.TestCase):
    def test_teams_requests_only_transcripts_and_caches_in_keyring(self):
        cache = SimpleNamespace(has_state_changed=True, serialize=lambda: "opaque cache")
        flow = {"user_code": "TEST", "message": "Test sign-in instruction"}
        application = SimpleNamespace(
            get_accounts=lambda: [],
            initiate_device_flow=Mock(return_value=flow),
            acquire_token_by_device_flow=lambda _: {"access_token": "private-token"},
        )
        messages = []
        with (
            patch("msal.SerializableTokenCache", return_value=cache),
            patch("msal.PublicClientApplication", return_value=application) as factory,
            patch("keyring.backends.SecretService.Keyring") as store,
        ):
            store.return_value.get_password.return_value = None
            token = teams_token("client-id", "organizations", messages.append)
            self.assertEqual(token, "private-token")
            self.assertEqual(messages, ["Test sign-in instruction"])
            application.initiate_device_flow.assert_called_once_with(
                scopes=["https://graph.microsoft.com/OnlineMeetingTranscript.Read.All"]
            )
            self.assertNotIn("client_credential", factory.call_args.kwargs)
            store.return_value.set_password.assert_called_once_with(
                "parakatt-integrations", "teams:organizations:client-id", "opaque cache"
            )


@unittest.skipUnless(NATIVE, "Build the native bindings")
class TranscriptCommandTests(unittest.TestCase):
    def test_file_import_deduplication_rename_and_export_need_no_model(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "teams.vtt"
            transcript.write_text(
                "WEBVTT\n\n00:00:00.000 --> 00:00:02.000\n<v Sam>Review the contract.</v>\n"
            )

            def run(*arguments):
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    status = main(["--data-dir", str(root / "app"), *arguments])
                self.assertEqual(status, 0)
                return output.getvalue()

            first = json.loads(run("file", "--provider", "teams", str(transcript)))
            second = json.loads(run("file", "--provider", "teams", str(transcript)))
            self.assertEqual(first["id"], second["id"])
            self.assertFalse(second["created"])
            run("speaker", "--record-id", first["id"], "--original", "Sam", "--name", "Samantha")
            action = json.loads(
                run(
                    "action",
                    "--record-id",
                    first["id"],
                    "--text",
                    "Review contract",
                    "--source-utterance",
                    "0",
                    "--owner",
                    "Samantha",
                    "--due-date",
                    "2026-11-20",
                )
            )
            run("complete-action", "--record-id", first["id"], "--action-id", action["id"])
            output = root / "minutes.md"
            run("export", "--record-id", first["id"], "--output", str(output))
            self.assertIn("Samantha: Review the contract.", output.read_text())
            self.assertIn("- [x] Review contract", output.read_text())
            self.assertIn("2026\\-11\\-20", output.read_text())
            self.assertIn("Source utterance 0", output.read_text())
            self.assertFalse(list((root / "app/models").glob("**/*.onnx")))


if __name__ == "__main__":
    unittest.main()
