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
import tempfile
import re

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
    parser.add_argument("--model-id", default="parakeet-tdt-0.6b-v3")
    parser.add_argument("--backend", choices=["cpu", "webgpu"], default="cpu")
    parser.add_argument("--streaming", action="store_true")
    parser.add_argument("--subset", action="store_true", help="Allow a screening or edge-case fixture subset; never a release acceptance run")
    parser.add_argument("--threads", type=int, default=0)
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--fixtures", type=Path, default=ROOT / "target/fixtures/fleurs/manifest.json")
    parser.add_argument("--warm-runs", type=int, default=10)
    parser.add_argument("--cold-runs", type=int, default=3)
    args = parser.parse_args()
    if args.binary is None: args.binary = ROOT / "target/release/examples" / ("streaming_bench" if args.streaming else "model_bench")
    if args.warm_runs < 1 or args.cold_runs < 0 or args.threads < 0:
        parser.error("warm-runs must be positive; cold-runs and threads must be nonnegative")
    manifest = json.loads(args.fixtures.read_text())
    samples = manifest["samples"]
    assert args.subset or all(sum(s["language"] == language for s in samples) == 100 for language in ("en_us", "sv_se")), "Exactly 100 fixtures per required language are required"
    for sample in samples:
        assert hashlib.sha256(Path(sample["path"]).read_bytes()).hexdigest() == sample["sha256"]
    if not args.binary.exists():
        worker = "streaming_bench" if args.streaming else "model_bench"
        subprocess.run(["cargo", "build", "--locked", "--release", "--example", worker], cwd=ROOT, check=True)
        if not args.binary.exists(): raise FileNotFoundError(args.binary)
    provenance = {"commit": command("git", "rev-parse", "HEAD"), "dirty": bool(command("git", "status", "--porcelain")), "runtime_lock_sha256": hashlib.sha256((ROOT / "Cargo.lock").read_bytes()).hexdigest()}
    model_manifests = json.loads((ROOT / "crates/parakatt-core/model-manifests.json").read_text())
    model_manifests += json.loads((ROOT / "crates/parakatt-core/model-candidates.json").read_text())
    provenance["model_manifest"] = next(m for m in model_manifests if m["id"] == args.model_id)
    observations, loads = [], []
    worker_args = [str(args.binary), str(args.model), args.backend, str(args.threads)]
    for run in range(args.cold_runs + 1):
        memory_file = tempfile.NamedTemporaryFile(prefix="parakatt-memory-", delete=False)
        memory_file.close()
        process = subprocess.Popen(["/usr/bin/time", "-l", "-o", memory_file.name, *worker_args], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            line = process.stdout.readline()
            if not line: raise RuntimeError("Benchmark worker failed before model readiness; see its stderr")
            loads.append(json.loads(line))
            iterations = 1 if run < args.cold_runs else args.warm_runs
            for iteration in range(iterations):
                batch = samples[:1] if run < args.cold_runs else samples
                for sample in batch:
                    process.stdin.write((json.dumps(sample) if args.streaming else sample["path"]) + "\n")
                    process.stdin.flush()
                    result = json.loads(process.stdout.readline())
                    count, total = errors(sample["reference"], result["text"])
                    observations.append(dict(result, id=sample["id"], language=sample["language"], errors=count, words=total, phase="cold" if run < args.cold_runs else "warm", run=iteration))
                print(f"Completed {'cold' if run < args.cold_runs else 'warm'} run {(run if run < args.cold_runs else iteration) + 1}", flush=True)
            process.stdin.close()
            if process.wait() != 0:
                raise RuntimeError("benchmark worker failed")
            memory = re.search(r"(\d+)\s+maximum resident set size", Path(memory_file.name).read_text())
            loads[-1]["peak_memory_bytes"] = int(memory.group(1)) if memory else None
        finally:
            Path(memory_file.name).unlink(missing_ok=True)
            if process.poll() is None:
                process.kill()
                process.wait()
    summary = {}
    for language in sorted({s["language"] for s in samples}):
        rows = [r for r in observations if r["language"] == language and r["phase"] == "warm"]
        times = sorted(r["inference_secs"] for r in rows)
        summary[language] = {"wer": sum(r["errors"] for r in rows) / max(1, sum(r["words"] for r in rows)), "median_secs": statistics.median(times), "p95_secs": times[math.ceil(len(times) * .95) - 1], "real_time_factor": sum(times) / sum(r["audio_secs"] for r in rows)}
    report = {"commit": command("git", "rev-parse", "HEAD"), "dirty": bool(command("git", "status", "--porcelain")), "binary_sha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(), "os": platform.platform(), "hardware": command("sysctl", "-n", "machdep.cpu.brand_string"), "runtime_lock_sha256": hashlib.sha256((ROOT / "Cargo.lock").read_bytes()).hexdigest(), "dataset_revision": manifest["revision"], "model_directory": str(args.model), "loads": loads, "summary": summary, "observations": observations}
    report.update(provenance)
    report.update(cold_runs=args.cold_runs, warm_runs=args.warm_runs, screening=args.subset or args.warm_runs < 10 or args.cold_runs < 3, streaming=args.streaming, cpu_threads=args.threads, os_build=command("sysctl", "-n", "kern.osversion"))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.with_suffix(".json").write_text(json.dumps(report, indent=2))
    markdown = "# Speech benchmark\n\n" + f"Commit: {report['commit']} (dirty={report['dirty']})\n\n| Language | WER | Median seconds | p95 seconds | Real-time factor |\n|---|---:|---:|---:|---:|\n"
    for language, row in summary.items():
        markdown += f"| {language} | {row['wer']:.4f} | {row['median_secs']:.4f} | {row['p95_secs']:.4f} | {row['real_time_factor']:.4f} |\n"
    markdown += "\nCold runs use new processes; the OS file cache is not purged. Peak memory is the process maximum RSS from macOS time. Preview compute times exclude audio arrival; audio times report how much audio was available. UI latency requires separate Instruments measurements.\n"
    args.output.with_suffix(".md").write_text(markdown)


if __name__ == "__main__":
    main()
