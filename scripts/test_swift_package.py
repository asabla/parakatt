"""Exercise package assembly and failure behavior without requiring a macOS SDK."""

import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import swift_package


class SwiftPackageTests(unittest.TestCase):
    def test_package_uses_locked_generator_and_versioned_framework(self):
        for features in ("", "webgpu"):
            with self.subTest(features=features), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                manifest = root / "crates/parakatt-core/native-runtime-manifest.json"
                manifest.parent.mkdir(parents=True)
                manifest.write_text(json.dumps({"archive_sha256": "example-pin"}))
                calls = []

                def run(arguments, root=root, calls=calls, **kwargs):
                    calls.append((arguments, kwargs))
                    if arguments[:2] == ["cargo", "build"]:
                        output = root / "target" / swift_package.TARGET / "release"
                        output.mkdir(parents=True)
                        (output / "libparakatt_core.dylib").write_bytes(b"core")
                        (output / "libwebgpu_dawn.dylib").write_bytes(b"dawn")
                    elif arguments[:2] == ["cargo", "run"]:
                        output = Path(arguments[arguments.index("--out-dir") + 1])
                        output.mkdir()
                        (output / "parakatt_core.swift").write_text("// matching bindings")
                        (output / "parakatt_coreFFI.h").write_text("// matching header")
                        (output / "parakatt_coreFFI.modulemap").write_text(
                            'module parakatt_coreFFI { header "parakatt_coreFFI.h" }'
                        )
                    elif arguments[0] == "xcodebuild":
                        framework = Path(arguments[arguments.index("-framework") + 1])
                        output = Path(arguments[arguments.index("-output") + 1])
                        shutil.copytree(
                            framework, output / "macos-arm64" / framework.name, symlinks=True
                        )

                with (
                    patch.dict(os.environ, {"MACOSX_DEPLOYMENT_TARGET": "14.0"}),
                    patch("swift_package.subprocess.run", side_effect=run),
                    patch("swift_package.verify_webgpu") as verify,
                ):
                    swift_package.build(root, features)
                package = root / "ParakattCore"
                framework = (
                    package / "parakatt_coreFFI.xcframework/macos-arm64/parakatt_coreFFI.framework"
                )
                self.assertEqual(
                    (package / "Sources/ParakattCore/parakatt_core.swift").read_text(),
                    "// matching bindings",
                )
                self.assertTrue((framework / "Versions/Current").is_symlink())
                self.assertEqual((framework / "parakatt_coreFFI").read_bytes(), b"core")
                self.assertIn(
                    "framework module", (framework / "Modules/module.modulemap").read_text()
                )
                with (framework / "Resources/Info.plist").open("rb") as stream:
                    self.assertEqual(plistlib.load(stream)["LSMinimumSystemVersion"], "14.0")
                cargo_calls = [(args, kwargs) for args, kwargs in calls if args[0] == "cargo"]
                self.assertEqual(len(cargo_calls), 2)
                for arguments, kwargs in cargo_calls:
                    self.assertIn("--locked", arguments)
                    self.assertTrue(kwargs["check"])
                    self.assertEqual(kwargs["env"]["MACOSX_DEPLOYMENT_TARGET"], "14.0")
                    if features:
                        self.assertEqual(arguments[arguments.index("--features") + 1], features)
                if features:
                    verify.assert_called_once()
                    self.assertEqual(
                        (framework / "Versions/A/Frameworks/libwebgpu_dawn.dylib").read_bytes(),
                        b"dawn",
                    )
                else:
                    verify.assert_not_called()

    def test_failed_generation_preserves_the_previous_package(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / "ParakattCore"
            package.mkdir()
            original = package / "previous-bindings.swift"
            original.write_text("previous valid package")
            with (
                patch(
                    "swift_package.subprocess.run",
                    side_effect=[None, subprocess.CalledProcessError(1, "cargo")],
                ),
                self.assertRaises(subprocess.CalledProcessError),
            ):
                swift_package.build(root, "")
            self.assertEqual(original.read_text(), "previous valid package")

    def test_unsupported_features_do_not_start_a_build(self):
        with patch("swift_package.subprocess.run") as run, self.assertRaises(ValueError):
            swift_package.build(Path("unused"), "unsupported")
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
