#!/usr/bin/env python3
"""Locate the app target's products without combining paths from dependencies."""
import json
import subprocess
import sys

configuration = sys.argv[1] if len(sys.argv) > 1 else "Release"
if configuration not in ("Debug", "Release"):
    raise SystemExit("Expected Debug or Release")
settings = json.loads(subprocess.check_output(["xcodebuild", "-project", "Parakatt.xcodeproj", "-scheme", "Parakatt", "-configuration", configuration, "-showBuildSettings", "-json"], stderr=subprocess.DEVNULL))
print(next(target["buildSettings"]["BUILT_PRODUCTS_DIR"] for target in settings if target["target"] == "Parakatt"))
