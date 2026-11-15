"""Verify a built native library against its checksum-pinned source archive."""

import hashlib
import lzma
from pathlib import Path
import shutil
import tarfile
import tempfile
import urllib.request


def verify_native(native, archive, expected_hash):
    with archive.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != expected_hash:
            raise RuntimeError("Native runtime archive checksum mismatch")
    expected = []
    # ort-sys distributes raw LZMA2 with a 64 MiB dictionary, rather than XZ.
    with (
        lzma.open(
            archive,
            format=lzma.FORMAT_RAW,
            filters=[{"id": lzma.FILTER_LZMA2, "dict_size": 1 << 26}],
        ) as stream,
        tarfile.open(fileobj=stream, mode="r|") as package,
    ):
        for member in package:
            if Path(member.name).name != native.name:
                continue
            if not member.isfile() or member.size > 512 * 1024 * 1024:
                raise RuntimeError("Invalid native runtime library in archive")
            source = package.extractfile(member)
            if source is None:
                raise RuntimeError("Native runtime library is unreadable")
            with source:
                expected.append(hashlib.file_digest(source, "sha256").hexdigest())
    if len(expected) != 1:
        raise RuntimeError("Expected exactly one native runtime library in archive")
    with native.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != expected[0]:
            raise RuntimeError("Built native runtime differs from its pinned source archive")


def verify_webgpu(root, native, manifest):
    cache = root / "target/native-runtime"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / (manifest["archive_sha256"] + ".tar.lzma2")
    if not archive.exists():
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as output:
            temporary = Path(output.name)
            try:
                with urllib.request.urlopen(manifest["archive_url"], timeout=60) as source:
                    shutil.copyfileobj(source, output)
                output.flush()
                with temporary.open("rb") as stream:
                    if (
                        hashlib.file_digest(stream, "sha256").hexdigest()
                        != manifest["archive_sha256"]
                    ):
                        raise RuntimeError("Native runtime archive checksum mismatch")
                temporary.replace(archive)
            finally:
                temporary.unlink(missing_ok=True)
    verify_native(native, archive, manifest["archive_sha256"])
