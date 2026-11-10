#!/usr/bin/env python3
"""Install a per-user launcher and desktop entry for the local Linux venv."""

import argparse
import os
from pathlib import Path
import shlex


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, default=Path.home() / ".local")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    executable = root / "target/linux-venv/bin/parakatt-desktop"
    if not executable.is_file():
        parser.error("Run make linux-desktop first")
    prefix = args.prefix.resolve()
    launcher = prefix / "bin/parakatt-desktop"
    launcher.parent.mkdir(parents=True, exist_ok=True)
    launcher.write_text(f'#!/bin/sh\nexec {shlex.quote(str(executable))} "$@"\n')
    launcher.chmod(0o755)
    data = Path(os.environ.get("XDG_DATA_HOME", prefix / "share"))
    desktop = data / "applications/parakatt.desktop"
    desktop.parent.mkdir(parents=True, exist_ok=True)
    quoted = str(launcher)
    for character in ("\\", '"', "`", "$"):
        quoted = quoted.replace(character, "\\" + character)
    content = (root / "linux/parakatt.desktop").read_text()
    desktop.write_text(content.replace("Exec=parakatt-desktop", f'Exec="{quoted}"'))
    print(f"Desktop entry: {desktop}")
    print(f"GNOME custom shortcut command: {launcher} --toggle")


if __name__ == "__main__":
    main()
