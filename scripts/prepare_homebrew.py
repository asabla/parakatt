"""Generate a cask from the exact release DMG and optionally open a tap pull request."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess

from release_version import replace_once, synchronize


TAP = "asabla/homebrew-tap"


def cask_for_dmg(root, dmg):
    version, _ = synchronize(root, check=True)
    if dmg.name != f"Parakatt-{version}-arm64.dmg":
        raise ValueError("DMG filename does not match VERSION")
    with dmg.open("rb") as stream:
        checksum = hashlib.file_digest(stream, "sha256").hexdigest()
    cask = (root / "homebrew/parakatt.rb").read_text()
    cask = replace_once(cask, r'(^  version ")[^"]*("$)', version, "cask version")
    return replace_once(cask, r'(^  sha256 ")[^"]*("$)', checksum, "cask checksum")


def api(endpoint, method="GET", payload=None):
    command = ["gh", "api", endpoint, "--method", method]
    if payload is not None:
        command += ["--input", "-"]
    return json.loads(subprocess.check_output(command, input=json.dumps(payload) if payload is not None else None, text=True))


def update_tap(version, cask):
    if not os.environ.get("GH_TOKEN"):
        raise ValueError("Set GH_TOKEN to a token with contents and pull-request write access to the tap")
    repo = api(f"repos/{TAP}")
    default = repo["default_branch"]
    current = api(f"repos/{TAP}/contents/Casks/parakatt.rb?ref={default}")
    if base64.b64decode(current["content"]).decode() == cask:
        print("Homebrew tap already matches this release")
        return
    branch = f"parakatt-{version}"
    branches = api(f"repos/{TAP}/git/matching-refs/heads/{branch}")
    if not any(item["ref"] == f"refs/heads/{branch}" for item in branches):
        base = api(f"repos/{TAP}/git/ref/heads/{default}")
        api(f"repos/{TAP}/git/refs", "POST", {"ref": f"refs/heads/{branch}", "sha": base["object"]["sha"]})
    existing = api(f"repos/{TAP}/contents/Casks/parakatt.rb?ref={branch}")
    if base64.b64decode(existing["content"]).decode() != cask:
        api(f"repos/{TAP}/contents/Casks/parakatt.rb", "PUT", {
            "message": f"chore: update Parakatt to {version}", "branch": branch,
            "sha": existing["sha"], "content": base64.b64encode(cask.encode()).decode(),
        })
    pulls = api(f"repos/{TAP}/pulls?head=asabla:{branch}&state=open")
    if pulls:
        print(pulls[0]["html_url"])
        return
    pull = api(f"repos/{TAP}/pulls", "POST", {
        "title": f"chore: update Parakatt to {version}", "head": branch, "base": default,
        "body": f"Update Parakatt to [{version}](https://github.com/asabla/parakatt/releases/tag/v{version}). The SHA-256 checksum comes from the DMG uploaded by the release workflow.",
    })
    print(pull["html_url"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dmg", type=Path)
    parser.add_argument("--output", type=Path, default=Path("dist/parakatt.rb"))
    parser.add_argument("--update-tap", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    try:
        cask = cask_for_dmg(root, args.dmg)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(cask)
        print(f"Wrote {args.output}")
        if args.update_tap:
            update_tap((root / "VERSION").read_text().strip(), cask)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Homebrew preparation failed: {error}\n")


if __name__ == "__main__":
    main()
