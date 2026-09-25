#!/usr/bin/env python3
"""Measure pinned real speech, keeping raw observations for comparison."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import platform
import statistics
import subprocess
import unicodedata

ROOT = Path(__file__).resolve().parents[1]


def words(text):
    text = unicodedata.normalize("NFC", text).casefold()
    return "".join(c if c.isalnum() or c.isspace() or c == "'" else " " for c in text).split()


def errors(reference, hypothesis):
    a, b = words(reference), words(hypothesis)
    previous = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        row = [i]
        for j, y in enumerate(b, 1):
            row.append(min(row[-1] + 1, previous[j] + 1, previous[j - 1] + (x != y)))
        previous = row
    return previous[-1], len(a)


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--binary", type=Path, default=ROOT / "target/release/examples/model_bench")
    parser.add_argument("--fixtures", type=Path, default=ROOT / "target/fixtures/fleurs/manifest.json")
    parser.add_argument("--warm-runs", type=int, default=10)
    parser.add_argument("--cold-runs", type=int, default=3)
    args = parser.parse_args()
    manifest = json.loads(args.fixtures.read_text())
    samples = manifest["samples"]
    assert all(sum(s["language"] == language for s in samples) == 100 for language in ("en_us", "sv_se")), "Exactly 100 fixtures per required language are required"
    for sample in samples:
        assert hashlib.sha256(Path(sample["path"]).read_bytes()).hexdigest() == sample["sha256"]
    if not args.binary.exists():
        subprocess.run(["cargo", "build", "--locked", "--release", "--example", "model_bench"], cwd=ROOT, check=True)
    observations, loads = [], []
    for run in range(args.cold_runs + 1):
        process = subprocess.Popen([str(args.binary), str(args.model)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            loads.append(json.loads(process.stdout.readline()))
            iterations = 1 if run < args.cold_runs else args.warm_runs
            for iteration in range(iterations):
                batch = samples[:1] if run < args.cold_runs else samples
                for sample in batch:
                    process.stdin.write(sample["path"] + "\n")
                    process.stdin.flush()
                    result = json.loads(process.stdout.readline())
                    count, total = errors(sample["reference"], result["text"])
                    observations.append(dict(result, id=sample["id"], language=sample["language"], errors=count, words=total, phase="cold" if run < args.cold_runs else "warm", run=iteration))
                print(f"Completed {'cold' if run < args.cold_runs else 'warm'} run {iteration + 1}", flush=True)
            process.stdin.close()
            if process.wait() != 0:
                raise RuntimeError("benchmark worker failed")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
    summary = {}
    for language in ("en_us", "sv_se"):
        rows = [r for r in observations if r["language"] == language and r["phase"] == "warm"]
        times = sorted(r["inference_secs"] for r in rows)
        summary[language] = {"wer": sum(r["errors"] for r in rows) / sum(r["words"] for r in rows), "median_secs": statistics.median(times), "p95_secs": times[math.ceil(len(times) * .95) - 1], "real_time_factor": sum(times) / sum(r["audio_secs"] for r in rows)}
    report = {"commit": command("git", "rev-parse", "HEAD"), "dirty": bool(command("git", "status", "--porcelain")), "binary_sha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(), "os": platform.platform(), "hardware": command("sysctl", "-n", "machdep.cpu.brand_string"), "runtime_lock_sha256": hashlib.sha256((ROOT / "Cargo.lock").read_bytes()).hexdigest(), "dataset_revision": manifest["revision"], "model_directory": str(args.model), "loads": loads, "summary": summary, "observations": observations}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.with_suffix(".json").write_text(json.dumps(report, indent=2))
    markdown = "# Speech benchmark\n\n" + f"Commit: {report['commit']} (dirty={report['dirty']})\n\n| Language | WER | Median seconds | p95 seconds | Real-time factor |\n|---|---:|---:|---:|---:|\n"
    for language, row in summary.items():
        markdown += f"| {language} | {row['wer']:.4f} | {row['median_secs']:.4f} | {row['p95_secs']:.4f} | {row['real_time_factor']:.4f} |\n"
    markdown += "\nCold runs use new processes; the OS file cache is not purged. UI latency and memory require separate Instruments measurements.\n"
    args.output.with_suffix(".md").write_text(markdown)


if __name__ == "__main__":
    main()
