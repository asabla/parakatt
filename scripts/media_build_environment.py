"""Prepare build-only media tools without reusing another Python installation."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

PACKAGES = {"meson": "1.12.1", "ninja": "1.13.2", "packaging": "26.3"}


def specification():
    return {"python": str(Path(sys.executable).resolve()),
            "version": list(sys.version_info[:3]), "packages": PACKAGES}


def prepare_build_environment(build):
    spec = specification()
    key = hashlib.sha256(json.dumps(spec, sort_keys=True).encode()).hexdigest()[:16]
    environment = Path(build) / ("venv-media-" + key)
    python = environment / "bin/python"
    marker = environment / "parakatt-build-environment.json"
    checker = ("import importlib.metadata,json,sys; expected=json.loads(sys.argv[1]); "
               "actual={name:importlib.metadata.version(name) for name in expected}; "
               "sys.exit(0 if actual==expected else 1)")
    verification = [str(python), "-c", checker, json.dumps(PACKAGES, sort_keys=True)]
    try:
        reusable = (json.loads(marker.read_text()) == spec
                    and all((environment / "bin" / name).is_file() for name in ("python", "meson", "ninja")))
    except (OSError, ValueError):
        reusable = False
    if reusable:
        try:
            subprocess.run(verification, check=True, capture_output=True, text=True)
            return environment
        except (OSError, subprocess.CalledProcessError):
            pass

    # A partial or restored environment can retain an incompatible executable.
    # Separate ensurepip so its actual stderr reaches the build log.
    subprocess.run([sys.executable, "-m", "venv", "--clear", "--without-pip", str(environment)], check=True)
    subprocess.run([str(python), "-m", "ensurepip", "--upgrade", "--default-pip"], check=True)
    subprocess.run([str(python), "-m", "pip", "install", *[f"{name}=={version}" for name, version in PACKAGES.items()]], check=True)
    subprocess.run(verification, check=True)
    marker.write_text(json.dumps(spec, indent=2) + "\n")
    return environment
