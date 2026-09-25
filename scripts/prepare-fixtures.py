#!/usr/bin/env python3
"""Fetch the pinned FLEURS test subset without extracting arbitrary tar paths."""
import concurrent.futures
import csv
import hashlib
import io
import json
from pathlib import Path
import shutil
import tarfile
import urllib.request

REVISION = "70bb2e84b976b7e960aa89f1c648e09c59f894dd"
BASE = f"https://huggingface.co/datasets/google/fleurs/resolve/{REVISION}/data"
ROOT = Path(__file__).resolve().parents[1] / "target/fixtures/fleurs"
HASHES = {
    "en_us": "d9c2e37b41aacd41bc283554a0a82b5476b36887049774ecb2819dcaaa55a356",
    "sv_se": "3792fd432675e16d85a67f5caf9927ad608aefc2484d738f26704f75584a5a6f",
}


def prepare(language):
    destination = ROOT / language
    destination.mkdir(parents=True, exist_ok=True)
    text = urllib.request.urlopen(f"{BASE}/{language}/test.tsv", timeout=60).read().decode()
    rows = sorted(csv.reader(io.StringIO(text), delimiter="\t"), key=lambda r: (int(r[0]), r[1]))[:100]
    selected = {r[1]: r for r in rows}
    archive = destination / "test.tar.gz"
    if not archive.exists():
        temporary = archive.with_suffix(".part")
        with urllib.request.urlopen(f"{BASE}/{language}/audio/test.tar.gz", timeout=60) as response, temporary.open("wb") as output:
            shutil.copyfileobj(response, output)
        temporary.replace(archive)
    with archive.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != HASHES[language]:
            raise ValueError(f"Archive checksum mismatch: {archive}")
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar:
            name = Path(member.name).name
            if member.isfile() and name in selected:
                with tar.extractfile(member) as source, (destination / name).open("wb") as output:
                    shutil.copyfileobj(source, output)
    result = []
    for name, row in selected.items():
        audio = destination / name
        result.append({"id": f"{language}:{row[0]}:{name}", "language": language, "path": str(audio.resolve()), "reference": row[3], "sha256": hashlib.sha256(audio.read_bytes()).hexdigest()})
    return result


if __name__ == "__main__":
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        samples = [sample for group in executor.map(prepare, HASHES) for sample in group]
    (ROOT / "manifest.json").write_text(json.dumps({"dataset": "google/fleurs", "revision": REVISION, "license": "CC-BY-4.0", "samples": samples}, indent=2))
    print(f"Verified {len(samples)} fixtures: {ROOT / 'manifest.json'}")
