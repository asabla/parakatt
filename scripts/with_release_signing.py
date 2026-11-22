"""Run release packaging with temporary Developer ID and notary credentials."""

import argparse
import base64
from contextlib import suppress
import os
from pathlib import Path
import re
import secrets
import subprocess
import tempfile

REQUIRED = (
    "MACOS_TEAM_ID",
    "MACOS_CERTIFICATE_P12_BASE64",
    "MACOS_CERTIFICATE_PASSWORD",
    "MACOS_NOTARY_KEY_BASE64",
    "MACOS_NOTARY_KEY_ID",
    "MACOS_NOTARY_ISSUER_ID",
)


def credentials(environment):
    missing = [name for name in REQUIRED if not environment.get(name)]
    if missing:
        raise ValueError("Missing release signing configuration: " + ", ".join(missing))
    if not re.fullmatch(r"[A-Z0-9]{10}", environment["MACOS_TEAM_ID"]):
        raise ValueError("MACOS_TEAM_ID must be a ten-character Apple Team ID")
    return {name: environment[name] for name in REQUIRED}


def signing_identity(output, team):
    matches = re.findall(
        r'(?m)^\s*\d+\)\s+([0-9A-F]{40})\s+"Developer ID Application: [^\n]+ \(([A-Z0-9]{10})\)"\s*$',
        output,
    )
    identities = [identity for identity, identity_team in matches if identity_team == team]
    if len(identities) != 1:
        raise ValueError("Expected exactly one Developer ID Application identity for MACOS_TEAM_ID")
    return identities[0]


def run_private(label, command):
    # Some security(1) arguments carry passwords. Report the failed operation
    # without surfacing its command line or replaying credential tool output.
    try:
        return subprocess.check_output(command, stderr=subprocess.STDOUT, text=True)
    except subprocess.CalledProcessError as exc:
        raise ValueError(f"{label} failed (exit status {exc.returncode})") from None


def package(command):
    config = credentials(os.environ)
    environment = {key: value for key, value in os.environ.items() if key not in REQUIRED}
    team = config["MACOS_TEAM_ID"]
    profile = "parakatt-release"
    with tempfile.TemporaryDirectory(prefix="parakatt-signing-") as directory:
        folder = Path(directory)
        keychain = str(folder / "release.keychain-db")
        password = secrets.token_urlsafe(32)
        certificate = folder / "certificate.p12"
        api_key = folder / "notary.p8"
        certificate.write_bytes(
            base64.b64decode(config["MACOS_CERTIFICATE_P12_BASE64"], validate=True)
        )
        api_key.write_bytes(base64.b64decode(config["MACOS_NOTARY_KEY_BASE64"], validate=True))
        try:
            run_private(
                "Create release keychain", ["security", "create-keychain", "-p", password, keychain]
            )
            run_private(
                "Unlock release keychain", ["security", "unlock-keychain", "-p", password, keychain]
            )
            run_private(
                "Configure release keychain",
                ["security", "set-keychain-settings", "-lut", "7200", keychain],
            )
            run_private(
                "Import Developer ID certificate",
                [
                    "security",
                    "import",
                    str(certificate),
                    "-k",
                    keychain,
                    "-f",
                    "pkcs12",
                    "-P",
                    config["MACOS_CERTIFICATE_PASSWORD"],
                    "-T",
                    "/usr/bin/codesign",
                ],
            )
            run_private(
                "Allow codesign to use the signing key",
                [
                    "security",
                    "set-key-partition-list",
                    "-S",
                    "apple-tool:,apple:",
                    "-s",
                    "-k",
                    password,
                    keychain,
                ],
            )
            identities = run_private(
                "Find Developer ID identity",
                ["security", "find-identity", "-v", "-p", "codesigning", keychain],
            )
            identity = signing_identity(identities, team)
            run_private(
                "Configure Apple notary credentials",
                [
                    "xcrun",
                    "notarytool",
                    "store-credentials",
                    profile,
                    "--keychain",
                    keychain,
                    "--key",
                    str(api_key),
                    "--key-id",
                    config["MACOS_NOTARY_KEY_ID"],
                    "--issuer",
                    config["MACOS_NOTARY_ISSUER_ID"],
                ],
            )
            certificate.unlink()
            api_key.unlink()
            environment.update(
                PARAKATT_CODESIGN_IDENTITY=identity,
                PARAKATT_SIGNING_TEAM_ID=team,
                PARAKATT_NOTARY_PROFILE=profile,
                PARAKATT_SIGNING_KEYCHAIN=keychain,
            )
            return subprocess.run(command, env=environment, check=False).returncode
        finally:
            with suppress(OSError):
                subprocess.run(
                    ["security", "delete-keychain", keychain], capture_output=True, check=False
                )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", nargs="+")
    args = parser.parse_args()
    try:
        raise SystemExit(package(args.command))
    except (OSError, ValueError) as error:
        parser.exit(1, f"Release signing setup failed: {error}\n")


if __name__ == "__main__":
    main()
