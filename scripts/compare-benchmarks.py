#!/usr/bin/env python3
"""Fail closed when a candidate misses the required accuracy or latency gates."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("baseline", type=Path)
parser.add_argument("candidate", type=Path)
parser.add_argument("--acceleration", action="store_true")
parser.add_argument("--output", type=Path)
args = parser.parse_args()
base, candidate = [json.loads(p.read_text()) for p in (args.baseline, args.candidate)]
failures = []
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
for language in ("en_us", "sv_se"):
    identities = []
    for report in (base, candidate):
        identities.append({(r["id"], r["words"], r["audio_secs"]) for r in report["observations"] if r["language"] == language and r["phase"] == "warm"})
    if identities[0] != identities[1]: failures.append(f"{language} fixture identities or references differ")
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
              baseline_binary=base["binary_sha256"], candidate_binary=candidate["binary_sha256"])
if args.output:
    args.output.write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
raise SystemExit(bool(failures))
