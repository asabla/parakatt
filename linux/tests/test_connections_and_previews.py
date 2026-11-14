"""No-write previews, explicit account selection and bounded source discovery."""

import json
import tempfile
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch
from urllib.parse import parse_qs, urlsplit

from parakatt_linux.authentication import MEETING_SCOPE, TRANSCRIPT_SCOPE, TeamsAuthentication
from parakatt_linux.backend import Backend, Paths, Recording
from parakatt_linux.connections import Connection, load_connections, save_connections
from parakatt_linux.providers import (
    ProviderError,
    Response,
    graph_collection,
    slack_identity,
    slack_sources,
    slack_speaker_names,
    teams_meeting,
    teams_transcripts,
)
from parakatt_linux.transcript_service import TranscriptService
from parakatt_linux.worker_events import RecordingState

VTT = "WEBVTT\n\n00:00:00.000 --> 00:00:02.000\n<v Sam>Review the contract.</v>\n"
NATIVE = (Path(__file__).parents[1] / "parakatt_linux/_native/parakatt_core.py").exists()


class MemoryStore:
    def __init__(self):
        self.values = {}

    def get_password(self, service, account):
        return self.values.get((service, account))

    def set_password(self, service, account, password):
        self.values[service, account] = password

    def delete_password(self, service, account):
        del self.values[service, account]


