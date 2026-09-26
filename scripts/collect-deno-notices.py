#!/usr/bin/env python3
"""Collect notices from Deno's exact Cargo.lock; verify every registry archive."""
import concurrent.futures, hashlib, io, json, pathlib, tarfile, time, tomllib, urllib.request
ROOT = pathlib.Path(__file__).resolve().parents[1]
manifest = json.loads((ROOT / 'config/media-tools.json').read_text())
archive = ROOT / 'target/media-cache' / manifest['deno-notices']['url'].rsplit('/', 1)[1]
with tarfile.open(archive) as source:
    member = next(m for m in source.getmembers() if m.name.count('/') == 1 and m.name.endswith('/Cargo.lock'))
    lock = tomllib.loads(source.extractfile(member).read().decode())
    typescript = next(m for m in source.getmembers() if m.name.endswith('/00_typescript.js'))
    copyright_header = source.extractfile(typescript).read(2000).split(b'var ts =')[0]
    (ROOT / 'target/media-tools/licenses/TypeScript-copyright.txt').write_bytes(copyright_header)
cache = ROOT / 'target/media-cache/deno-crates'
cache.mkdir(parents=True, exist_ok=True)
notices = ROOT / 'target/media-tools/licenses'
notices.mkdir(parents=True, exist_ok=True)

def collect(package):
    name, version = package['name'], package['version']
    filename = f'{name}-{version}.crate'
    path = cache / filename
    candidates = list((pathlib.Path.home() / '.cargo/registry/cache').glob('*/' + filename))
    if path.exists(): data = path.read_bytes()
    elif candidates: data = candidates[0].read_bytes()
    else:
        for attempt in range(4):
            try:
                with urllib.request.urlopen(f'https://static.crates.io/crates/{name}/{filename}', timeout=60) as response:
                    data = response.read()
                path.write_bytes(data)
                break
            except Exception:
                if attempt == 3: raise
                time.sleep(2 ** attempt)
    if hashlib.sha256(data).hexdigest() != package['checksum']:
        raise RuntimeError('Deno dependency checksum mismatch: ' + filename)
    parts = [f'Notice collection includes build-time and all-platform Cargo.lock dependencies, not only the runtime dependency set.\nDeno dependency: {name} {version}\nArchive SHA-256: {package["checksum"]}\n']
    with tarfile.open(fileobj=io.BytesIO(data)) as source:
        for item in source.getmembers():
            if not item.isfile(): continue
            base = pathlib.PurePosixPath(item.name).name.lower()
            if base.startswith(('license', 'copying', 'notice', 'copyright')) or (item.name.count('/') == 1 and base in ('cargo.toml', 'readme.md', 'readme')):
                content = source.extractfile(item).read()
                if b'\x00' not in content:
                    parts.append('\n--- ' + item.name + ' ---\n' + content.decode('utf-8', errors='replace'))
    (notices / f'deno-dependency-{name}-{version}.txt').write_text('\n'.join(parts))
    return {'name': name, 'version': version, 'sha256': package['checksum']}

packages = [p for p in lock['package'] if p.get('source', '').startswith('registry+')]
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    entries = list(pool.map(collect, packages))
(notices / 'deno-dependencies.json').write_text(json.dumps(entries, indent=2) + '\n')
print(f'Collected verified notices for {len(entries)} locked Deno dependencies')
