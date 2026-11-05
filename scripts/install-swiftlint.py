#!/usr/bin/env python3
"""Install the pinned SwiftLint binary after checking its archive digest."""

import hashlib
import io
from pathlib import Path
import urllib.request
import zipfile

VERSION = "0.65.1"
SHA256 = "c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0"


def main():
    root = Path(__file__).resolve().parents[1]
    destination = root / "target/tools/bin/swiftlint"
    url = f"https://github.com/realm/SwiftLint/releases/download/{VERSION}/portable_swiftlint.zip"
    with urllib.request.urlopen(url, timeout=120) as response:
        archive = response.read()
    if hashlib.sha256(archive).hexdigest() != SHA256:
        raise SystemExit("SwiftLint archive checksum mismatch")
    with zipfile.ZipFile(io.BytesIO(archive)) as package:
        binary = package.read("swiftlint")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(binary)
    destination.chmod(0o755)


if __name__ == "__main__":
    main()
