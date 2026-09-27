#!/usr/bin/env python3
"""Exercise bundled tools, media decoding, local STT and history with an isolated PATH."""
import argparse, json, os, pathlib, subprocess, tempfile
parser=argparse.ArgumentParser()
parser.add_argument('app',type=pathlib.Path)
parser.add_argument('media',type=pathlib.Path)
parser.add_argument('--models',type=pathlib.Path)
parser.add_argument('--output',type=pathlib.Path)
parser.add_argument('--playback', action='store_true', help='Check playback preparation, decoded frames, seeking and cache reuse without transcribing')
args=parser.parse_args()
with tempfile.TemporaryDirectory(prefix='parakatt-media-smoke-') as directory:
    env=dict(os.environ,PARAKATT_SMOKE_TEST='1',PARAKATT_DATA_ROOT=directory,PARAKATT_SMOKE_MEDIA=str(args.media.resolve()),PATH='/usr/bin:/bin:/usr/sbin:/sbin',HOME=directory)
    if args.playback:
        env.pop('PARAKATT_SMOKE_MEDIA')
        env['PARAKATT_SMOKE_PLAYBACK']=str(args.media.resolve())
    if args.models: env['PARAKATT_SMOKE_MODEL_ROOT']=str(args.models.resolve())
    with (pathlib.Path(directory)/'run.log').open('w') as output:
        completed=subprocess.run([str(args.app.resolve()/'Contents/MacOS/Parakatt')],env=env,stdout=output,stderr=output,timeout=1800)
    report=json.loads((pathlib.Path(directory)/'startup.json').read_text())
    section, state = ('playback', 'ready') if args.playback else ('media', 'completed')
    if completed.returncode or 'error' in report or report.get(section,{}).get('state')!=state:
        raise SystemExit(json.dumps(report,indent=2))
    if not args.playback and report['media']['max_audio_samples']>480000: raise SystemExit('Audio buffer exceeded its bound')
    if args.output: args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
