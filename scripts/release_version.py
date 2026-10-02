"""Keep app and Rust versions consistent without updating dependency versions."""
import argparse
from pathlib import Path
import re


def replace_once(text, pattern, value, name):
    updated, count = re.subn(pattern, lambda match: match[1] + value + match[2], text, flags=re.M)
    if count != 1:
        raise ValueError(f"Expected one {name} field, found {count}")
    return updated


def synchronize(root, version=None, build_number=None, check=False, tag=None):
    current = (root / "VERSION").read_text().strip()
    version = version if version is not None else current
    if not re.fullmatch(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)", version):
        raise ValueError("Version must use X.Y.Z with no leading zeros")
    current_build = (root / "BUILD_NUMBER").read_text().strip()
    if not re.fullmatch(r"[1-9]\d*", current_build):
        raise ValueError("BUILD_NUMBER must be a positive integer")
    if build_number is None:
        build_number = str(int(current_build) + (version != current))
    else:
        build_number = str(build_number)
    if not re.fullmatch(r"[1-9]\d*", build_number):
        raise ValueError("Build number must be a positive integer")
    if not check and (int(build_number) < int(current_build) or
                      (version != current and int(build_number) <= int(current_build))):
        raise ValueError("A new version requires a higher build number")
    if not check and tuple(map(int, version.split('.'))) < tuple(map(int, current.split('.'))):
        raise ValueError("Version must not decrease")
    if tag is not None and tag != f"v{version}":
        raise ValueError(f"Tag {tag!r} does not match VERSION v{version}")
    if tag is not None:
        notes = (root / "RELEASE_NOTES.md").read_text().splitlines()
        if not notes or notes[0] != f"# Parakatt {version}":
            raise ValueError("Release notes do not match VERSION")
        if f"## {version}\n" not in (root / "CHANGELOG.md").read_text():
            raise ValueError("Changelog does not contain the release version")

    # Prepare all changes before writing. A missing field must not cause a partial sync.
    updates = {"VERSION": version + "\n", "BUILD_NUMBER": build_number + "\n"}
    project = (root / "project.yml").read_text()
    for field, value in (("CFBundleShortVersionString", version), ("MARKETING_VERSION", version),
                         ("CFBundleVersion", build_number), ("CURRENT_PROJECT_VERSION", build_number)):
        project = replace_once(project, rf'(^\s*{field}: ")[^"]*("\s*$)', value, field)
    updates["project.yml"] = project
    info = (root / "Parakatt/Info.plist").read_text()
    for field, value in (("CFBundleShortVersionString", version), ("CFBundleVersion", build_number)):
        info = replace_once(info, rf'(<key>{field}</key>\s*<string>)[^<]*(</string>)', value, field)
    updates["Parakatt/Info.plist"] = info
    manifest = (root / "crates/parakatt-core/Cargo.toml").read_text()
    updates["crates/parakatt-core/Cargo.toml"] = replace_once(
        manifest, r'(^version = ")[^"]*("\s*$)', version, "Rust package version")
    lock = (root / "Cargo.lock").read_text()
    updates["Cargo.lock"] = replace_once(
        lock, r'(^name = "parakatt-core"\nversion = ")[^"]*("\s*$)', version, "locked Rust package version")

    mismatches = [name for name, content in updates.items() if (root / name).read_text() != content]
    if check:
        if mismatches:
            raise ValueError("Version mismatch: " + ", ".join(mismatches))
    else:
        for name in mismatches:
            (root / name).write_text(updates[name])
    return version, build_number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", nargs="?")
    parser.add_argument("--build-number")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--tag", help="Require a matching release tag; implies --check")
    args = parser.parse_args()
    if (args.check or args.tag) and (args.version is not None or args.build_number is not None):
        parser.error("Check mode reads VERSION and BUILD_NUMBER; do not supply new values")
    try:
        version, build = synchronize(Path(__file__).resolve().parents[1], args.version,
                                     args.build_number, args.check or args.tag is not None, args.tag)
    except (ValueError, OSError) as error:
        parser.exit(1, f"{error}\n")
    print(f"Version {version}, build {build}: {'verified' if args.check or args.tag else 'synchronized'}")


if __name__ == "__main__":
    main()
