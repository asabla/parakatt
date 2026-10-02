"""Check the prepared app on macOS 14 with verified model and speech fixtures."""
import argparse
import json
from pathlib import Path
import platform
import subprocess
import sys

from media_tool_downloads import fetch_verified


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--output', type=Path, default=Path('target/macos14-validation'))
    args = parser.parse_args()
    version = subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip()
    if version.split('.')[0] != '14' or platform.machine() != 'arm64':
        parser.exit(1, 'This check requires macOS 14 on Apple Silicon\n')
    root = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    app = args.app.resolve()
    run(sys.executable, root / 'scripts/verify-app.py', app)
    manifests = json.loads((root / 'crates/parakatt-core/model-manifests.json').read_text())
    manifest = next(item for item in manifests if item['id'] == 'parakeet-tdt-0.6b-v3')
    models = output / 'models'
    destination = models / manifest['id'] / manifest['revision']
    destination.mkdir(parents=True, exist_ok=True)
    for spec in manifest['files']:
        url = f"https://huggingface.co/{manifest['repo']}/resolve/{manifest['revision']}/{manifest['subdirectory']}{spec['name']}"
        path = fetch_verified(url, destination / spec['name'], spec['sha256'], spec['name'])
        if path.stat().st_size != spec['size']:
            raise ValueError(f"Model file size mismatch: {spec['name']}")
    run(sys.executable, root / 'scripts/smoke-app.py', app, '--models', models,
        '--expect-backend', 'cpu', '--output', output / 'startup.json')
    run(sys.executable, root / 'scripts/prepare-fixtures.py', '--languages', 'en_us', 'sv_se',
        '--count', '1', '--output', output / 'fixtures')
    fixture_manifest = (output / 'fixtures/manifest.json').read_text()
    samples = json.loads(fixture_manifest)['samples']
    (output / 'fixture-manifest.json').write_text(fixture_manifest)
    ffmpeg = app / 'Contents/Helpers/MediaTools/ffmpeg'
    for sample in samples:
        language = sample['language']
        video = output / f'{language}.mkv'
        run(ffmpeg, '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=128x72:rate=10',
            '-i', sample['path'], '-c:v', 'mpeg4', '-c:a', 'flac', '-shortest', video)
        report = output / f'transcription-{language}.json'
        run(sys.executable, root / 'scripts/smoke-media.py', app, video, '--models', models,
            '--output', report)
        media = json.loads(report.read_text())['media']
        if media['characters'] == 0 or media['segments'] == 0 or media['srt_bytes'] == 0:
            raise ValueError(f'No recognized speech/subtitles for {language}')
    run(sys.executable, root / 'scripts/smoke-media.py', app, output / 'en_us.mkv',
        '--playback', '--headless', '--output', output / 'playback.json')
    (output / 'platform.json').write_text(json.dumps({
        'os': version, 'architecture': platform.machine(), 'model_revision': manifest['revision'],
        'video_output': 'headless', 'live_capture_tested': False,
        'installed_update_permissions_tested': False,
    }, indent=2) + '\n')
    print('macOS 14 candidate runtime checks passed')


if __name__ == '__main__':
    main()
