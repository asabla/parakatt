#!/usr/bin/env python3
"""Check the sealed app bundle, release layout, and deployment targets."""

import argparse
from pathlib import Path
import plistlib
import re
import subprocess

from macos_signing import APP_ID, mach_o_files, verify_bundle

parser = argparse.ArgumentParser()
parser.add_argument("app", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
app = args.app.resolve()
with (app / "Contents/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
if info.get("CFBundleIdentifier") != APP_ID or info.get("CFBundleExecutable") != "Parakatt":
    raise SystemExit("Unexpected release bundle identity")
for field, filename in (
    ("CFBundleShortVersionString", "VERSION"),
    ("CFBundleVersion", "BUILD_NUMBER"),
):
    expected = (root / filename).read_text().strip()
    if info.get(field) != expected:
        raise SystemExit(f"Packaged {field} is {info.get(field)!r}; expected {expected!r}")
print("Verified packaged version and build number")
for key in ("NSMicrophoneUsageDescription", "NSAudioCaptureUsageDescription"):
    if not isinstance(info.get(key), str) or not info[key].strip():
        raise SystemExit("Missing capture permission description: " + key)
verify_bundle(app)
failures = []
binaries = list(mach_o_files(app))
has_webgpu_runtime = any(path.name == "libwebgpu_dawn.dylib" for path in binaries)
for path in binaries:
    build = subprocess.check_output(["xcrun", "vtool", "-show-build", str(path)], text=True)
    for version in re.findall(r"minos\s+([\d.]+)", build):
        parts = tuple(map(int, version.split(".")))
        if (*parts, 0)[:3] > (14, 0, 0):
            failures.append(f"{path.name} requires macOS {version}")
    links = subprocess.check_output(["otool", "-L", str(path)], text=True).splitlines()[1:]
    for link in links:
        if not link[:1].isspace():
            continue  # Universal binaries repeat an architecture header.
        name = link.strip().split(" (", 1)[0]
        if name.startswith("/") and not name.startswith(("/System/Library/", "/usr/lib/")):
            failures.append(f"Non-system absolute library dependency: {name}")
        if "libwebgpu_dawn" in name and not has_webgpu_runtime:
            failures.append("WebGPU native runtime is missing from the app")
if not binaries:
    failures.append("No app binaries found")
if failures:
    raise SystemExit("\n".join(failures))
print(f"Verified {len(binaries)} Mach-O binaries and macOS 14 deployment targets")

helpers = app / "Contents/Helpers/MediaTools"
for name in ("yt-dlp", "deno", "ffmpeg", "ffprobe"):
    helper = helpers / name
    if not helper.is_file():
        raise SystemExit(f"Missing bundled media tool: {name}")
    subprocess.run(["codesign", "--verify", str(helper)], check=True)
if not (app / "Contents/Resources/MediaTools/licenses").is_dir():
    raise SystemExit("Missing media license notices")
print("Verified self-contained media tool layout")

playback = app / "Contents/Frameworks/VLCKit.framework"
if not (playback / "VLCKit").is_file():
    raise SystemExit("Missing bundled video playback framework")
subprocess.run(["codesign", "--verify", "--strict", str(playback)], check=True)
for name in ("VLCKit-LGPL-2.1.txt",):
    if not (app / "Contents/Resources/MediaTools/licenses" / name).is_file():
        raise SystemExit("Missing playback license notice: " + name)
if not (app / "Contents/Resources/MediaTools/playback-engine.json").is_file():
    raise SystemExit("Missing playback engine version manifest")
print("Verified bundled playback engine and notices")
