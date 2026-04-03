#!/bin/bash
# Sync the version from VERSION file to all references in the project.
# Usage: ./scripts/sync-version.sh [new-version]
#
# If a new version is provided, updates VERSION first, then syncs.
# If no argument, reads VERSION and syncs all files to match.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."

if [ $# -ge 1 ]; then
    echo "$1" > "$ROOT/VERSION"
fi

VERSION=$(tr -d '[:space:]' < "$ROOT/VERSION")

if [ -z "$VERSION" ]; then
    echo "Error: VERSION file is empty" >&2
    exit 1
fi

echo "Syncing version: $VERSION"

# Makefile
sed -i '' "s/^VERSION := .*/VERSION := $VERSION/" "$ROOT/Makefile"

# project.yml
sed -i '' "s/CFBundleShortVersionString: .*/CFBundleShortVersionString: \"$VERSION\"/" "$ROOT/project.yml"
sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: \"$VERSION\"/" "$ROOT/project.yml"

# Info.plist (line after CFBundleShortVersionString)
sed -i '' "/<key>CFBundleShortVersionString<\/key>/{n;s|<string>.*</string>|<string>$VERSION</string>|;}" "$ROOT/Parakatt/Info.plist"

# Cargo.toml
sed -i '' "s/^version = .*/version = \"$VERSION\"/" "$ROOT/crates/parakatt-core/Cargo.toml"

# Homebrew cask
sed -i '' "s/version .*/version \"$VERSION\"/" "$ROOT/homebrew/parakatt.rb"

echo "Done. Updated: Makefile, project.yml, Info.plist, Cargo.toml, homebrew/parakatt.rb"
