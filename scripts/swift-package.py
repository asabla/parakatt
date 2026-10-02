#!/usr/bin/env python3
"""Build bindings only when their complete build inputs change."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
TARGET = "aarch64-apple-darwin"


def fingerprint():
    digest = hashlib.sha256()
    paths = [ROOT / "Cargo.toml", ROOT / "Cargo.lock", ROOT / "rust-toolchain.toml", ROOT / "Makefile", Path(__file__)]
    paths += sorted((ROOT / "crates").rglob("*.rs"))
    paths += sorted((ROOT / "vendor").rglob("*.rs"))
    paths += sorted((ROOT / "vendor").rglob("Cargo.toml"))
    paths += sorted((ROOT / "crates").rglob("*.json"))
    paths += sorted((ROOT / "crates").rglob("Cargo.toml"))
    for path in paths:
        digest.update(str(path.relative_to(ROOT)).encode())
        digest.update(path.read_bytes())
    for command in (["rustc", "-Vv"], ["cargo", "swift", "--version"]):
        digest.update(subprocess.check_output(command))
    for key in ("RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS", "SDKROOT", "MACOSX_DEPLOYMENT_TARGET", "PARAKATT_SPEECH_FEATURES"):
        digest.update(f"{key}={os.environ.get(key, '')}".encode())
    digest.update(f"{TARGET}:release".encode())
    return digest.hexdigest()


def main():
    stamp = ROOT / ".swift-package-fingerprint"
    version = subprocess.check_output(["cargo", "swift", "--version"], text=True).strip()
    if version != "cargo-swift 0.11.1":
        raise RuntimeError("Install the pinned generator: cargo install cargo-swift --version 0.11.1 --locked")
    expected = fingerprint()
    if "--force" not in sys.argv and (ROOT / "ParakattCore").is_dir() and stamp.exists() and stamp.read_text() == expected:
        print("ParakattCore build inputs are unchanged")
        return
    # cargo-swift does not expose --locked. Interpose a narrow Cargo wrapper
    # for its build/metadata calls, while permitting ort-sys to obtain its
    # checksum-pinned native runtime (CARGO_NET_OFFLINE disables ORT linking).
    locked_tools = ROOT / "target/locked-tools"
    locked_tools.mkdir(parents=True, exist_ok=True)
    wrapper = locked_tools / "cargo"
    wrapper.write_text("#!/usr/bin/env python3\nimport os, sys\nargs = sys.argv[1:]\nif args and args[0] in ('build', 'metadata', 'check') and '--locked' not in args: args.insert(1, '--locked')\nos.execv(os.environ['PARAKATT_REAL_CARGO'], [os.environ['PARAKATT_REAL_CARGO']] + args)\n")
    wrapper.chmod(0o755)
    # A PATH entry can be a tool-manager shim. After PATH is changed, that shim
    # can resolve cargo back to this wrapper and loop. Use the selected Rust
    # toolchain's executable directly.
    sysroot = Path(subprocess.check_output(["rustc", "--print", "sysroot"], text=True).strip())
    real_cargo = sysroot / "bin/cargo"
    if not real_cargo.is_file():
        raise RuntimeError("The selected Rust toolchain does not contain cargo")
    env = dict(os.environ, PARAKATT_REAL_CARGO=str(real_cargo), CARGO=str(wrapper), PATH=str(locked_tools) + os.pathsep + os.environ["PATH"])
    env.pop("CARGO_NET_OFFLINE", None)
    crate = ROOT / "crates/parakatt-core"
    generated = crate / "ParakattCore"
    if generated.exists():
        shutil.rmtree(generated)
    features = os.environ.get("PARAKATT_SPEECH_FEATURES", "")
    if features not in ("", "webgpu"):
        raise ValueError("Supported speech build features: empty or webgpu")
    command = ["cargo", "swift", "package", "--release", "--accept-all", "--swift-tools-version", "5.9", "--bundle-identifier", "com.parakatt.core", "--platforms", "macos@14", "--name", "ParakattCore", "--target", TARGET]
    if features:
        command += ["--features", features]
    subprocess.run(command, cwd=crate, env=env, input="y\n", text=True, check=True)
    if features == "webgpu":
        native = ROOT / "target" / TARGET / "release/libwebgpu_dawn.dylib"
        if not native.is_file():
            raise RuntimeError("WebGPU runtime was not produced by the pinned ORT build")
        manifest = json.loads((ROOT / "crates/parakatt-core/native-runtime-manifest.json").read_text())
        if hashlib.sha256(native.read_bytes()).hexdigest() != manifest["native_sha256"]:
            raise RuntimeError("Native WebGPU runtime hash differs from its release manifest")
        for framework in generated.glob("*.xcframework/**/Versions/A"):
            runtime = framework / "Frameworks"
            runtime.mkdir(exist_ok=True)
            shutil.copy2(native, runtime / native.name)
            library = framework / framework.parents[1].stem
            subprocess.run(["install_name_tool", "-add_rpath", "@loader_path/Frameworks", str(library)], check=True)
            # Re-sign only generated framework code, never the stable launcher.
            subprocess.run(["codesign", "--force", "--sign", "-", str(runtime / native.name)], check=True)
            subprocess.run(["codesign", "--force", "--sign", "-", str(framework.parents[1])], check=True)
    destination = ROOT / "ParakattCore"
    if destination.exists():
        shutil.rmtree(destination)
    shutil.move(str(generated), destination)
    stamp.write_text(expected)


if __name__ == "__main__":
    main()
