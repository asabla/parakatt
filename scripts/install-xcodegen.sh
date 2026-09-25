#!/bin/sh
set -eu
destination="${RUNNER_TEMP:-/tmp}/parakatt-xcodegen"
if [ ! -d "$destination/.git" ]; then
    git clone https://github.com/yonaskolb/XcodeGen.git "$destination"
fi
git -C "$destination" checkout --detach 8445e778451c7e44237b90281bde622d764b0084
cd "$destination"
swift build -c release --product xcodegen
if [ -n "${GITHUB_PATH:-}" ]; then
    echo "$destination/.build/release" >> "$GITHUB_PATH"
else
    echo "XcodeGen: $destination/.build/release/xcodegen"
fi
