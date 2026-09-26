#!/bin/sh
# Measure real app rendering with synthetic data and isolated storage. No audio capture.
set -eu
TASK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TASK_OUTPUT=${1:-"$TASK_ROOT/target/maintenance/app-profile"}
TASK_TEMPLATE=${2:-"Time Profiler"}
cd "$TASK_ROOT"
mkdir -p "$(dirname "$TASK_OUTPUT")"
TASK_APP=$(python3 scripts/build-products.py Release)/Parakatt.app
# Give the disposable fixture a separate app identity. Launch by exact path
# and attach by PID below; changing the bundle ID alone is not sufficient.
TASK_PROFILE_DIR=$(mktemp -d "$TASK_ROOT/target/maintenance/profile-app.XXXXXX")
trap 'rm -rf "$TASK_PROFILE_DIR"' EXIT
TASK_PROFILE_APP="$TASK_PROFILE_DIR/ParakattPerformanceFixture.app"
ditto "$TASK_APP" "$TASK_PROFILE_APP"
python3 - "$TASK_PROFILE_APP/Contents/Info.plist" "$TASK_OUTPUT.json" <<'PYTHON'
import plistlib, sys
with open(sys.argv[1], 'rb') as stream: info = plistlib.load(stream)
info['CFBundleIdentifier'] = 'com.parakatt.performancefixture'
info['CFBundleName'] = 'ParakattPerformanceFixture'
info['ParakattPerformanceOutput'] = sys.argv[2]
with open(sys.argv[1], 'wb') as stream: plistlib.dump(info, stream)
PYTHON
# Only the disposable profiling copy is signed; the stable launcher is unchanged.
codesign --force --sign - --options runtime --entitlements Parakatt/Parakatt.entitlements "$TASK_PROFILE_APP" > "$TASK_OUTPUT-sign.log" 2>&1
# Launch the exact executable ourselves, then attach by PID. On some macOS
# versions Instruments --launch substitutes an installed app with the same name.
TASK_GATE="$TASK_PROFILE_DIR/start-workload"
PARAKATT_PROFILE_GATE="$TASK_GATE" PARAKATT_UI_WORKLOAD="$TASK_OUTPUT.json" \
  "$TASK_PROFILE_APP/Contents/MacOS/Parakatt" > "$TASK_OUTPUT-app.log" 2>&1 &
TASK_APP_PID=$!
trap 'kill "$TASK_APP_PID" 2>/dev/null || true; rm -rf "$TASK_PROFILE_DIR"' EXIT
xcrun xctrace record --template "$TASK_TEMPLATE" --time-limit 30s --output "$TASK_OUTPUT.trace" \
  --attach "$TASK_APP_PID" > "$TASK_OUTPUT-instruments.log" 2>&1 &
TASK_TRACE_PID=$!
# Keep the workload idle while Instruments attaches. This wait is bounded.
TASK_WAIT=0
while ! grep -q 'Starting recording' "$TASK_OUTPUT-instruments.log"; do
  kill -0 "$TASK_TRACE_PID" 2>/dev/null || { cat "$TASK_OUTPUT-instruments.log"; exit 1; }
  TASK_WAIT=$((TASK_WAIT + 1))
  [ "$TASK_WAIT" -lt 30 ] || { kill "$TASK_TRACE_PID"; exit 1; }
  sleep 1
done
sleep 2
touch "$TASK_GATE"
TASK_TRACE_STATUS=0
wait "$TASK_TRACE_PID" || TASK_TRACE_STATUS=$?
wait "$TASK_APP_PID" || true
TASK_APP_PID=""
[ "$TASK_TRACE_STATUS" -eq 0 ] || { cat "$TASK_OUTPUT-instruments.log"; exit "$TASK_TRACE_STATUS"; }
# A completed workload and saved trace are required; never accept a missing report.
[ -d "$TASK_OUTPUT.trace" ] || { cat "$TASK_OUTPUT-instruments.log"; exit "$TASK_TRACE_STATUS"; }
python3 - "$TASK_OUTPUT.json" "$TASK_PROFILE_APP" "$TASK_TEMPLATE" <<'PY'
import hashlib, json, pathlib, subprocess, sys
with open(sys.argv[1]) as report:
    data = json.load(report)
if not data.get('completed'): raise SystemExit('App workload failed: ' + str(data))
def command(*args): return subprocess.check_output(args, text=True).strip()
framework = pathlib.Path(sys.argv[2]) / 'Contents/Frameworks/ParakattApp.framework/ParakattApp'
data['provenance'] = {
    'commit': command('git', 'rev-parse', 'HEAD'),
    'dirty': bool(command('git', 'status', '--porcelain')),
    'hardware': command('sysctl', '-n', 'machdep.cpu.brand_string'),
    'framework_sha256': hashlib.sha256(framework.read_bytes()).hexdigest(),
    'runtime_lock_sha256': hashlib.sha256(pathlib.Path('Cargo.lock').read_bytes()).hexdigest(),
    'instruments_template': sys.argv[3],
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
print('App workload completed; results in ' + sys.argv[1])
PY
