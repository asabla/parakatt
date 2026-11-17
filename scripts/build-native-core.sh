#!/bin/sh
# The native build recipe is separate from unrelated Makefile checks and packaging.
set -eu
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
export PARAKATT_SPEECH_FEATURES="${PARAKATT_SPEECH_FEATURES-webgpu}"
if [ -z "${SDKROOT:-}" ]; then
    SDKROOT="$(xcodebuild -version -sdk macosx Path)"
    export SDKROOT
fi
cargo build --locked --release --target aarch64-apple-darwin -p parakatt-core --features "$PARAKATT_SPEECH_FEATURES"
