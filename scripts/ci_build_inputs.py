#!/usr/bin/env python3
"""Transfer prepared CI inputs without losing framework links or executable bits."""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import platform
import posixpath
import subprocess
import tarfile

BUNDLES = {
    "swift": (
        "ParakattCore",
        ".swift-package-fingerprint",
        "target/ci-tools/bin/xcodegen",
        "target/ci-tools/bin/swiftlint",
        "target/ci-tools/share/xcodegen/SettingPresets",
    ),
    "media": (
        "target/media-tools",
        "target/playback-engine/VLCKit.framework",
        "target/playback-engine/COPYING.txt",
        "target/playback-engine/licenses",
        "target/playback-engine/stamp",
    ),
}
MANIFEST = "ci-inputs.json"


def environment_key():
    values = {
        "architecture": platform.machine(),
        "deployment_target": os.environ.get("MACOSX_DEPLOYMENT_TARGET", "14.0"),
    }
    for name, command in (
        ("xcode", ["xcodebuild", "-version"]),
        ("sdk", ["xcrun", "--sdk", "macosx", "--show-sdk-version"]),
        ("sdk_build", ["xcrun", "--sdk", "macosx", "--show-sdk-build-version"]),
    ):
        values[name] = subprocess.check_output(command, text=True).strip()
    return hashlib.sha256(json.dumps(values, sort_keys=True).encode()).hexdigest()


def pack(root, kind, destination, revision, environment):
    for name in BUNDLES[kind]:
        if not (root / name).exists():
            raise ValueError(f"Missing {kind} build input: {name}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    metadata = json.dumps(
        {"schema": 1, "kind": kind, "revision": revision, "environment": environment},
        sort_keys=True,
    ).encode()
    # Tar preserves native framework symlinks and permissions; raw artifact
    # directory uploads do not. Compression level 1 avoids spending CI on gzip.
    with tarfile.open(destination, "w:gz", compresslevel=1, dereference=False) as archive:
        entry = tarfile.TarInfo(MANIFEST)
        entry.size = len(metadata)
        archive.addfile(entry, io.BytesIO(metadata))
        for name in BUNDLES[kind]:
            archive.add(root / name, arcname=name)


def restore(root, kind, source, revision, environment):
    with tarfile.open(source, "r:gz") as archive:
        manifest = archive.extractfile(MANIFEST)
        if manifest is None:
            raise ValueError("Missing build-input manifest")
        metadata = json.load(manifest)
        expected = {"schema": 1, "kind": kind, "revision": revision, "environment": environment}
        if metadata != expected:
            raise ValueError("Build inputs do not match this commit, environment, or bundle")
        members = []
        for entry in archive.getmembers():
            if entry.name == MANIFEST:
                continue
            path = PurePosixPath(entry.name)
            if (
                path.is_absolute()
                or ".." in path.parts
                or not any(
                    path == PurePosixPath(name) or PurePosixPath(name) in path.parents
                    for name in BUNDLES[kind]
                )
            ):
                raise ValueError(f"Unexpected build-input path: {entry.name}")
            if entry.issym() or entry.islnk():
                target = PurePosixPath(entry.linkname)
                if entry.issym():
                    target = path.parent / target
                target = PurePosixPath(posixpath.normpath(str(target)))
                if target.is_absolute() or not any(
                    target == PurePosixPath(name) or PurePosixPath(name) in target.parents
                    for name in BUNDLES[kind]
                ):
                    raise ValueError(f"Unexpected build-input link: {entry.name}")
            members.append(entry)
        archive.extractall(root, members=members, filter="data")
    for name in BUNDLES[kind]:
        if not (root / name).exists():
            raise ValueError(f"Incomplete {kind} build inputs: {name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("environment")
    for name in ("pack", "restore"):
        command = commands.add_parser(name)
        command.add_argument("kind", choices=BUNDLES)
        command.add_argument("archive", type=Path)
        command.add_argument("--revision", required=True)
        command.add_argument("--environment", required=True)
    args = parser.parse_args()
    if args.command == "environment":
        print(f"environment={environment_key()}")
    else:
        operation = pack if args.command == "pack" else restore
        operation(
            Path(__file__).resolve().parents[1],
            args.kind,
            args.archive,
            args.revision,
            args.environment,
        )


if __name__ == "__main__":
    main()
