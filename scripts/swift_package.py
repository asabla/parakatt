"""Build the macOS package with the UniFFI generator pinned by Cargo.lock."""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

from native_build_inputs import source_fingerprint
from native_runtime import verify_webgpu

ROOT = Path(__file__).resolve().parents[1]
TARGET = "aarch64-apple-darwin"
FFI_MODULE = "parakatt_coreFFI"


def fingerprint():
    digest = hashlib.sha256()
    digest.update(source_fingerprint(ROOT).encode())
    digest.update(subprocess.check_output(["rustc", "-Vv"]))
    for key in (
        "RUSTFLAGS",
        "CARGO_ENCODED_RUSTFLAGS",
        "SDKROOT",
        "MACOSX_DEPLOYMENT_TARGET",
        "PARAKATT_SPEECH_FEATURES",
    ):
        digest.update(f"{key}={os.environ.get(key, '')}".encode())
    digest.update(f"{TARGET}:release".encode())
    return digest.hexdigest()


def build(root, features):
    if features not in ("", "webgpu"):
        raise ValueError("Supported speech build features: empty or webgpu")
    environment = dict(os.environ)
    environment.setdefault("MACOSX_DEPLOYMENT_TARGET", "14.0")
    environment.pop("CARGO_NET_OFFLINE", None)
    metadata = subprocess.check_output(
        ["cargo", "metadata", "--locked", "--no-deps", "--format-version", "1"],
        cwd=root,
        env=environment,
    )
    target = Path(json.loads(metadata)["target_directory"])
    feature_args = ["--features", features] if features else []
    subprocess.run(
        [
            "cargo",
            "build",
            "--locked",
            "--release",
            "-p",
            "parakatt-core",
            "--target",
            TARGET,
            *feature_args,
        ],
        cwd=root,
        env=environment,
        check=True,
    )
    library = target / TARGET / "release/libparakatt_core.dylib"
    with tempfile.TemporaryDirectory(prefix="swift-package-", dir=target) as directory:
        work = Path(directory)
        bindings = work / "bindings"
        subprocess.run(
            [
                "cargo",
                "run",
                "--locked",
                "-p",
                "parakatt-core",
                "--example",
                "uniffi_bindgen",
                *feature_args,
                "--",
                "generate",
                "--library",
                str(library),
                "--language",
                "swift",
                "--out-dir",
                str(bindings),
            ],
            cwd=root,
            env=environment,
            check=True,
        )
        package = work / "ParakattCore"
        sources = package / "Sources/ParakattCore"
        sources.mkdir(parents=True)
        swift_files = list(bindings.glob("*.swift"))
        if not swift_files:
            raise RuntimeError("UniFFI did not produce Swift bindings")
        for source in swift_files:
            shutil.copy2(source, sources / source.name)
        framework = work / f"{FFI_MODULE}.framework"
        content = framework / "Versions/A"
        for folder in ("Headers", "Modules", "Resources"):
            (content / folder).mkdir(parents=True)
        header = bindings / f"{FFI_MODULE}.h"
        shutil.copy2(header, content / "Headers" / header.name)
        modulemap = (bindings / f"{FFI_MODULE}.modulemap").read_text()
        (content / "Modules/module.modulemap").write_text(
            modulemap.replace("module ", "framework module ", 1)
        )
        binary = content / FFI_MODULE
        shutil.copy2(library, binary)
        subprocess.run(
            [
                "install_name_tool",
                "-id",
                f"@rpath/{FFI_MODULE}.framework/{FFI_MODULE}",
                str(binary),
            ],
            check=True,
        )
        with (content / "Resources/Info.plist").open("wb") as stream:
            plistlib.dump(
                {
                    "CFBundleExecutable": FFI_MODULE,
                    "CFBundleIdentifier": "com.parakatt.core",
                    "CFBundleInfoDictionaryVersion": "6.0",
                    "CFBundleName": FFI_MODULE,
                    "CFBundlePackageType": "FMWK",
                    "CFBundleShortVersionString": "1.0",
                    "CFBundleVersion": "1",
                    "CFBundleSupportedPlatforms": ["MacOSX"],
                    "LSMinimumSystemVersion": "14.0",
                },
                stream,
            )
        (framework / "Versions/Current").symlink_to("A")
        for name in ("Headers", "Modules", "Resources", FFI_MODULE):
            (framework / name).symlink_to(f"Versions/Current/{name}")
        if features == "webgpu":
            native = target / TARGET / "release/libwebgpu_dawn.dylib"
            manifest = json.loads(
                (root / "crates/parakatt-core/native-runtime-manifest.json").read_text()
            )
            verify_webgpu(root, native, manifest)
            runtime = content / "Frameworks"
            runtime.mkdir()
            shutil.copy2(native, runtime / native.name)
            subprocess.run(
                ["install_name_tool", "-add_rpath", "@loader_path/Frameworks", str(binary)],
                check=True,
            )
            subprocess.run(
                ["codesign", "--force", "--sign", "-", str(runtime / native.name)], check=True
            )
        subprocess.run(["codesign", "--force", "--sign", "-", str(framework)], check=True)
        subprocess.run(
            [
                "xcodebuild",
                "-create-xcframework",
                "-framework",
                str(framework),
                "-output",
                str(package / f"{FFI_MODULE}.xcframework"),
            ],
            check=True,
        )
        (package / "Package.swift").write_text(f'''// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ParakattCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ParakattCore", targets: ["ParakattCore"])],
    targets: [
        .binaryTarget(name: "{FFI_MODULE}", path: "{FFI_MODULE}.xcframework"),
        .target(name: "ParakattCore", dependencies: ["{FFI_MODULE}"])
    ]
)
''')
        destination = root / "ParakattCore"
        if destination.exists():
            shutil.rmtree(destination)
        shutil.move(str(package), destination)


def main():
    features = os.environ.get("PARAKATT_SPEECH_FEATURES", "")
    if features not in ("", "webgpu"):
        raise ValueError("Supported speech build features: empty or webgpu")
    stamp = ROOT / ".swift-package-fingerprint"
    expected = fingerprint()
    if (
        "--force" not in sys.argv
        and (ROOT / "ParakattCore").is_dir()
        and stamp.exists()
        and stamp.read_text() == expected
    ):
        print("ParakattCore build inputs are unchanged")
        return
    build(ROOT, features)
    stamp.write_text(expected)
