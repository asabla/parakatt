#!/usr/bin/env python3
"""Start the packaged launcher with isolated data; do not request macOS permissions."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("app", type=Path)
parser.add_argument("--models", type=Path)
parser.add_argument("--expect-backend", choices=["cpu", "webgpu"])
parser.add_argument("--output", type=Path)
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix="parakatt-startup-") as directory:
    env = dict(os.environ, PARAKATT_SMOKE_TEST="1", PARAKATT_DATA_ROOT=directory)
    if args.models: env["PARAKATT_SMOKE_MODEL_ROOT"] = str(args.models.resolve())
    with (Path(directory) / "startup.log").open("w") as log:
        completed = subprocess.run([str(args.app.resolve() / "Contents/MacOS/Parakatt")], env=env, stdout=log, stderr=log, timeout=90)
    path = Path(directory) / "startup.json"
    if completed.returncode or not path.exists():
        raise SystemExit(f"Packaged app failed to start (exit {completed.returncode}). " + (Path(directory) / "startup.log").read_text()[-4000:])
    report = json.loads(path.read_text())
    if not report["started"]: raise SystemExit(json.dumps(report))
    if args.models and not report["model_loaded"]: raise SystemExit("Model failed to load")
    if args.expect_backend and report["actual_backend"] != args.expect_backend: raise SystemExit("Unexpected execution backend: " + report["actual_backend"])
    if args.output: args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
