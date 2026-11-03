#!/usr/bin/env python3
"""Fail closed when a candidate misses the required accuracy or latency gates."""
import argparse
import json
import math
import statistics
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("baseline", type=Path)
parser.add_argument("candidate", type=Path)
parser.add_argument("--acceleration", action="store_true")
parser.add_argument("--expected-backend", choices=["webgpu", "burnmetal", "nemometal"])
parser.add_argument("--allow-model-change", action="store_true", help="Compare an explicitly verified alternative export or model")
parser.add_argument("--output", type=Path)
args = parser.parse_args()
base, candidate = [json.loads(p.read_text()) for p in (args.baseline, args.candidate)]
failures = []
for label, report in (("baseline", base), ("candidate", candidate)):
    if report.get("schema_version") != 2:
        failures.append(f"{label} needs schema 2 provenance; rerun the benchmark")
    if report.get("model_files_verified") is not True:
        failures.append(f"{label} model files were not verified")
    for field in ("os_build", "fixture_manifest_sha256", "model_manifest_sha256", "runtime_lock_sha256", "binary_sha256"):
        if not report.get(field): failures.append(f"{label} is missing {field}")
    for row in report["observations"]:
        if any(not isinstance(row.get(key), (int, float)) or not math.isfinite(row[key]) or row[key] < 0 for key in ("inference_secs", "audio_secs", "errors", "words")):
            failures.append(f"{label} has invalid observations")
            break
if base.get("os_build") != candidate.get("os_build"):
    failures.append("OS builds differ")
if base.get("fixture_manifest_sha256") != candidate.get("fixture_manifest_sha256"):
    failures.append("Fixture files or references differ")
if not args.allow_model_change and base.get("model_manifest_sha256") != candidate.get("model_manifest_sha256"):
    failures.append("Model manifests differ; an alternative model requires --allow-model-change")
if base["dataset_revision"] != candidate["dataset_revision"]:
    failures.append("Dataset revisions differ")
if base["hardware"] != candidate["hardware"] or base["os"] != candidate["os"]:
    failures.append("Hardware or OS differs")
for label, report in (("baseline", base), ("candidate", candidate)):
    if report.get("screening", False): failures.append(f"{label} is a screening run")
    cold = [r for r in report["observations"] if r["phase"] == "cold"]
    if len(cold) != 3: failures.append(f"{label} needs three cold runs")
    for language in ("en_us", "sv_se"):
        rows = [r for r in report["observations"] if r["language"] == language and r["phase"] == "warm"]
        if len(rows) != 1000 or len({r["id"] for r in rows}) != 100 or len({r["run"] for r in rows}) != 10:
            failures.append(f"{label} needs 100 {language} fixtures in ten warm runs")
        for run in range(10):
            batch = [r for r in rows if r["run"] == run]
            if len(batch) != 100 or len({r["id"] for r in batch}) != 100:
                failures.append(f"{label} {language} warm run {run + 1} is incomplete or duplicated")
        if rows and all(math.isfinite(r["inference_secs"]) and r["inference_secs"] >= 0 for r in rows):
            times = sorted(r["inference_secs"] for r in rows)
            measured = {"wer": sum(r["errors"] for r in rows) / max(1, sum(r["words"] for r in rows)), "median_secs": statistics.median(times), "p95_secs": times[math.ceil(len(times) * .95) - 1]}
            if any(not math.isclose(report["summary"][language][key], value, rel_tol=1e-9, abs_tol=1e-12) for key, value in measured.items()):
                failures.append(f"{label} {language} summary differs from its observations")
for language in ("en_us", "sv_se"):
    identities = []
    for report in (base, candidate):
        identities.append({(r["id"], r["words"], r["audio_secs"]) for r in report["observations"] if r["language"] == language and r["phase"] == "warm"})
    if identities[0] != identities[1]: failures.append(f"{language} fixture identities or references differ")
expected_backend = args.expected_backend or ("webgpu" if args.acceleration else None)
if expected_backend:
    actual = {r.get("backend", "").replace("_", "").lower() for r in candidate["observations"]}
    if actual != {expected_backend}:
        failures.append(f"Acceleration observations must all use {expected_backend}; fallback is not acceleration evidence")
results = {}
for language in ("en_us", "sv_se"):
    before, after = base["summary"][language], candidate["summary"][language]
    accuracy = after["wer"] <= before["wer"]
    improvement = 1 - after["median_secs"] / before["median_secs"]
    tail = after["p95_secs"] <= before["p95_secs"]
    results[language] = dict(no_accuracy_regression=accuracy, median_improvement=improvement, p95_no_regression=tail)
    if not accuracy: failures.append(f"{language} word error rate regressed")
    if args.acceleration and (improvement < .10 or not tail): failures.append(f"{language} acceleration latency gate failed")
report = dict(passed=not failures, acceleration=args.acceleration, languages=results, failures=failures,
              baseline_binary=base["binary_sha256"], candidate_binary=candidate["binary_sha256"], expected_backend=expected_backend, allow_model_change=args.allow_model_change)
if args.output:
    args.output.write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
raise SystemExit(bool(failures))
