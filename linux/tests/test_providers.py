import json
import unittest
from unittest.mock import patch

from parakatt_linux.providers import (
    ProviderError,
    Response,
    get_with_retry,
    http_get,
    slack_speaker_names,
    slack_transcript,
    teams_transcript,
)


class ProviderTests(unittest.TestCase):
    def test_tenant_restrictions_and_http_date_rate_limit_fail_explicitly(self):
        body = b'{"error":{"innerError":{"code":"SpeakerAttributionNotAllowed"}}}'
        with self.assertRaisesRegex(ProviderError, "disabled speaker-attributed"):
            get_with_retry(
                "https://graph.microsoft.com", "token", "text/vtt", lambda *_: Response(403, body)
            )
        with (
            patch("parakatt_linux.providers.time.sleep") as sleep,
            self.assertRaisesRegex(ProviderError, "delayed retry"),
        ):
            get_with_retry(
                "url",
                "token",
                "text/vtt",
                lambda *_: Response(429, b"", "Wed, 11 Nov 2026 12:00:00 GMT"),
            )
        sleep.assert_not_called()

    def test_optional_slack_name_lookup_retains_only_names(self):
        transcript = '{"file":{"huddle_transcription":{"lines":[{"user_id":"U1","text":"Hello"},{"user_id":"U1","text":"Again"}]}}}'
        calls = []

        def transport(url, *_):
            calls.append(url)
            return Response(
                200,
                b'{"ok":true,"user":{"profile":{"display_name":"Alex","email":"not-retained@example.com"}}}',
            )

        self.assertEqual(slack_speaker_names("token", transcript, transport), {"U1": "Alex"})
        self.assertEqual(len(calls), 1)

    def test_teams_uses_fixed_host_encoded_identifiers_and_named_format(self):
        requests = []

        def transport(url, token, accept):
            requests.append((url, token, accept))
            return Response(200, b"WEBVTT\n")

        self.assertEqual(
            teams_transcript("secret", "meeting/1", "transcript?1", transport=transport), "WEBVTT\n"
        )
        self.assertIn("meeting%2F1", requests[0][0])
        self.assertIn("transcript%3F1", requests[0][0])
        self.assertEqual(requests[0][2], "text/vtt")
        self.assertNotIn("secret", requests[0][0])

    def test_busy_provider_retries_but_denied_access_does_not_leak_response(self):
        responses = iter([Response(429, b"", "0"), Response(200, b"ok")])
        with patch("parakatt_linux.providers.time.sleep"):
            self.assertEqual(
                get_with_retry("url", "token", "text/vtt", lambda *_: next(responses)), b"ok"
            )
        for status in (401, 403, 500):
            with self.assertRaises(ProviderError) as error:
                get_with_retry(
                    "url", "token", "text/vtt", lambda *_, s=status: Response(s, b"private data")
                )
            self.assertNotIn("private data", str(error.exception))

    def test_unsupported_hosts_are_rejected_before_credentials_are_sent(self):
        for url in ("https://attacker.example/file", "http://graph.microsoft.com/file"):
            with self.assertRaises(ProviderError):
                http_get(url, "secret", "text/vtt")

    def test_slack_follows_only_documented_transcript_file_reference(self):
        calls = []

        def transport(url, *_):
            calls.append(url)
            payload = (
                {"ok": True, "file": {"huddle_transcript_file_id": "F2"}}
                if len(calls) == 1
                else {"ok": True, "file": {"huddle_transcription": {"lines": [{"contents": "Hi"}]}}}
            )
            return Response(200, json.dumps(payload).encode())

        self.assertIn("huddle_transcription", slack_transcript("secret", "F1", transport))
        self.assertTrue(calls[1].endswith("file=F2"))

    def test_slack_summary_is_not_silently_used_as_transcript(self):
        with self.assertRaisesRegex(ProviderError, "No accessible Huddle transcript"):
            slack_transcript(
                "token", "F1", lambda *_: Response(200, b'{"ok":true,"file":{"title":"Notes"}}')
            )


if __name__ == "__main__":
    unittest.main()
