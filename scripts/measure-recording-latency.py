#!/usr/bin/env python3
"""Measure actual app stop/final paths with isolated, attributed audio replay."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
parser.add_argument('--models', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--trials', type=int, default=5)
parser.add_argument('--fixtures', type=Path, default=ROOT / 'target/fixtures/fleurs/manifest.json')
args = parser.parse_args()
if not 1 <= args.trials <= 20:
    parser.error('trials must be 1 through 20')
args.output.mkdir(parents=True, exist_ok=True)
app = args.app.resolve()
ffmpeg = app / 'Contents/Helpers/MediaTools/ffmpeg'
manifest = json.loads(args.fixtures.read_text())
fixtures = []
for language in ('en_us', 'sv_se'):
    sample = next(s for s in manifest['samples'] if s['language'] == language)
    audio = Path(sample['path'])
    assert hashlib.sha256(audio.read_bytes()).hexdigest() == sample['sha256']
    for seconds, incremental in ((3, False), (8, True), (20, True)):
        path = args.output.resolve() / f'{language}-{seconds}s.f32'
        subprocess.run([str(ffmpeg), '-v', 'error', '-y', '-stream_loop', '-1', '-i', str(audio),
                        '-t', str(seconds), '-ar', '16000', '-ac', '1', '-f', 'f32le', str(path)], check=True)
        fixtures.append(dict(id=f'{language}-{seconds}s', path=str(path), incremental=incremental,
                             source_id=sample['id'], source_sha256=sample['sha256'],
                             audio_sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
fixture_manifest = args.output.resolve() / 'fixtures.json'
fixture_manifest.write_text(json.dumps(fixtures, indent=2) + '\n')
reports = {}
for backend in ('cpu', 'automatic'):
    output = args.output.resolve() / f'{backend}.json'
    with tempfile.TemporaryDirectory(prefix='parakatt-stop-latency-') as directory:
        env = dict(os.environ, PARAKATT_STOP_LATENCY=str(output), PARAKATT_DATA_ROOT=directory,
                   PARAKATT_FIXTURE_MODELS=str(args.models.resolve()), PARAKATT_LATENCY_FIXTURES=str(fixture_manifest),
                   PARAKATT_LATENCY_BACKEND=backend, PARAKATT_LATENCY_TRIALS=str(args.trials))
        env.pop('PARAKATT_SMOKE_TEST', None)
        with (args.output / f'{backend}.log').open('w') as log:
            result = subprocess.run([str(app / 'Contents/MacOS/Parakatt')], env=env, stdout=log, stderr=log, timeout=900)
        report = json.loads(output.read_text())
        if result.returncode or not report['completed']:
            raise RuntimeError(f'{backend} replay failed: {report.get("error", result.returncode)}; see log')
        reports[backend] = report
summary = {}
for backend, report in reports.items():
    summary[backend] = {}
    for fixture in fixtures:
        summary[backend][fixture['id']] = {}
        for preview in (False, True):
            rows = [r for r in report['observations'] if r['fixture'] == fixture['id'] and r['preview'] == preview]
            assert len(rows) == args.trials
            summary[backend][fixture['id']]['preview' if preview else 'alone'] = {
                'median_seconds': statistics.median(r['stop_to_final_state_seconds'] for r in rows),
                'max_seconds': max(r['stop_to_final_state_seconds'] for r in rows),
                'median_control_seconds': statistics.median(r['control_return_seconds'] for r in rows),
                'trials': len(rows),
            }
receipt = dict(commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
               dirty=bool(subprocess.check_output(['git', 'status', '--porcelain'], text=True).strip()),
               launcher_sha256=hashlib.sha256((app / 'Contents/MacOS/Parakatt').read_bytes()).hexdigest(),
               framework_sha256=hashlib.sha256((app / 'Contents/Frameworks/ParakattApp.framework/ParakattApp').read_bytes()).hexdigest(),
               core_framework_sha256=hashlib.sha256((app / 'Contents/Frameworks/parakatt_coreFFI.framework/parakatt_coreFFI').read_bytes()).hexdigest(),
               runtime_lock_sha256=hashlib.sha256((ROOT / 'Cargo.lock').read_bytes()).hexdigest(),
               model_manifest_sha256=hashlib.sha256((ROOT / 'crates/parakatt-core/model-manifests.json').read_bytes()).hexdigest(),
               native_runtime_sha256=sorted({hashlib.sha256(p.read_bytes()).hexdigest() for p in app.rglob('libwebgpu_dawn.dylib')}),
               fixture_sha256=hashlib.sha256(fixture_manifest.read_bytes()).hexdigest(),
               fixture_content_sha256=hashlib.sha256(json.dumps([{k: v for k, v in f.items() if k != 'path'} for f in fixtures], sort_keys=True).encode()).hexdigest(),
               hardware=subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip(),
               physical_capture=False, summary=summary)
(args.output / 'summary.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(summary, indent=2))
