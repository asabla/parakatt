#!/usr/bin/env python3
"""Build the pinned macOS media bundle. Build tools are never runtime dependencies."""
import base64, hashlib, json, os, pathlib, shutil, subprocess, sys, tarfile, zipfile
from media_tool_downloads import fetch_verified, verify
ROOT = pathlib.Path(__file__).resolve().parents[1]
DEST = ROOT / 'target/media-tools'
CACHE = ROOT / 'target/media-cache'
BUILD = ROOT / 'target/media-build'
LOCK = ROOT / 'config/media-tools.json'
manifest = json.loads(LOCK.read_text())
local_notices = b''.join((ROOT / spec['local_path']).read_bytes() for spec in manifest.values() if isinstance(spec, dict) and 'local_path' in spec)
fingerprint = hashlib.sha256(LOCK.read_bytes() + pathlib.Path(__file__).read_bytes() + (ROOT / "scripts/collect-deno-notices.py").read_bytes() + (ROOT / "scripts/media_tool_downloads.py").read_bytes() + local_notices).hexdigest()
if (DEST / 'stamp').exists() and (DEST / 'stamp').read_text() == fingerprint:
    sys.exit(0)
for directory in [DEST, CACHE, BUILD, DEST / 'licenses', DEST / 'sources']:
    directory.mkdir(parents=True, exist_ok=True)
def run(args, cwd=None, env=None):
    subprocess.run(list(map(str,args)), cwd=cwd, env=env, check=True)
def fetch(name):
    spec=manifest[name]
    if 'local_path' in spec:
        path=ROOT / spec['local_path']
        verify(path, spec['sha256'], name)
        return path
    path=CACHE / spec.get('filename', spec['url'].rsplit('/',1)[1])
    return fetch_verified(spec['url'], path, spec['sha256'], name)
shutil.copy2(fetch('yt-dlp'), DEST / 'yt-dlp')
with zipfile.ZipFile(fetch('deno')) as archive:
    (DEST / 'deno').write_bytes(archive.read('deno'))
for name in ['ffmpeg','dav1d']:
    archive=fetch(name)
    with tarfile.open(archive) as source:
        source.extractall(BUILD, filter='data')
    shutil.copy2(archive,DEST / 'sources' / archive.name)
ffmpeg=BUILD / ('ffmpeg-'+manifest['ffmpeg']['version'])
dav1d=BUILD / ('dav1d-'+manifest['dav1d']['version'])
venv=BUILD / 'venv'
if not (venv/'bin/meson').exists():
    run([sys.executable,'-m','venv',venv])
    run([venv/'bin/pip','install','meson==1.9.1','ninja==1.13.0','packaging==25.0'])
env=dict(os.environ)
env['PATH']=str(venv/'bin')+os.pathsep+env.get('PATH','')
env['MACOSX_DEPLOYMENT_TARGET']='14.0'
env['SDKROOT']=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
env['CC']=subprocess.check_output(['xcrun','--find','clang'],text=True).strip()
env['CFLAGS']='-mmacosx-version-min=14.0 -isysroot '+env['SDKROOT']
prefix=BUILD / 'prefix'
if not (prefix/'lib/libdav1d.a').exists():
    run([venv/'bin/meson','setup',dav1d/'build',dav1d,'--prefix='+str(prefix),'--default-library=static','--buildtype=release','-Denable_tools=false','-Denable_tests=false'],env=env)
    run([venv/'bin/meson','install','-C',dav1d/'build'],env=env)
