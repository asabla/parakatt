"""Offline checks for version integrity and release DMG checksum handling."""
import hashlib
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

from prepare_homebrew import cask_for_dmg, update_tap
from prepare_release import prepare
from release_version import synchronize


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        source = Path(__file__).resolve().parents[1]
        for name in ("VERSION", "BUILD_NUMBER", "project.yml", "Parakatt/Info.plist",
                     "crates/parakatt-core/Cargo.toml", "Cargo.lock", "homebrew/parakatt.rb",
                     "RELEASE_NOTES.md", "CHANGELOG.md"):
            dest = self.root / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source / name, dest)
        self.version = (self.root / "VERSION").read_text().strip()
        self.build = int((self.root / "BUILD_NUMBER").read_text())
        parts = list(map(int, self.version.split('.')))
        parts[-1] += 1
        self.next_version = '.'.join(map(str, parts))

    def snapshot(self):
        return {path.relative_to(self.root): path.read_bytes() for path in self.root.rglob('*') if path.is_file()}

    def test_bump_keeps_dependencies_and_cask_unchanged(self):
        cask = (self.root / "homebrew/parakatt.rb").read_bytes()
        manifest = (self.root / "crates/parakatt-core/Cargo.toml").read_text()
        lock = (self.root / "Cargo.lock").read_text()
        synchronize(self.root, self.next_version)
        self.assertEqual(synchronize(self.root, check=True), (self.next_version, str(self.build + 1)))
        self.assertEqual((self.root / "crates/parakatt-core/Cargo.toml").read_text(),
                         manifest.replace(f'version = "{self.version}"', f'version = "{self.next_version}"', 1))
        self.assertEqual((self.root / "Cargo.lock").read_text(),
                         lock.replace(f'name = "parakatt-core"\nversion = "{self.version}"',
                                      f'name = "parakatt-core"\nversion = "{self.next_version}"'))
        self.assertEqual((self.root / "homebrew/parakatt.rb").read_bytes(), cask)

    def test_sync_same_version_does_not_bump_build(self):
        before = self.snapshot()
        synchronize(self.root)
        self.assertEqual(self.snapshot(), before)

    def test_check_detects_stale_lock_without_writing(self):
        lock = self.root / "Cargo.lock"
        lock.write_text(lock.read_text().replace(f'name = "parakatt-core"\nversion = "{self.version}"',
                                                'name = "parakatt-core"\nversion = "0.0.1"'))
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, "Cargo.lock"):
            synchronize(self.root, check=True)
        self.assertEqual(self.snapshot(), before)

    def test_invalid_versions_do_not_write(self):
        before = self.snapshot()
        for version in ('v1.0.0', '01.0.0', '1.0.0\n', '1.0.0-beta', '1/0/0', '1.0;echo bad'):
            with self.subTest(version=version), self.assertRaises(ValueError):
                synchronize(self.root, version)
            self.assertEqual(self.snapshot(), before)

    def test_build_number_must_increase_for_new_version(self):
        before = self.snapshot()
        with self.assertRaises(ValueError):
            synchronize(self.root, self.next_version, str(self.build))
        with self.assertRaises(ValueError):
            synchronize(self.root, build_number='0')
        with self.assertRaises(ValueError):
            synchronize(self.root, '0.0.1')
        self.assertEqual(self.snapshot(), before)

    def test_missing_field_does_not_partially_sync(self):
        lock = self.root / "Cargo.lock"
        lock.write_text(lock.read_text().replace('name = "parakatt-core"', 'name = "missing"'))
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, "locked Rust package version"):
            synchronize(self.root, self.next_version)
        self.assertEqual(self.snapshot(), before)

    def test_tag_and_release_notes_must_match(self):
        synchronize(self.root, check=True, tag=f'v{self.version}')
        with self.assertRaisesRegex(ValueError, "Tag"):
            synchronize(self.root, check=True, tag=f'v{self.next_version}')
        (self.root / "RELEASE_NOTES.md").write_text('# Parakatt 0.0.1\n')
        with self.assertRaisesRegex(ValueError, "Release notes"):
            synchronize(self.root, check=True, tag=f'v{self.version}')
        (self.root / "RELEASE_NOTES.md").write_text('')
        with self.assertRaisesRegex(ValueError, "Release notes"):
            synchronize(self.root, check=True, tag=f'v{self.version}')

    def test_cask_checksum_comes_from_supplied_dmg(self):
        dmg = self.root / f'Parakatt-{self.version}-arm64.dmg'
        data = b'exact release asset bytes'
        dmg.write_bytes(data)
        before = (self.root / "homebrew/parakatt.rb").read_bytes()
        cask = cask_for_dmg(self.root, dmg)
        self.assertIn(f'version "{self.version}"', cask)
        self.assertIn(f'sha256 "{hashlib.sha256(data).hexdigest()}"', cask)
        self.assertEqual((self.root / "homebrew/parakatt.rb").read_bytes(), before)
        wrong = self.root / 'Parakatt-0.0.1-arm64.dmg'
        wrong.write_bytes(data)
        with self.assertRaisesRegex(ValueError, "filename"):
            cask_for_dmg(self.root, wrong)

    def test_tap_update_requires_credential_before_api_call(self):
        with patch.dict('os.environ', {}, clear=True), patch('prepare_homebrew.api') as api:
            with self.assertRaisesRegex(ValueError, "GH_TOKEN"):
                update_tap(self.version, 'cask')
            api.assert_not_called()

    def test_tap_update_does_not_write_when_cask_already_matches(self):
        import base64
        cask = 'same published cask'
        with patch.dict('os.environ', {'GH_TOKEN': 'test-token'}), patch('prepare_homebrew.api') as api:
            api.side_effect = [{'default_branch': 'main'}, {'content': base64.b64encode(cask.encode()).decode()}]
            update_tap(self.version, cask)
            self.assertEqual(api.call_count, 2)
            self.assertTrue(all(call.args[1:] == () for call in api.call_args_list))

    def test_missing_asset_stops_metadata_generation(self):
        dist = self.root / 'dist'
        dist.mkdir()
        with patch('prepare_release.subprocess.run') as run:
            with self.assertRaisesRegex(ValueError, 'Missing release asset'):
                prepare(self.root, dist)
            run.assert_not_called()
        self.assertEqual(list(dist.iterdir()), [])

    def test_failed_dmg_verification_stops_metadata_generation(self):
        import subprocess
        dist = self.root / 'dist'
        dist.mkdir()
        for suffix in ('arm64.dmg', 'arm64.zip', 'media-sources.zip'):
            (dist / f'Parakatt-{self.version}-{suffix}').write_bytes(b'asset')
        with patch('prepare_release.subprocess.run', side_effect=subprocess.CalledProcessError(1, 'hdiutil')):
            with self.assertRaises(subprocess.CalledProcessError):
                prepare(self.root, dist)
        self.assertFalse((dist / 'SHA256SUMS').exists())
        self.assertFalse((dist / 'parakatt.rb').exists())


if __name__ == '__main__':
    unittest.main()
