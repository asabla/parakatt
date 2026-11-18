"""Native file verification must derive its digest from the pinned archive."""

import hashlib
import importlib.util
import io
import json
import lzma
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from native_runtime import verify_native


class NativeRuntimeTests(unittest.TestCase):
    def test_runtime_upgrade_does_not_reuse_the_previous_archive(self):
        spec = importlib.util.spec_from_file_location(
            "build_linux", Path(__file__).with_name("build-linux.py")
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "config").mkdir()
            cache = root / "target/linux-runtime"
            cache.mkdir(parents=True)
            previous = cache / "onnxruntime-1.30.0.whl"
            previous.write_bytes(b"previous version")
            output = io.BytesIO()
            with zipfile.ZipFile(output, "w") as package:
                package.writestr("onnxruntime/capi/libonnxruntime.so.1.31.0", b"new")
                package.writestr("onnxruntime/LICENSE", b"license")
                package.writestr("onnxruntime/ThirdPartyNotices.txt", b"notices")
            raw = output.getvalue()
            (root / "config/linux-runtime.json").write_text(
                json.dumps(
                    {
                        "version": "1.31.0",
                        "directory": "onnxruntime-1.31.0",
                        "url": "https://example.invalid/onnxruntime-1.31.0.whl",
                        "sha256": hashlib.sha256(raw).hexdigest(),
                    }
                )
            )
            with (
                patch.object(module, "ROOT", root),
                patch.dict("os.environ", {}, clear=True),
                patch.object(module.platform, "machine", return_value="x86_64"),
                patch.object(
                    module.urllib.request, "urlopen", return_value=io.BytesIO(raw)
                ) as fetch,
            ):
                environment = module.runtime_environment()
                self.assertEqual(module.runtime_environment(), environment)
            self.assertEqual(previous.read_bytes(), b"previous version")
            library = Path(environment["ORT_LIB_PATH"])
            self.assertEqual((library / "libonnxruntime.so.1").read_bytes(), b"new")
            self.assertEqual(
                (library / "libonnxruntime.so").readlink(), Path("libonnxruntime.so.1.31.0")
            )
            self.assertEqual((library.parent / "LICENSE").read_bytes(), b"license")
            self.assertEqual((library.parent / "ThirdPartyNotices.txt").read_bytes(), b"notices")
            fetch.assert_called_once()

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
