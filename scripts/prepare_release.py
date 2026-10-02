"""Verify release assets and prepare the same metadata in CI and tag builds."""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess

from prepare_homebrew import cask_for_dmg
from release_version import synchronize


def prepare(root, dist):
    version, _ = synchronize(root, check=True)
    synchronize(root, check=True, tag=f"v{version}")
    names = [f"Parakatt-{version}-arm64.dmg", f"Parakatt-{version}-arm64.zip",
             f"Parakatt-{version}-media-sources.zip"]
    for name in names:
        if not (dist / name).is_file():
            raise ValueError(f"Missing release asset: {name}")
    subprocess.run(["hdiutil", "verify", str(dist / names[0])], check=True)
    checksums = []
    for name in names:
        with (dist / name).open("rb") as stream:
            checksums.append(f"{hashlib.file_digest(stream, 'sha256').hexdigest()}  {name}\n")
    (dist / "SHA256SUMS").write_text(''.join(checksums))
    (dist / "parakatt.rb").write_text(cask_for_dmg(root, dist / names[0]))
    shutil.copyfile(root / "RELEASE_NOTES.md", dist / "RELEASE_NOTES.md")
    print(f"Prepared release metadata for {version}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dist", type=Path, default=Path("dist"))
    args = parser.parse_args()
    try:
        prepare(Path(__file__).resolve().parents[1], args.dist)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Release preparation failed: {error}\n")


if __name__ == "__main__":
    main()
