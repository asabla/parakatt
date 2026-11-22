"""Exercise release signing ordering and failure handling without credentials."""

from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from macos_signing import APP_ID, Signing, nested_code, sign_app, verify_bundle
from with_release_signing import REQUIRED, credentials, run_private, signing_identity


class SigningTests(unittest.TestCase):
    def test_framework_members_are_signed_before_the_bundle_that_contains_them(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Parakatt.app"
            main = app / "Contents/MacOS/Parakatt"
            framework = app / "Contents/Frameworks/Core.framework"
            binary = framework / "Versions/A/Core"
            library = framework / "Versions/A/Frameworks/Runtime.dylib"
            helper = app / "Contents/Helpers/MediaTools/deno"
            for path in (main, binary, library, helper):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"\xcf\xfa\xed\xfe")
            (framework / "Versions/Current").symlink_to("A")
            (framework / "Core").symlink_to("Versions/Current/Core")
            alias = Path(directory) / "Alias.app"
            alias.symlink_to(app, target_is_directory=True)
            planned = nested_code(alias)
            self.assertEqual(
                set(planned), {path.resolve() for path in (library, helper, framework)}
            )
            self.assertEqual(planned[-1], framework.resolve())

    def test_notary_rejection_does_not_staple_even_with_zero_exit_status(self):
        with (
            patch(
                "macos_signing.subprocess.check_output",
                return_value=plistlib.dumps({"status": "Invalid", "id": "submission"}),
            ),
            patch("macos_signing.subprocess.run") as run,
            self.assertRaisesRegex(ValueError, "did not accept"),
        ):
            Signing(profile="example").notarize(Path("upload.zip"), Path("Parakatt.app"))
        run.assert_called_once_with(
            ["xcrun", "notarytool", "log", "submission", "--keychain-profile", "example"],
            check=False,
        )

    def test_partial_signing_configuration_cannot_fall_back_to_ad_hoc(self):
        with (
            patch.dict("os.environ", {"PARAKATT_SIGNING_TEAM_ID": "ABCDEFGHIJ"}, clear=True),
            self.assertRaisesRegex(ValueError, "require a Developer ID"),
        ):
            Signing.from_environment()
        with self.assertRaisesRegex(ValueError, "MACOS_CERTIFICATE_P12_BASE64"):
            credentials(
                {name: "value" for name in REQUIRED if name != "MACOS_CERTIFICATE_P12_BASE64"}
            )

    def test_keychain_requires_one_developer_id_identity_for_the_expected_team(self):
        dev = f'  1) {"A" * 40} "Developer ID Application: Example (ABCDEFGHIJ)"\n'
        other = f'  2) {"B" * 40} "Apple Development: Example (ABCDEFGHIJ)"\n'
        self.assertEqual(signing_identity(dev + other, "ABCDEFGHIJ"), "A" * 40)
        with self.assertRaisesRegex(ValueError, "exactly one"):
            signing_identity(dev + dev, "ABCDEFGHIJ")
        with self.assertRaisesRegex(ValueError, "exactly one"):
            signing_identity(dev, "ZYXWVUTSRQ")

    def test_credentials_command_failure_omits_arguments_and_tool_output(self):
        command = ["security", "import", "-P", "some-password"]
        error = subprocess.CalledProcessError(1, command, output="some-password")
        with (
            patch("with_release_signing.subprocess.check_output", side_effect=error),
            self.assertRaisesRegex(ValueError, r"^Import certificate failed \(exit status 1\)$"),
        ):
            run_private("Import certificate", command)

    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("clang"), "Requires macOS tools")
    def test_sealed_app_rejects_modified_resource(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            app = work / "Parakatt.app"
            binary = app / "Contents/MacOS/Parakatt"
            resource = app / "Contents/Resources/example.txt"
            binary.parent.mkdir(parents=True)
            resource.parent.mkdir()
            resource.write_text("original content")
            (app / "Contents/Info.plist").write_bytes(
                plistlib.dumps(
                    {
                        "CFBundleIdentifier": APP_ID,
                        "CFBundleExecutable": "Parakatt",
                        "CFBundlePackageType": "APPL",
                    }
                )
            )
            subprocess.run(
                ["clang", "-x", "c", "-o", str(binary), "-"],
                input="int main(void) { return 0; }",
                text=True,
                check=True,
            )
            sign_app(app, Signing())
            resource.write_text("changed content")
            with self.assertRaises(subprocess.CalledProcessError):
                verify_bundle(app)
