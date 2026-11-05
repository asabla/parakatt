"""Checksum-verified build downloads with bounded retries for network failures."""

import hashlib
import http.client
import pathlib
import shutil
import sys
import tempfile
import time
import urllib.error
import urllib.request


def reset_media_outputs(destination):
    """Invalidate media outputs while retaining the separate playback source set."""
    (destination / "stamp").unlink(missing_ok=True)
    for name in ("licenses", "sources"):
        directory = destination / name
        if not directory.is_dir():
            continue
        for path in directory.iterdir():
            if name == "sources" and path.name == "playback":
                continue
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path)
            else:
                path.unlink()


def verify(path, expected, name):
    with path.open("rb") as source:
        actual = hashlib.file_digest(source, "sha256").hexdigest()
    if actual != expected:
        raise ValueError("Checksum mismatch: " + name)


NETWORK_ERRORS = (
    urllib.error.URLError,
    TimeoutError,
    ConnectionError,
    http.client.IncompleteRead,
)
TRANSIENT_HTTP = (408, 429, 500, 502, 503, 504)


def fetch_verified(url, path, expected, name, attempts=5, mirrors=()):
    """Try configured sources in order; every source must match the same digest."""
    locations = (url, *mirrors)
    for index, location in enumerate(locations):
        try:
            return _fetch_verified(location, path, expected, name, attempts)
        except NETWORK_ERRORS as error:
            if index + 1 == len(locations):
                raise
            if isinstance(error, urllib.error.HTTPError) and error.code not in (
                *TRANSIENT_HTTP,
                404,
            ):
                raise
            print(
                f"{name}: source unavailable; trying configured mirror",
                file=sys.stderr,
                flush=True,
            )


def _fetch_verified(url, path, expected, name, attempts):
    path = pathlib.Path(path)
    if path.exists():
        verify(path, expected, name)
        return path
    for attempt in range(attempts):
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(
                dir=path.parent, prefix=path.name + ".", suffix=".download", delete=False
            ) as sink:
                temporary = pathlib.Path(sink.name)
                with urllib.request.urlopen(url, timeout=90) as source:
                    while data := source.read(1024 * 1024):
                        sink.write(data)
            verify(temporary, expected, name)
            temporary.replace(path)
            return path
        except NETWORK_ERRORS as error:
            if isinstance(error, urllib.error.HTTPError) and error.code not in TRANSIENT_HTTP:
                raise
            if attempt + 1 == attempts:
                raise
            delay = 2**attempt
            print(
                f"{name}: {error}; retry {attempt + 2}/{attempts} in {delay}s",
                file=sys.stderr,
                flush=True,
            )
            time.sleep(delay)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
