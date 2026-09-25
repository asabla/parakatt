#!/usr/bin/env python3
"""Build bindings only when their complete build inputs change."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
TARGET = "aarch64-apple-darwin"


def fingerprint():
    digest = hashlib.sha256()
    paths = [ROOT / "Cargo.toml", ROOT / "Cargo.lock", ROOT / "Makefile", Path(__file__)]
    paths += sorted((ROOT / "crates").rglob("*.rs"))
    paths += sorted((ROOT / "crates").rglob("Cargo.toml"))
    for path in paths:
        digest.update(str(path.relative_to(ROOT)).encode())
        digest.update(path.read_bytes())
    for command in (["rustc", "-Vv"], ["cargo", "swift", "--version"]):
        digest.update(subprocess.check_output(command))
    for key in ("RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS", "SDKROOT", "MACOSX_DEPLOYMENT_TARGET"):
        digest.update(f"{key}={os.environ.get(key, '')}".encode())
    digest.update(f"{TARGET}:release".encode())
    return digest.hexdigest()


def main():
    stamp = ROOT / ".swift-package-fingerprint"
    expected = fingerprint()
    if "--force" not in sys.argv and (ROOT / "ParakattCore").is_dir() and stamp.exists() and stamp.read_text() == expected:
        print("ParakattCore build inputs are unchanged")
        return
    # cargo-swift runs Cargo internally. Offline mode prevents lockfile drift;
    # the preceding locked build obtains all required dependencies.
    env = dict(os.environ, CARGO_NET_OFFLINE="true")
    crate = ROOT / "crates/parakatt-core"
    generated = crate / "ParakattCore"
    if generated.exists():
        shutil.rmtree(generated)
    subprocess.run(["cargo", "swift", "package", "--platforms", "macos", "--name", "ParakattCore", "--target", TARGET], cwd=crate, env=env, input="y\n", text=True, check=True)
    destination = ROOT / "ParakattCore"
    if destination.exists():
        shutil.rmtree(destination)
    shutil.move(str(generated), destination)
    stamp.write_text(expected)


if __name__ == "__main__":
    main()
