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

from media_tool_downloads import fetch_verified, verify


class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = pathlib.Path(self.directory.name) / 'notice.txt'
        self.data = b'verified dependency notice'
        self.digest = hashlib.sha256(self.data).hexdigest()
        self.url = 'https://example.invalid/notice.txt'
        self.sleep = self.enterContext(patch('media_tool_downloads.time.sleep'))
        self.open = self.enterContext(patch('media_tool_downloads.urllib.request.urlopen'))

    def fetch(self):
        return fetch_verified(self.url, self.path, self.digest, 'test-notice')

    def assert_no_partial(self):
        self.assertEqual(list(self.path.parent.glob('*.download')), [])

    def test_service_unavailable_then_success(self):
        self.open.side_effect = [urllib.error.HTTPError(self.url, 503, 'Unavailable', {}, None), io.BytesIO(self.data)]
        self.assertEqual(self.fetch().read_bytes(), self.data)
        self.assertEqual(self.open.call_count, 2)
        self.sleep.assert_called_once_with(1)
        self.assert_no_partial()

    def test_interrupted_transfer_restarts_without_partial_bytes(self):
        class Interrupted(io.BytesIO):
            def read(self, size=-1):
                if self.tell():
                    raise http.client.IncompleteRead(b'', 20)
                return super().read(size)
        self.open.side_effect = [Interrupted(b'partial contents'), io.BytesIO(self.data)]
        self.assertEqual(self.fetch().read_bytes(), self.data)
        self.assert_no_partial()

    def test_retry_limit_leaves_no_cache_entry(self):
        self.open.side_effect = urllib.error.URLError('connection failed')
        with self.assertRaises(urllib.error.URLError):
            self.fetch()
        self.assertEqual(self.open.call_count, 5)
        self.assertEqual([call.args[0] for call in self.sleep.call_args_list], [1, 2, 4, 8])
        self.assertFalse(self.path.exists())
        self.assert_no_partial()

    def test_missing_dependency_is_not_retried(self):
        self.open.side_effect = urllib.error.HTTPError(self.url, 404, 'Missing', {}, None)
        with self.assertRaises(urllib.error.HTTPError):
            self.fetch()
        self.assertEqual(self.open.call_count, 1)
        self.sleep.assert_not_called()
        self.assert_no_partial()

    def test_invalid_download_is_not_cached_or_retried(self):
        self.open.return_value = io.BytesIO(b'wrong contents')
        with self.assertRaisesRegex(ValueError, 'Checksum mismatch: test-notice'):
            self.fetch()
        self.assertFalse(self.path.exists())
        self.sleep.assert_not_called()
        self.assert_no_partial()

    def test_valid_cache_needs_no_network(self):
        self.path.write_bytes(self.data)
        self.assertEqual(self.fetch().read_bytes(), self.data)
        self.open.assert_not_called()

    def test_invalid_cache_is_rejected(self):
        self.path.write_bytes(b'corrupt cache')
        with self.assertRaisesRegex(ValueError, 'Checksum mismatch: test-notice'):
            self.fetch()
        self.open.assert_not_called()

    def test_pinned_native_notices_are_available_offline(self):
        root = pathlib.Path(__file__).resolve().parents[1]
        manifest = json.loads((root / 'config/media-tools.json').read_text())
        notices = {name: spec for name, spec in manifest.items() if name.startswith('native-notice-')}
        self.assertTrue(notices)
        for name, spec in notices.items():
            with self.subTest(notice=name):
                path = root / spec['local_path']
                verify(path, spec['sha256'], name)
                contents = path.read_bytes()
                if spec.get('encoding') == 'base64':
                    contents = base64.b64decode(contents, validate=True)
                self.assertTrue(contents.decode('utf-8').strip())
        self.open.assert_not_called()


if __name__ == '__main__':
    unittest.main()
