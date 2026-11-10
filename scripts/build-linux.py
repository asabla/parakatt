#!/usr/bin/env python3
"""Build the Linux frontend's native library and matching Python bindings."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def runtime_environment():
    environment = os.environ.copy()
    if environment.get("ORT_LIB_PATH") or environment.get("ORT_LIB_LOCATION"):
        library = environment.get("ORT_LIB_PATH") or environment["ORT_LIB_LOCATION"]
        environment["LD_LIBRARY_PATH"] = library + (
            ":" + environment["LD_LIBRARY_PATH"] if environment.get("LD_LIBRARY_PATH") else ""
        )
        return environment
    manifest = json.loads((ROOT / "config/linux-runtime.json").read_text())
    if platform.machine() != "x86_64":
        raise RuntimeError(
            "Automatic ONNX installation supports x86_64; set ORT_LIB_PATH for your architecture"
        )
    cache = ROOT / "target/linux-runtime"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / "onnxruntime.tgz"
    if not archive.exists():
        partial = archive.with_suffix(".part")
        with (
            urllib.request.urlopen(manifest["url"], timeout=60) as source,
            partial.open("wb") as output,
        ):
            shutil.copyfileobj(source, output)
        partial.replace(archive)
    with archive.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != manifest["sha256"]:
            archive.unlink()
            raise RuntimeError("ONNX Runtime checksum mismatch; the archive was discarded")
    with tarfile.open(archive, "r:gz") as package:
        package.extractall(cache, filter="data")
    library = cache / manifest["directory"] / "lib"
    environment["ORT_LIB_PATH"] = str(library)
    environment["ORT_PREFER_DYNAMIC_LINK"] = "1"
    environment["LD_LIBRARY_PATH"] = str(library) + (
        ":" + environment["LD_LIBRARY_PATH"] if environment.get("LD_LIBRARY_PATH") else ""
    )
    return environment


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()
    if sys.platform != "linux":
        parser.error("This target builds the Linux desktop frontend")
    environment = runtime_environment()
    profile = [] if args.debug else ["--release"]
    subprocess.run(
        ["cargo", "build", "--locked", *profile, "-p", "parakatt-core"],
        cwd=ROOT,
        check=True,
        env=environment,
    )
    library = ROOT / "target" / ("debug" if args.debug else "release") / "libparakatt_core.so"
    destination = ROOT / "linux/parakatt_linux/_native"
    # Release artifacts intentionally strip symbols. UniFFI's ELF metadata
    # reader needs the unstripped symbol table, so generate from a matching
    # debug build while packaging the optimized library (ABI checks still apply).
    subprocess.run(
        ["cargo", "build", "--locked", "-p", "parakatt-core"], cwd=ROOT, check=True, env=environment
    )
    metadata_library = ROOT / "target/debug/libparakatt_core.so"
    (destination / "parakatt_core.py").unlink(missing_ok=True)
    subprocess.run(
        [
            "cargo",
            "run",
            "--locked",
            "-p",
            "parakatt-core",
            "--example",
            "uniffi_bindgen",
            "--",
            "generate",
            "--library",
            str(metadata_library),
            "--language",
            "python",
            "--out-dir",
            str(destination),
        ],
        cwd=ROOT,
        check=True,
        env=environment,
    )
    if not (destination / "parakatt_core.py").is_file():
        raise RuntimeError("UniFFI did not generate Python bindings")

    def copy_artifact(source, name):
        temporary = destination / (name + ".tmp")
        shutil.copy2(source, temporary)
        temporary.replace(destination / name)

    copy_artifact(library, library.name)
    # Bundling the selected dynamic runtime also makes wheels relocatable.
    runtime = environment.get("ORT_LIB_PATH") or environment.get("ORT_LIB_LOCATION")
    if runtime:
        candidates = sorted(Path(runtime).glob("libonnxruntime.so*"))
        if not candidates:
            candidates = sorted((Path(runtime) / "lib").glob("libonnxruntime.so*"))
        for candidate in candidates:
            copy_artifact(candidate, candidate.name)
        for name, installed in (
            ("LICENSE", "onnxruntime-LICENSE.txt"),
            ("ThirdPartyNotices.txt", "onnxruntime-ThirdPartyNotices.txt"),
        ):
            notice = Path(runtime).parent / name
            if notice.is_file():
                copy_artifact(notice, installed)
    print(f"Native frontend ready at {destination}")
    print("Install with: python3 -m pip install ./linux")


if __name__ == "__main__":
    main()
