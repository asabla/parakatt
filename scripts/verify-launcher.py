#!/usr/bin/env python3
"""Verify a packaged launcher against the checked-in identity."""
from pathlib import Path
import subprocess
import sys
import shutil
import tempfile

root = Path(__file__).resolve().parents[1]
binary = sys.argv[1] if len(sys.argv) > 1 else str(root / "bin/parakatt-launcher")
details = subprocess.check_output(["codesign", "-dvvv", binary], stderr=subprocess.STDOUT, text=True)
actual = next(line.split("=", 1)[1] for line in details.splitlines() if line.startswith("CDHash="))
expected = (root / "bin/parakatt-launcher.cdhash").read_text().strip()
if actual != expected:
    sys.exit(f"Launcher identity changed: expected {expected}, got {actual}")
# Verify the executable's embedded signature independently of Xcode's old
# bundle resource seal. The launcher is deliberately reused without re-signing.
with tempfile.TemporaryDirectory(prefix="parakatt-launcher-check-") as directory:
    standalone = Path(directory) / "launcher"
    shutil.copyfile(binary, standalone)
    subprocess.run(["codesign", "--verify", str(standalone)], check=True)
print(f"Launcher identity verified: {actual}")
