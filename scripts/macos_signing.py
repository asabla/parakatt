"""Sign the completed macOS app and optionally notarize distribution artifacts."""

import argparse
from dataclasses import dataclass
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP_ID = "com.parakatt.app"
MACH_O = {
    b"\xcf\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xce",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}


def mach_o_files(app):
    for path in sorted(app.rglob("*")):
        if not path.is_symlink() and path.is_file():
            with path.open("rb") as stream:
                if stream.read(4) in MACH_O:
                    yield path


def nested_code(app):
    """Plan leaf signing once and seal each framework after its contents."""
    app = app.resolve()
    frameworks = [
        path for path in app.rglob("*.framework") if path.is_dir() and not path.is_symlink()
    ]
    bundle_executables = {(app / "Contents/MacOS/Parakatt").resolve()}
    for framework in frameworks:
        executable = (framework / framework.stem).resolve()
        if not executable.is_relative_to(framework) or not executable.is_file():
            raise ValueError(f"Missing framework executable: {framework}")
        bundle_executables.add(executable)
    leaves = [path for path in mach_o_files(app) if path not in bundle_executables]
    return leaves + sorted(frameworks, key=lambda path: (-len(path.parts), str(path)))


@dataclass(frozen=True)
class Signing:
    identity: str = "-"
    team: str = ""
    profile: str = ""
    keychain: str = ""

    @classmethod
    def from_environment(cls):
        settings = cls(
            identity=os.environ.get("PARAKATT_CODESIGN_IDENTITY", "-"),
            team=os.environ.get("PARAKATT_SIGNING_TEAM_ID", ""),
            profile=os.environ.get("PARAKATT_NOTARY_PROFILE", ""),
            keychain=os.environ.get("PARAKATT_SIGNING_KEYCHAIN", ""),
        )
        if not settings.identity:
            raise ValueError("Missing code signing identity")
        if settings.distribution:
            if not re.fullmatch(r"[A-Z0-9]{10}", settings.team) or not settings.profile:
                raise ValueError("Developer ID signing requires a Team ID and notary profile")
        elif settings.team or settings.profile or settings.keychain:
            raise ValueError("Distribution signing settings require a Developer ID identity")
        return settings

    @property
    def distribution(self):
        return self.identity != "-"

    def sign(self, path, *, runtime=True, entitlements=None):
        command = ["codesign", "--force", "--sign", self.identity]
        if self.distribution:
            command.append("--timestamp")
        if self.keychain:
            command += ["--keychain", self.keychain]
        if runtime:
            command += ["--options", "runtime"]
        if entitlements is not None:
            command += ["--entitlements", str(entitlements)]
        subprocess.run([*command, str(path)], check=True)

    def notarize(self, upload, staple):
        args = ["--keychain-profile", self.profile]
        if self.keychain:
            args += ["--keychain", self.keychain]
        # Inspect the returned status even on a zero exit code.
        result = subprocess.check_output(
            [
                "xcrun",
                "notarytool",
                "submit",
                str(upload),
                *args,
                "--wait",
                "--output-format",
                "plist",
                "--timeout",
                "30m",
            ]
        )
        submission = plistlib.loads(result)
        if submission.get("status") != "Accepted":
            print(f"Notarization status: {submission.get('status')}, ID: {submission.get('id')}")
            if submission.get("id"):
                subprocess.run(["xcrun", "notarytool", "log", submission["id"], *args], check=False)
            raise ValueError("Apple did not accept the notarization submission")
        subprocess.run(["xcrun", "stapler", "staple", str(staple)], check=True)
        subprocess.run(["xcrun", "stapler", "validate", str(staple)], check=True)


def verify_bundle(app):
    subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)], check=True
    )


def sign_app(app, signing):
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != APP_ID or info.get("CFBundleExecutable") != "Parakatt":
        raise ValueError("Expected the Parakatt release bundle and executable")
    helpers = app / "Contents/Helpers/MediaTools"
    entitlements = {
        helpers / "deno": ROOT / "config/media-runtime.entitlements",
        # The upstream PyInstaller executable loads its own embedded Python
        # libraries. They retain their upstream signatures when we re-sign it.
        helpers / "yt-dlp": ROOT / "config/yt-dlp-runtime.entitlements",
    }
    for path in nested_code(app):
        signing.sign(path, entitlements=entitlements.get(path))
    signing.sign(app, entitlements=ROOT / "Parakatt/Parakatt.entitlements")
    verify_bundle(app)
    if signing.distribution:
        requirement = (
            f'identifier "{APP_ID}" and anchor apple generic '
            "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists "
            f'and certificate leaf[subject.OU] = "{signing.team}"'
        )
        subprocess.run(
            ["codesign", "--verify", "--strict", "-R", "=" + requirement, str(app)], check=True
        )
        with tempfile.TemporaryDirectory(prefix="parakatt-notary-") as temp:
            upload = Path(temp) / "Parakatt.zip"
            subprocess.run(["ditto", "-c", "-k", "--keepParent", str(app), str(upload)], check=True)
            signing.notarize(upload, app)
        verify_bundle(app)
        subprocess.run(
            ["spctl", "--assess", "--type", "execute", "--verbose=2", str(app)], check=True
        )


def sign_dmg(dmg, signing):
    if signing.distribution:
        signing.sign(dmg, runtime=False)
        signing.notarize(dmg, dmg)
        subprocess.run(
            [
                "spctl",
                "--assess",
                "--type",
                "open",
                "--context",
                "context:primary-signature",
                "--verbose=2",
                str(dmg),
            ],
            check=True,
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=("app", "dmg"))
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    try:
        signing = Signing.from_environment()
        function = sign_app if args.kind == "app" else sign_dmg
        function(args.path.resolve(strict=True), signing)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"macOS signing failed: {error}\n")


if __name__ == "__main__":
    main()
