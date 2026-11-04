#!/usr/bin/env python3
"""Check output-only CLI recognition with two pinned public speech fixtures."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import wave


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def snapshot(root):
    return {str(p.relative_to(root)): digest(p) for p in root.rglob("*") if p.is_file()}


def check(binary, models, manifest):
    fixtures = json.loads(manifest.read_text())
    results = []
    with tempfile.TemporaryDirectory(prefix="parakatt-cli-smoke-") as temporary:
        root = Path(temporary)
        env = os.environ | {
            "XDG_DATA_HOME": str(root / "data"),
            "XDG_CONFIG_HOME": str(root / "config"),
        }
        (root / "config").mkdir()
        (root / "config/config.toml").write_text('sentinel = "must remain unchanged"\n')
        before = snapshot(root)
        for language in ("en_us", "sv_se"):
            fixture = next(s for s in fixtures["samples"] if s["language"] == language)
            audio = Path(fixture["path"]).resolve()
            assert digest(audio) == fixture["sha256"], "Fixture checksum mismatch"
            with wave.open(str(audio)) as wav:
                duration = wav.getnframes() / wav.getframerate()
            command = [str(binary), "--models-dir", str(models), "transcribe", str(audio)]
            runs = [subprocess.run(command + ["--format", fmt], cwd=root, env=env,
                                   capture_output=True, text=True, check=True, timeout=180)
                    for fmt in ("text", "json")]
            transcript = json.loads(runs[1].stdout)
            assert transcript["source"] == {"kind": "file", "path": str(audio)}
            assert transcript["backend"] == "cpu"
            assert transcript["model"] == "parakeet-tdt-0.6b-v3"
            assert transcript["text"].strip(), "Empty recognition result"
            assert runs[0].stdout == transcript["text"] + "\n", "Text/JSON results differ"
            assert abs(transcript["duration_secs"] - duration) < 0.0001
            assert transcript["segments"], "Missing sentence timestamps"
            previous = 0.0
            for segment in transcript["segments"]:
                start, end = segment["start_secs"], segment["end_secs"]
                assert math.isfinite(start) and math.isfinite(end)
                assert previous <= start <= end <= duration + 0.5
                assert segment["text"].strip()
                previous = end
            assert snapshot(root) == before, "CLI wrote application state"
            results.append({"fixture": fixture["id"], "audio_sha256": fixture["sha256"],
                            "duration_secs": duration, "segments": len(transcript["segments"]),
                            "text_sha256": hashlib.sha256(transcript["text"].encode()).hexdigest(),
                            "text_json_equal": True, "isolated_state_unchanged": True})
    return {"platform": platform.platform(), "architecture": platform.machine(),
            "binary_sha256": digest(binary), "backend": "cpu", "model": transcript["model"],
            "dataset": fixtures["dataset"], "revision": fixtures["revision"],
            "license": fixtures["license"], "results": results}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--models", required=True, type=Path)
    parser.add_argument("--fixtures", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    report = check(args.binary.resolve(), args.models.resolve(), args.fixtures.resolve())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Passed English/Swedish CPU file transcription: {args.output}")