# FFmpeg only needs this one pkg-config entry. Avoid any host package discovery.
pkg=BUILD/'pkg-config'
pkg.write_text('#!/bin/sh\ncase "$*" in\n*--cflags*) echo "-I'+str(prefix)+'/include";;\n*--libs*) echo "-L'+str(prefix)+'/lib -ldav1d";;\n*--modversion*) echo "'+manifest['dav1d']['version']+'";;\n*--version*) echo "1.0";;\n*--exists*|*--atleast-version*) exit 0;;\nesac\n')
pkg.chmod(0o755)
flags=['--disable-autodetect','--disable-doc','--disable-debug','--disable-shared','--enable-static','--disable-gpl','--disable-nonfree','--disable-network','--enable-videotoolbox','--enable-audiotoolbox','--enable-libdav1d','--arch=aarch64','--target-os=darwin','--cc=clang','--pkg-config='+str(pkg),'--extra-cflags=-mmacosx-version-min=14.0','--extra-ldflags=-mmacosx-version-min=14.0','--prefix='+str(prefix)]
run([ffmpeg/'configure',*flags],cwd=ffmpeg,env=env)
run(['make','-j',str(min(os.cpu_count() or 2,8))],cwd=ffmpeg,env=env)
for name in ['ffmpeg','ffprobe']:
    shutil.copy2(ffmpeg/name,DEST/name)
for name in ['yt-dlp','deno','ffmpeg','ffprobe']:
    (DEST/name).chmod(0o755)
    # Sign a fresh inode: rewriting an executable in place can retain stale code pages.
    staged = DEST / (name + '.signed')
    shutil.copyfile(DEST/name, staged)
    staged.chmod(0o755)
    args=['codesign','--force','--sign','-']
    if name=='deno': args+=['--options','runtime','--entitlements',str(ROOT/'config/media-runtime.entitlements')]
    run([*args,staged])
    staged.replace(DEST/name)
    run(['codesign','--verify',DEST/name])
for src,name in [(ffmpeg/'COPYING.LGPLv2.1','FFmpeg-LGPL-2.1.txt'),(dav1d/'COPYING','dav1d.txt')]:
    shutil.copy2(src,DEST/'licenses'/name)
# Binary distributions include third-party code. Keep exact upstream source notices.
for key in ['yt-dlp-notices','deno-notices']:
    if key in manifest:
        archive=fetch(key)
        shutil.copy2(archive,DEST/'sources'/archive.name)
        with tarfile.open(archive) as source:
            for member in source.getmembers():
                if member.isfile() and '/tests/' not in member.name and (pathlib.PurePosixPath(member.name).name.upper().startswith('LICENSE') or pathlib.PurePosixPath(member.name).name in ['COPYING','THIRD_PARTY_LICENSES.txt']):
                    data=source.extractfile(member).read()
                    (DEST/'licenses'/(key+'-'+member.name.replace('/','_'))).write_bytes(data)
for key, spec in manifest.items():
    if not key.startswith('native-notice-'): continue
    contents=fetch(key).read_bytes()
    if 'local_path' in spec:
        source=DEST / 'sources' / spec['local_path']
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_bytes(contents)
    if spec.get('encoding')=='base64': contents=base64.b64decode(contents)
    (DEST/'licenses'/(key+'.txt')).write_bytes(contents)
run([sys.executable,ROOT/'scripts/collect-deno-notices.py'])
shutil.copy2(ROOT/'scripts/collect-deno-notices.py',DEST/'sources/collect-deno-notices.py')
shutil.copy2(ROOT/'scripts/media_tool_downloads.py',DEST/'sources/media_tool_downloads.py')
(DEST/'build-options.json').write_text(json.dumps(flags,indent=2))
(DEST/'sources/build-options.json').write_text(json.dumps(flags,indent=2))
(DEST/'sources/README.txt').write_text('Corresponding sources for the bundled media tools. The FFmpeg and dav1d source archives are unmodified. Build options and pinned download hashes are included. To reproduce the application bundle, check out the matching Parakatt release, copy these archives to target/media-cache using the filenames in media-tools.json, and run make media-tools. The preparation script uses the selected Xcode SDK and builds for Apple Silicon and macOS 14.0. Build-only Python tools are installed in target/media-build/venv. No build tools are required on the end user system.\n')
shutil.copy2(LOCK,DEST/'manifest.json')
shutil.copy2(LOCK,DEST/'sources/media-tools.json')
shutil.copy2(ROOT/'config/media-runtime.entitlements',DEST/'sources/media-runtime.entitlements')
shutil.copy2(__file__,DEST/'sources/prepare-media-tools.py')
(DEST/'stamp').write_text(fingerprint)
print('Prepared pinned media tools:',DEST)
