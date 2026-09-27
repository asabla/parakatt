#!/usr/bin/env python3
"""Prepare the pinned, dynamically linked macOS playback framework."""
import hashlib
import json
import pathlib
import shutil
import subprocess
import tarfile
from media_tool_downloads import fetch_verified

ROOT = pathlib.Path(__file__).resolve().parents[1]
LOCK = ROOT / 'config/playback-engine.json'
DEST = ROOT / 'target/playback-engine'
CACHE = ROOT / 'target/media-cache'
manifest = json.loads(LOCK.read_text())
fingerprint = hashlib.sha256(LOCK.read_bytes() + pathlib.Path(__file__).read_bytes() + (ROOT / 'scripts/media_tool_downloads.py').read_bytes()).hexdigest()
if (DEST / 'stamp').is_file() and (DEST / 'stamp').read_text() == fingerprint:
    raise SystemExit(0)
DEST.mkdir(parents=True, exist_ok=True)
CACHE.mkdir(parents=True, exist_ok=True)
sources = ROOT / 'target/media-tools/sources/playback'
sources.mkdir(parents=True, exist_ok=True)

def fetch(spec):
    return fetch_verified(spec['url'], CACHE / spec['filename'], spec['sha256'], spec['filename'])

with tarfile.open(fetch(manifest['binary'])) as archive:
    archive.extractall(DEST / 'unpacked', members=(m for m in archive.getmembers() if not any(p.startswith('._') for p in pathlib.PurePosixPath(m.name).parts)), filter='data')
package = DEST / 'unpacked/VLCKit - binary package'
framework = DEST / 'VLCKit.framework'
if framework.exists(): shutil.rmtree(framework)
shutil.copytree(package / 'VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework', framework, symlinks=True, ignore=shutil.ignore_patterns('._*'))
binary = framework / 'Versions/A/VLCKit'
subprocess.run(['lipo', str(binary), '-thin', 'arm64', '-output', str(binary) + '.thin'], check=True)
pathlib.Path(str(binary) + '.thin').replace(binary)
# A sibling framework must resolve through the app's Frameworks runpath.
subprocess.run(['install_name_tool', '-id', '@rpath/VLCKit.framework/Versions/A/VLCKit', str(binary)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(framework)], check=True)
shutil.copy2(package / 'COPYING.txt', DEST / 'COPYING.txt')
notices = DEST / 'licenses'
if notices.exists(): shutil.rmtree(notices)
notices.mkdir()
for spec in [*manifest['sources'].values(), *manifest['contrib'].values()]:
    archive = fetch(spec)
    shutil.copy2(archive, sources / archive.name)
    # Include upstream notices for the wrapper, libVLC and its static dependencies.
    # Full sources (including notices in source-file comments) ship separately.
    with tarfile.open(archive) as contents:
        for member in contents.getmembers():
            name = pathlib.PurePosixPath(member.name).name.upper()
            if member.isfile() and (name.startswith(('COPYING', 'LICENSE', 'NOTICE', 'COPYRIGHT')) or name == 'AUTHORS'):
                (notices / (archive.name + '-' + member.name.replace('/', '_') + '.txt')).write_bytes(contents.extractfile(member).read())
shutil.copy2(LOCK, sources / LOCK.name)
shutil.copy2(__file__, sources / pathlib.Path(__file__).name)
shutil.copy2(ROOT / 'scripts/media_tool_downloads.py', sources / 'media_tool_downloads.py')
(sources / 'README.txt').write_text(
    'VLCKit 3.7.3 is dynamically linked under LGPL 2.1 or later. The framework is unmodified except for arm64 thinning, its install name, and ad-hoc signing. '
    'The pinned VLCKit and libVLC source archives include upstream build scripts and libvlc/patches. Apply those patches to libVLC before building, as buildMobileVLCKit.sh does. '
    'Contrib archives cover the upstream macOS selection with host package detection disabled. Copy them to vlc/contrib/tarballs; versions and patches are in the libVLC contrib/src recipes. Build VLCKit with buildMobileVLCKit.sh -x. '
    'See the matching Parakatt release scripts/prepare-playback-engine.py and config/playback-engine.json for packaging. '
    'A compatible replacement VLCKit.framework can be copied to Parakatt.app/Contents/Frameworks and the app signed again. Library validation is disabled.\n')
(DEST / 'stamp').write_text(fingerprint)
print('Prepared bundled playback engine:', framework)
