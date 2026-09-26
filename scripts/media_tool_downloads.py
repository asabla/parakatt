"""Checksum-verified build downloads with bounded retries for network failures."""
import hashlib
import http.client
import pathlib
import sys
import tempfile
import time
import urllib.error
import urllib.request


def verify(path, expected, name):
    with path.open('rb') as source:
        actual = hashlib.file_digest(source, 'sha256').hexdigest()
    if actual != expected:
        raise ValueError('Checksum mismatch: ' + name)


def fetch_verified(url, path, expected, name, attempts=5):
    path = pathlib.Path(path)
    if path.exists():
        verify(path, expected, name)
        return path
    for attempt in range(attempts):
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=path.parent, prefix=path.name + '.', suffix='.download', delete=False) as sink:
                temporary = pathlib.Path(sink.name)
                with urllib.request.urlopen(url, timeout=90) as source:
                    while data := source.read(1024 * 1024):
                        sink.write(data)
            verify(temporary, expected, name)
            temporary.replace(path)
            return path
        except (urllib.error.URLError, TimeoutError, ConnectionError, http.client.IncompleteRead) as error:
            if isinstance(error, urllib.error.HTTPError) and error.code not in (408, 429, 500, 502, 503, 504):
                raise
            if attempt + 1 == attempts:
                raise
            delay = 2 ** attempt
            print(f'{name}: {error}; retry {attempt + 2}/{attempts} in {delay}s', file=sys.stderr, flush=True)
            time.sleep(delay)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
