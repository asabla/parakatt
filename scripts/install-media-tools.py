#!/usr/bin/env python3
"""Copy prepared tools into the app, without source archives or build dependencies."""
import pathlib, shutil, sys
root = pathlib.Path(__file__).resolve().parents[1]
source = root / 'target/media-tools'
if not (source / 'stamp').is_file():
    raise SystemExit('Run make media-tools before building Parakatt.')
app = pathlib.Path(sys.argv[1])
destination = app / 'Contents/Helpers/MediaTools'
destination.mkdir(parents=True, exist_ok=True)
for name in ['yt-dlp', 'deno', 'ffmpeg', 'ffprobe']:
    staged = destination / (name + '.stage')
    shutil.copy2(source / name, staged)
    staged.replace(destination / name)
old_licenses = destination / 'licenses'
if old_licenses.exists(): shutil.rmtree(old_licenses)
notices = app / 'Contents/Resources/MediaTools/licenses'
notices.mkdir(parents=True, exist_ok=True)
for notice in (source / 'licenses').iterdir():
    if notice.suffix in ('.py', '.rs', '.js', '.ts'): continue
    shutil.copy2(notice, notices / (notice.name + '.txt'))

for name in ['manifest.json', 'build-options.json']:
    stale = destination / name
    if stale.exists(): stale.unlink()
    shutil.copy2(source / name, notices.parent / name)
