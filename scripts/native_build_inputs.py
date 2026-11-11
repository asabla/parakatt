#!/usr/bin/env python3
"""Hash native source/build inputs identically in CI and the local binding generator."""

import hashlib
from pathlib import Path

REQUIRED_FILES = (
    "Cargo.toml",
    "Cargo.lock",
    "rust-toolchain.toml",
    "scripts/build-native-core.sh",
    "scripts/swift-package.py",
    "scripts/native_build_inputs.py",
)
OPTIONAL_FILES = (".cargo/config", ".cargo/config.toml")
SOURCE_GLOBS = (
    "crates/**/*.rs",
    "crates/**/Cargo.toml",
    "crates/**/*.json",
    "crates/**/*.udl",
    "vendor/**/*.rs",
    "vendor/**/Cargo.toml",
)


def source_fingerprint(root):
    paths = {root / name for name in REQUIRED_FILES}
    paths.update(root / name for name in OPTIONAL_FILES if (root / name).is_file())
    for pattern in SOURCE_GLOBS:
        paths.update(root.glob(pattern))
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(str(path.relative_to(root)).encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


if __name__ == "__main__":
    print(f"native_sources={source_fingerprint(Path(__file__).resolve().parents[1])}")
