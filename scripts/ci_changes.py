#!/usr/bin/env python3
"""Conservatively select expensive Rust checks; unknown paths always require them."""

import argparse
import os
from pathlib import PurePosixPath
import subprocess


def needs_rust_checks(paths):
    for name in paths:
        path = PurePosixPath(name)
        # Only explicitly unrelated inputs can skip fuzzing and mutation testing.
        if path.suffix == ".md" or path.parts[0] == "docs":
            continue
        if path.parts[0] in ("Parakatt", "Launcher", "Tests") and path.suffix == ".swift":
            continue
        if name in ("project.yml", ".swiftlint.yml", ".swiftlint-analyze.yml"):
            continue
        return True
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base")
    args = parser.parse_args()
    # Main, manual, and scheduled runs always exercise the full suite.
    if os.environ.get("GITHUB_EVENT_NAME") != "pull_request":
        required = True
    else:
        if not args.base:
            parser.error("Pull requests require a base commit")
        changed = subprocess.check_output(
            ["git", "diff", "--name-only", "--no-renames", "-z", args.base, "HEAD", "--"]
        )
        paths = changed.decode("utf-8", errors="surrogateescape").split("\0")
        required = needs_rust_checks([path for path in paths if path])
    print(f"rust_checks={str(required).lower()}")


if __name__ == "__main__":
    main()
