#!/bin/sh
# Run the opt-in synthetic UI workload under Instruments. No audio is captured.
set -eu
TASK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TASK_OUTPUT=${1:-"$TASK_ROOT/target/maintenance/ui-profile"}
TASK_TEMPLATE=${2:-"Time Profiler"}
mkdir -p "$(dirname "$TASK_OUTPUT")"
cd "$TASK_ROOT"
make xcode
xcodebuild build-for-testing -project Parakatt.xcodeproj -scheme Parakatt -configuration Debug -derivedDataPath target/xcode > "$TASK_OUTPUT-build.log" 2>&1
TASK_DEVELOPER=$(xcode-select -p)
TASK_PLATFORM="$TASK_DEVELOPER/Platforms/MacOSX.platform/Developer"
TASK_PRODUCTS="$TASK_ROOT/target/xcode/Build/Products/Debug"
xcrun xctrace record --template "$TASK_TEMPLATE" --time-limit 25s --output "$TASK_OUTPUT.trace" \
  --env "PARAKATT_UI_PROFILE=$TASK_OUTPUT.json" \
  --env "DYLD_FRAMEWORK_PATH=$TASK_PRODUCTS:$TASK_PRODUCTS/PackageFrameworks:$TASK_PLATFORM/Library/Frameworks:$TASK_DEVELOPER/../SharedFrameworks" \
  --env "DYLD_LIBRARY_PATH=$TASK_PRODUCTS:$TASK_PLATFORM/usr/lib" \
  --target-stdout "$TASK_OUTPUT-tests.log" \
  --launch -- "$TASK_PLATFORM/Library/Xcode/Agents/xctest" \
  -XCTest 'ParakattTests.MaintenanceProfileTests/testProfileRecordingHistoryAndTranscriptScroll' \
  "$TASK_PRODUCTS/ParakattTests.xctest" > "$TASK_OUTPUT-instruments.log" 2>&1
# Fail if the test process did not finish its workload and write the report.
test -s "$TASK_OUTPUT.json"
