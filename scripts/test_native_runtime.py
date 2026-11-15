"""Native file verification must derive its digest from the pinned archive."""

import hashlib
import io
import lzma
from pathlib import Path
import tarfile
import tempfile
import unittest

from native_runtime import verify_native


class NativeRuntimeTests(unittest.TestCase):
    def test_pinned_archive_and_library_must_both_match(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            raw = io.BytesIO()
            content = b"verified native runtime"
            with tarfile.open(fileobj=raw, mode="w") as package:
                item = tarfile.TarInfo("lib/libwebgpu_dawn.dylib")
                item.size = len(content)
                package.addfile(item, io.BytesIO(content))
            archive = root / "runtime.tar.lzma2"
            archive.write_bytes(
                lzma.compress(
                    raw.getvalue(),
                    format=lzma.FORMAT_RAW,
                    filters=[{"id": lzma.FILTER_LZMA2, "dict_size": 1 << 26}],
                )
            )
            expected = hashlib.sha256(archive.read_bytes()).hexdigest()
            native = root / "libwebgpu_dawn.dylib"
            native.write_bytes(content)
            verify_native(native, archive, expected)
            native.write_bytes(b"modified library")
            with self.assertRaisesRegex(RuntimeError, "differs"):
                verify_native(native, archive, expected)
            archive.write_bytes(b"modified archive")
            with self.assertRaisesRegex(RuntimeError, "archive checksum"):
                verify_native(native, archive, expected)


if __name__ == "__main__":
    unittest.main()