class ConnectionMetadataTests(unittest.TestCase):
    def test_atomic_metadata_storage_and_corruption_preservation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "connections.json"
            values = [Connection("c1", "teams", "Work", client_id="public-id")]
            save_connections(path, values)
            self.assertEqual(load_connections(path), (values, None))
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            before = path.read_bytes()
            with (
                patch("parakatt_linux.connections.os.replace", side_effect=OSError("disk full")),
                self.assertRaises(OSError),
            ):
                save_connections(path, [])
            self.assertEqual(path.read_bytes(), before)
            self.assertFalse(list(path.parent.glob("*.tmp")))
            path.write_text('{"version":1,"connections":"invalid"}')
            self.assertTrue(load_connections(path)[1])
            self.assertFalse(path.exists())
            self.assertEqual(len(list(path.parent.glob("*.invalid-*.json"))), 1)

    def test_duplicate_credentials_are_not_exposed_as_independent_connections(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "connections.json"
            first = Connection("one", "teams", "Work", client_id="APP", tenant="Example.org")
            second = Connection(
                "two", "teams", "Other label", client_id="app", tenant="example.org"
            )
            with self.assertRaisesRegex(ValueError, "already has a connection"):
                save_connections(path, [first, second])
            self.assertFalse(path.exists())


class AuthenticationBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.store = MemoryStore()
        self.cache = SimpleNamespace(
            has_state_changed=True, serialize=lambda: "opaque-cache", deserialize=Mock()
        )
        self.client = Mock()
        self.client.get_accounts.return_value = []
        self.enterContext(patch("msal.SerializableTokenCache", return_value=self.cache))
        self.factory = self.enterContext(
            patch("msal.PublicClientApplication", return_value=self.client)
        )

    def auth(self, **kwargs):
        return TeamsAuthentication("public-id", "example.org", store=self.store, **kwargs)

    def test_multiple_accounts_require_an_explicit_choice_and_minimal_scopes(self):
        accounts = [
            {"home_account_id": "one", "username": "a@example.org"},
            {"home_account_id": "two", "username": "b@example.org"},
        ]
        self.client.get_accounts.return_value = accounts
        self.client.acquire_token_silent.return_value = {"access_token": "private-token"}
        auth = self.auth()
        self.assertEqual([account.id for account in auth.accounts()], ["one", "two"])
        with self.assertRaisesRegex(ProviderError, "choose a work account"):
            auth.token(interactive=False)
        self.assertEqual(auth.token("two", interactive=False), "private-token")
        self.client.acquire_token_silent.assert_called_once_with(
            [TRANSCRIPT_SCOPE], account=accounts[1]
        )
        self.assertEqual(
            self.store.values[("parakatt-integrations", "teams:example.org:public-id")],
            "opaque-cache",
        )
        self.assertEqual(self.auth(meeting_links=True).scopes, [TRANSCRIPT_SCOPE, MEETING_SCOPE])

    def test_cancellation_stops_device_flow_without_persisting_tokens(self):
        cancel = threading.Event()
        flow = {
            "user_code": "TEST-CODE",
            "verification_uri": "https://microsoft.com/devicelogin",
            "message": "Example sign-in",
            "expires_at": 100,
        }
        self.client.initiate_device_flow.return_value = flow

        def poll(value):
            for _ in range(100):
                if value.get("expires_at") == 0:
                    return {"error": "expired_token"}
                threading.Event().wait(0.01)
            self.fail("Device flow was not canceled")

        self.client.acquire_token_by_device_flow.side_effect = poll
        with self.assertRaisesRegex(ProviderError, "canceled"):
            self.auth().token(announce=lambda _prompt: cancel.set(), cancel=cancel)
        self.assertEqual(self.store.values, {})

    def test_failed_sign_in_does_not_expose_provider_body_or_token(self):
        self.client.initiate_device_flow.return_value = {"user_code": "TEST"}
        self.client.acquire_token_by_device_flow.return_value = {
            "error": "access_denied",
            "error_description": "private provider content",
        }
        with self.assertRaises(ProviderError) as raised:
            self.auth().token()
        self.assertNotIn("private provider content", str(raised.exception))
        self.assertEqual(self.store.values, {})

    def test_sign_out_only_removes_selected_account(self):
        account = {"home_account_id": "two"}
        self.client.get_accounts.return_value = [{"home_account_id": "one"}, account]
        self.auth().sign_out("two")
        self.client.remove_account.assert_called_once_with(account)

    def test_device_prompt_always_includes_the_code_when_provider_message_is_missing(self):
        self.client.initiate_device_flow.return_value = {"user_code": "TEST-CODE"}
        self.client.acquire_token_by_device_flow.return_value = {"access_token": "private-token"}
        prompts = []
        self.auth().token(announce=prompts.append)
        self.assertIn("TEST-CODE", prompts[0].message)
        self.assertIn("https://microsoft.com/devicelogin", prompts[0].message)


class SourceDiscoveryTests(unittest.TestCase):
    def test_graph_pagination_stays_in_the_selected_collection(self):
        url = "https://graph.microsoft.com/v1.0/me/onlineMeetings/M/transcripts"
        pages = iter(
            [
                Response(
                    200,
                    json.dumps(
                        {"value": [{"id": "T1"}], "@odata.nextLink": url + "?$skiptoken=next"}
                    ).encode(),
                ),
                Response(200, b'{"value":[{"id":"T2"}]}'),
            ]
        )
        self.assertEqual(
            [row["id"] for row in graph_collection(url, "secret", lambda *_: next(pages))],
            ["T1", "T2"],
        )
        for next_url in [
            "https://attacker.example/steal",
            "https://graph.microsoft.com/v1.0/me/messages",
            "https://graph.microsoft.com:444/v1.0/me/onlineMeetings/M/transcripts",
        ]:
            calls = []

            def transport(address, *_, seen=calls, link=next_url):
                seen.append(address)
                return Response(200, json.dumps({"value": [], "@odata.nextLink": link}).encode())

            with self.assertRaisesRegex(ProviderError, "left the selected collection"):
                graph_collection(url, "secret", transport)
            self.assertEqual(calls, [url])

    def test_teams_link_lookup_requires_opt_in_and_escapes_odata(self):
        calls = []
        reference = "https://teams.microsoft.com/l/meetup-join/a'b"

        def transport(url, *_):
            calls.append(url)
            return Response(200, b'{"value":[{"id":"M1","subject":"Review"}]}')

        with self.assertRaisesRegex(ProviderError, "optional OnlineMeetings.Read"):
            teams_meeting("secret", reference, transport=transport)
        self.assertEqual(calls, [])
        self.assertEqual(
            teams_meeting("secret", reference, allow_links=True, transport=transport).id, "M1"
        )
        query = parse_qs(urlsplit(calls[0]).query)
        self.assertIn("a''b", query["$filter"][0])
        self.assertNotIn("secret", calls[0])
        self.assertEqual(teams_meeting("secret", "M/1").id, "M/1")

    def test_transcript_selection_retains_server_ids_and_dates(self):
        sources = teams_transcripts(
            "secret",
            "M/1",
            transport=lambda *_: Response(
                200, b'{"value":[{"id":"T1","createdDateTime":"2026-11-14T09:00:00Z"}]}'
            ),
        )
        self.assertEqual(sources[0].id, "T1")
        self.assertIn("2026-11-14", sources[0].created_at)

    def test_slack_lists_only_advertised_transcripts_across_pages(self):
        calls = []

        def transport(url, *_):
            calls.append(url)
            page = parse_qs(urlsplit(url).query)["page"][0]
            data = (
                {
                    "ok": True,
                    "paging": {"pages": 2},
                    "files": [
                        {"id": "NOTES", "title": "AI notes"},
                        {"id": "F1", "title": "Huddle", "huddle_transcript_file_id": "F2"},
                    ],
                }
                if page == "1"
                else {
                    "ok": True,
                    "paging": {"pages": 2},
                    "files": [{"id": "F2", "huddle_transcription": {"lines": []}}],
                }
            )
            return Response(200, json.dumps(data).encode())

        self.assertEqual(
            [source.id for source in slack_sources("secret", "C1", transport)], ["F1", "F2"]
        )
        self.assertEqual(len(calls), 2)
        self.assertIn("channel=C1", calls[0])
        identity = slack_identity(
            "secret",
            lambda *_: Response(200, b'{"ok":true,"team_id":"T1","team":"Example","user":"alex"}'),
        )
        self.assertEqual(identity.workspace_id, "T1")

    def test_canceling_name_lookup_does_not_continue_reading_profiles(self):
        canceled = threading.Event()
        canceled.set()
        transport = Mock()
        with self.assertRaisesRegex(ProviderError, "canceled"):
            slack_speaker_names(
                "secret", '{"lines":[{"text":"Hi","user_id":"U1"}]}', transport, canceled
            )
        transport.assert_not_called()


@unittest.skipUnless(NATIVE, "Build the shared bindings")
class PreviewContractTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.backend = Backend(Paths.discover(data=self.directory.name))
        self.service = TranscriptService(self.backend, MemoryStore())

    def test_preview_is_read_only_and_commit_uses_the_reviewed_snapshot(self):
        source = Path(self.directory.name) / "meeting.vtt"
        source.write_text(VTT)
        preview = self.service.from_file(source, "teams", "Review")
        self.assertEqual(preview.speakers, ("Sam",))
        self.assertEqual(self.backend.history(), [])
        self.assertFalse(self.backend.engine.is_model_loaded())
        source.write_text(VTT.replace("Review the contract.", "Changed after preview."))
        committed = self.service.commit(preview, "Confirmed review")
        self.assertIn(
            "Review the contract.", self.backend.engine.get_transcription(committed.result.id).text
        )
        self.assertEqual(
            self.backend.engine.get_transcript_origin(committed.result.id).original_content, VTT
        )

    def test_duplicate_import_preserves_user_edits_and_speaker_corrections(self):
        preview = self.service.prepare("teams", "Review", VTT, "M/T", {"Sam": "Source name"})
        first = self.service.commit(preview, "Review")
        self.backend.engine.edit_transcription(first.result.id, "Edited minutes")
        self.backend.engine.set_transcript_speaker_alias(first.result.id, "Sam", "Samantha")
        again = self.service.commit(preview, "Different title")
        self.assertFalse(again.result.created)
        self.assertEqual(
            self.backend.engine.get_transcription(first.result.id).text, "Edited minutes"
        )
        self.assertEqual(
            self.backend.engine.get_imported_utterances(first.result.id)[0].speaker, "Samantha"
        )

    def test_malformed_or_untimed_content_never_manufactures_history(self):
        with self.assertRaises(self.backend.api.CoreError):
            self.service.prepare("teams", "Review", "invalid")
        self.assertEqual(self.backend.history(), [])
        preview = self.service.prepare(
            "slack", "Huddle", '{"lines":[{"text":"Review the plan","user_id":"U1"}]}'
        )
        self.assertIsNone(preview.utterances[0].start_secs)
        self.assertEqual(preview.utterances[0].speaker, "U1")
        self.assertEqual(self.backend.history(), [])


class WorkerStateTests(unittest.TestCase):
    def test_state_callback_can_stop_capture_without_deadlocking(self):
        events = []
        recording = Recording(
            SimpleNamespace(),
            False,
            "dictation",
            lambda kind, value: (
                events.append((kind, value)),
                recording.stop()
                if kind == "recording_state" and value == RecordingState.RECORDING
                else None,
            ),
        )
        recording._transition(RecordingState.PREPARING)
        worker = threading.Thread(
            target=lambda: recording._transition(RecordingState.RECORDING), daemon=True
        )
        worker.start()
        worker.join(timeout=2)
        self.assertFalse(worker.is_alive())
        self.assertEqual(recording.state, RecordingState.FINISHING)
        recording.set_paused(True)
        self.assertEqual(recording.state, RecordingState.FINISHING)


if __name__ == "__main__":
    unittest.main()
