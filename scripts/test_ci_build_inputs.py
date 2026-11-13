"""Offline checks for shared Swift CI artifacts and their platform boundaries."""

import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import ci_build_inputs as inputs


class BuildInputTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.source = self.root / "source"
        self.destination = self.root / "restored"
        self.archive = self.root / "inputs.tar.gz"
        for name in inputs.BUNDLES["swift"]:
            path = self.source / name
            if name == "ParakattCore":
                binary = path / "Core.framework/Versions/A/Core"
                binary.parent.mkdir(parents=True)
                binary.write_bytes(b"native framework")
                binary.chmod(0o755)
                (binary.parent.parent / "Current").symlink_to("A")
                (path / "Core.framework/Core").symlink_to("Versions/Current/Core")
            elif name.endswith("SettingPresets"):
                path.mkdir(parents=True)
                (path / "base.yml").write_text("PRODUCT_NAME: $(TARGET_NAME)\n")
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"pinned input")
                path.chmod(0o755)

    def pack(self):
        inputs.pack(self.source, "swift", self.archive, "commit-a", "sdk-a")

    def test_round_trip_preserves_framework_links_and_tool_permissions(self):
        self.pack()
        inputs.restore(self.destination, "swift", self.archive, "commit-a", "sdk-a")
        binary = self.destination / "ParakattCore/Core.framework/Core"
        self.assertTrue(binary.is_symlink())
        self.assertEqual(binary.read_bytes(), b"native framework")
        self.assertTrue(os.access(binary, os.X_OK))
        self.assertTrue(os.access(self.destination / "target/ci-tools/bin/xcodegen", os.X_OK))
        self.assertTrue(
            (self.destination / "target/ci-tools/share/xcodegen/SettingPresets/base.yml").is_file()
        )
        self.assertFalse((self.destination / inputs.MANIFEST).exists())

    def test_mismatched_commit_environment_or_bundle_is_rejected_before_extracting(self):
        self.pack()
        for kind, revision, environment in (
            ("swift", "commit-b", "sdk-a"),
            ("swift", "commit-a", "sdk-b"),
            ("media", "commit-a", "sdk-a"),
        ):
            with self.assertRaisesRegex(ValueError, "do not match"):
                inputs.restore(self.destination, kind, self.archive, revision, environment)
            self.assertFalse(self.destination.exists())

    def test_missing_prepared_input_fails_instead_of_uploading_partial_bundle(self):
        (self.source / "target/ci-tools/bin/xcodegen").unlink()
        with self.assertRaisesRegex(ValueError, "Missing swift"):
            self.pack()
        self.assertFalse(self.archive.exists())

    def test_media_bundle_keeps_corresponding_sources_but_omits_unpacking_tree(self):
        directories = {
            "target/media-tools",
            "target/playback-engine/VLCKit.framework",
            "target/playback-engine/licenses",
        }
        for name in inputs.BUNDLES["media"]:
            path = self.source / name
            if name in directories:
                path.mkdir(parents=True, exist_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"notice or fingerprint")
        sources = self.source / "target/media-tools/sources/playback"
        sources.mkdir(parents=True)
        (sources / "vlc-source.tar.xz").write_bytes(b"corresponding source")
        unpacked = self.source / "target/playback-engine/unpacked"
        unpacked.mkdir()
        (unpacked / "unneeded-build-input").write_bytes(b"not a runtime input")
        inputs.pack(self.source, "media", self.archive, "commit-a", "sdk-a")
        inputs.restore(self.destination, "media", self.archive, "commit-a", "sdk-a")
        self.assertEqual(
            (
                self.destination / "target/media-tools/sources/playback/vlc-source.tar.xz"
            ).read_bytes(),
            b"corresponding source",
        )
        self.assertFalse((self.destination / "target/playback-engine/unpacked").exists())

    def test_unexpected_or_traversing_member_is_rejected(self):
        for name in ("../outside", "/outside", ".github/workflows/test.yml"):
            with tarfile.open(self.archive, "w:gz") as archive:
                data = json.dumps(
                    {"schema": 1, "kind": "swift", "revision": "commit-a", "environment": "sdk-a"}
                ).encode()
                manifest = tarfile.TarInfo(inputs.MANIFEST)
                manifest.size = len(data)
                archive.addfile(manifest, io.BytesIO(data))
                archive.addfile(tarfile.TarInfo(name))
            with self.assertRaisesRegex(ValueError, "Unexpected"):
                inputs.restore(self.destination, "swift", self.archive, "commit-a", "sdk-a")

    def test_sdk_or_toolchain_changes_change_environment_key(self):
        with patch(
            "ci_build_inputs.subprocess.check_output", side_effect=["Xcode 16.4", "15.5", "24F74"]
        ):
            first = inputs.environment_key()
        with patch(
            "ci_build_inputs.subprocess.check_output", side_effect=["Xcode 16.4", "15.6", "24G84"]
        ):
            second = inputs.environment_key()
        self.assertNotEqual(first, second)

    def test_link_cannot_redirect_extraction_into_checkout_source(self):
        with tarfile.open(self.archive, "w:gz") as archive:
            data = json.dumps(
                {"schema": 1, "kind": "swift", "revision": "commit-a", "environment": "sdk-a"}
            ).encode()
            manifest = tarfile.TarInfo(inputs.MANIFEST)
            manifest.size = len(data)
            archive.addfile(manifest, io.BytesIO(data))
            link = tarfile.TarInfo("ParakattCore/redirect")
            link.type = tarfile.SYMTYPE
            link.linkname = "../.github"
            archive.addfile(link)
        with self.assertRaisesRegex(ValueError, "Unexpected build-input link"):
            inputs.restore(self.destination, "swift", self.archive, "commit-a", "sdk-a")
        self.assertFalse(self.destination.exists())


if __name__ == "__main__":
    unittest.main()
