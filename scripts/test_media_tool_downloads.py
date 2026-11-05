"""Offline regression tests for media build download failures."""

import base64
import hashlib
import http.client
import io
import json
import pathlib
import tempfile
import unittest
import urllib.error
from unittest.mock import patch

from media_tool_downloads import fetch_verified, reset_media_outputs, verify


class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = pathlib.Path(self.directory.name) / "notice.txt"
        self.data = b"verified dependency notice"
        self.digest = hashlib.sha256(self.data).hexdigest()
        self.url = "https://example.invalid/notice.txt"
        self.sleep = self.enterContext(patch("media_tool_downloads.time.sleep"))
        self.open = self.enterContext(patch("media_tool_downloads.urllib.request.urlopen"))

    def fetch(self):
        return fetch_verified(self.url, self.path, self.digest, "test-notice")

    def assert_no_partial(self):
        self.assertEqual(list(self.path.parent.glob("*.download")), [])

    def test_service_unavailable_then_success(self):
        self.open.side_effect = [
            urllib.error.HTTPError(self.url, 503, "Unavailable", {}, None),
            io.BytesIO(self.data),
        ]
        self.assertEqual(self.fetch().read_bytes(), self.data)
        self.assertEqual(self.open.call_count, 2)
        self.sleep.assert_called_once_with(1)
        self.assert_no_partial()

    def test_interrupted_transfer_restarts_without_partial_bytes(self):
        class Interrupted(io.BytesIO):
            def read(self, size=-1):
                if self.tell():
                    raise http.client.IncompleteRead(b"", 20)
                return super().read(size)

        self.open.side_effect = [Interrupted(b"partial contents"), io.BytesIO(self.data)]
        self.assertEqual(self.fetch().read_bytes(), self.data)
        self.assert_no_partial()

    def test_retry_limit_leaves_no_cache_entry(self):
        self.open.side_effect = urllib.error.URLError("connection failed")
        with self.assertRaises(urllib.error.URLError):
            self.fetch()
        self.assertEqual(self.open.call_count, 5)
        self.assertEqual([call.args[0] for call in self.sleep.call_args_list], [1, 2, 4, 8])
        self.assertFalse(self.path.exists())
        self.assert_no_partial()

    def test_missing_dependency_is_not_retried(self):
        self.open.side_effect = urllib.error.HTTPError(self.url, 404, "Missing", {}, None)
        with self.assertRaises(urllib.error.HTTPError):
            self.fetch()
        self.assertEqual(self.open.call_count, 1)
        self.sleep.assert_not_called()
        self.assert_no_partial()

    def test_network_retry_limit_uses_mirror_with_same_digest(self):
        mirror = "https://mirror.invalid/notice.txt"
        self.open.side_effect = [
            urllib.error.URLError("connection failed"),
            urllib.error.URLError("connection failed"),
            io.BytesIO(self.data),
        ]
        result = fetch_verified(
            self.url, self.path, self.digest, "test-notice", attempts=2, mirrors=[mirror]
        )
        self.assertEqual(result.read_bytes(), self.data)
        self.assertEqual(
            [call.args[0] for call in self.open.call_args_list],
            [self.url, self.url, mirror],
        )
        self.assert_no_partial()

    def test_mirror_checksum_failure_is_not_cached(self):
        self.open.side_effect = [
            urllib.error.HTTPError(self.url, 404, "Missing", {}, None),
            io.BytesIO(b"wrong contents"),
        ]
        with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
            fetch_verified(
                self.url, self.path, self.digest, "test-notice", mirrors=["https://mirror.invalid"]
            )
        self.assertEqual(self.open.call_count, 2)
        self.assertFalse(self.path.exists())
        self.assert_no_partial()

    def test_primary_checksum_failure_does_not_try_mirror(self):
        self.open.return_value = io.BytesIO(b"wrong contents")
        with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
            fetch_verified(
                self.url, self.path, self.digest, "test-notice", mirrors=["https://mirror.invalid"]
            )
        self.assertEqual(self.open.call_count, 1)
        self.assert_no_partial()

    def test_authorization_failure_does_not_try_mirror(self):
        self.open.side_effect = urllib.error.HTTPError(self.url, 403, "Forbidden", {}, None)
        with self.assertRaises(urllib.error.HTTPError):
            fetch_verified(
                self.url, self.path, self.digest, "test-notice", mirrors=["https://mirror.invalid"]
            )
        self.assertEqual(self.open.call_count, 1)
        self.assert_no_partial()

    def test_invalid_download_is_not_cached_or_retried(self):
        self.open.return_value = io.BytesIO(b"wrong contents")
        with self.assertRaisesRegex(ValueError, "Checksum mismatch: test-notice"):
            self.fetch()
        self.assertFalse(self.path.exists())
        self.sleep.assert_not_called()
        self.assert_no_partial()

    def test_valid_cache_needs_no_network(self):
        self.path.write_bytes(self.data)
        self.assertEqual(self.fetch().read_bytes(), self.data)
        self.open.assert_not_called()

    def test_invalid_cache_is_rejected(self):
        self.path.write_bytes(b"corrupt cache")
        with self.assertRaisesRegex(ValueError, "Checksum mismatch: test-notice"):
            self.fetch()
        self.open.assert_not_called()

    def test_media_rebuild_removes_stale_outputs_and_preserves_playback_sources(self):
        destination = pathlib.Path(self.directory.name)
        (destination / "stamp").write_text("previous build")
        sources = destination / "sources"
        playback = sources / "playback"
        playback.mkdir(parents=True)
        (playback / "vlc.tar.gz").write_bytes(b"playback source")
        (sources / "ffmpeg-old.tar.xz").write_bytes(b"old media source")
        notices = destination / "licenses"
        notices.mkdir()
        (notices / "deno-old.txt").write_text("old notice")

        reset_media_outputs(destination)

        self.assertFalse((destination / "stamp").exists())
        self.assertEqual(list(sources.iterdir()), [playback])
        self.assertEqual((playback / "vlc.tar.gz").read_bytes(), b"playback source")
        self.assertEqual(list(notices.iterdir()), [])
        reset_media_outputs(destination)
        self.assertTrue((playback / "vlc.tar.gz").is_file())

    def test_pinned_native_notices_are_available_offline(self):
        root = pathlib.Path(__file__).resolve().parents[1]
        manifest = json.loads((root / "config/media-tools.json").read_text())
        notices = {
            name: spec for name, spec in manifest.items() if name.startswith("native-notice-")
        }
        self.assertTrue(notices)
        for name, spec in notices.items():
            with self.subTest(notice=name):
                path = root / spec["local_path"]
                verify(path, spec["sha256"], name)
                contents = path.read_bytes()
                if spec.get("encoding") == "base64":
                    contents = base64.b64decode(contents, validate=True)
                self.assertTrue(contents.decode("utf-8").strip())
        self.open.assert_not_called()


if __name__ == "__main__":
    unittest.main()
