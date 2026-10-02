#!/bin/sh
# Usage: ./scripts/sync-version.sh [version] [--build-number N]
# Use --check [--tag vX.Y.Z] to verify without changing files.
set -eu
exec python3 "$(dirname "$0")/release_version.py" "$@"
