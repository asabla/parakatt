#!/usr/bin/env python3
"""Check release layout, deployment targets, and the stable launcher identity."""
import argparse
from pathlib import Path
import re
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("app", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
app = args.app.resolve()
subprocess.run(["python3", str(root / "scripts/verify-launcher.py"), str(app / "Contents/MacOS/Parakatt")], check=True)
failures, binaries = [], []
for path in app.rglob("*"):
    if path.is_symlink() or not path.is_file(): continue
    with path.open("rb") as stream: magic = stream.read(4)
    if magic not in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe"): continue
    binaries.append(path)
    build = subprocess.check_output(["xcrun", "vtool", "-show-build", str(path)], text=True)
    for version in re.findall(r"minos\s+([\d.]+)", build):
        parts = tuple(map(int, version.split(".")))
        if parts > (14, 0): failures.append(f"{path.name} requires macOS {version}")
    links = subprocess.check_output(["otool", "-L", str(path)], text=True).splitlines()[1:]
    for link in links:
        if not link[:1].isspace(): continue  # Universal binaries repeat an architecture header.
        name = link.strip().split(" (", 1)[0]
        if name.startswith("/") and not name.startswith(("/System/Library/", "/usr/lib/")):
            failures.append(f"Non-system absolute library dependency: {name}")
        if "libwebgpu_dawn" in name and not list(app.rglob("libwebgpu_dawn.dylib")):
            failures.append("WebGPU native runtime is missing from the app")
if not binaries: failures.append("No app binaries found")
if failures: raise SystemExit("\n".join(failures))
print(f"Verified {len(binaries)} Mach-O binaries and macOS 14 deployment targets")

helpers = app / "Contents/Helpers/MediaTools"
for name in ("yt-dlp", "deno", "ffmpeg", "ffprobe"):
    helper = helpers / name
    if not helper.is_file(): raise SystemExit(f"Missing bundled media tool: {name}")
    subprocess.run(["codesign", "--verify", str(helper)], check=True)
if not (app / "Contents/Resources/MediaTools/licenses").is_dir(): raise SystemExit("Missing media license notices")
print("Verified self-contained media tool layout")
