#!/usr/bin/env python3
"""Compare critical-module coverage with the base commit on the same toolchain."""

import json
import os
import pathlib
import re
import subprocess
import tempfile

from coverage_gate import POLICY, check_rust

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "target/coverage"


def run(*arguments, **kwargs):
    subprocess.run(arguments, check=True, **kwargs)


def measure(directory, report):
    env = dict(os.environ)
    env["CARGO_LLVM_COV_TARGET_DIR"] = str(ROOT / "target/llvm-cov-target")
    run(
        "cargo",
        "llvm-cov",
        "--locked",
        "--workspace",
        "--all-features",
        "--json",
        "--summary-only",
        "--output-path",
        str(report),
        cwd=directory,
        env=env,
    )


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    base = os.environ.get("COVERAGE_BASE_SHA")
    if base:
        if not re.fullmatch(r"[0-9a-f]{40}", base):
            raise ValueError("Coverage base must be a full commit SHA")
        run("git", "fetch", "--no-tags", "--depth=1", "origin", base, cwd=ROOT)
    else:
        base = subprocess.check_output(
            ["git", "merge-base", "HEAD", "origin/main"], cwd=ROOT, text=True
        ).strip()
    with tempfile.TemporaryDirectory(prefix="parakatt-coverage-") as temporary:
        checkout = pathlib.Path(temporary) / "base"
        run("git", "worktree", "add", "--detach", str(checkout), base, cwd=ROOT)
        try:
            measure(checkout, OUTPUT / "base-rust.json")
        finally:
            run("git", "worktree", "remove", "--force", str(checkout), cwd=ROOT)
    measure(ROOT, OUTPUT / "rust.json")
    check_rust(
        json.loads((OUTPUT / "rust.json").read_text()),
        json.loads((OUTPUT / "base-rust.json").read_text()),
        json.loads(POLICY.read_text())["rust_modules"],
    )


if __name__ == "__main__":
    main()
