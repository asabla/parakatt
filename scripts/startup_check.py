"""Check the app's normal launch path without using maintenance mode."""

import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time


def check_normal_startup(app, timeout=30, settle_seconds=1):
    app = Path(app).resolve()
    with (app / "Contents/Info.plist").open("rb") as stream:
        version = plistlib.load(stream)["CFBundleShortVersionString"]
    with tempfile.TemporaryDirectory(prefix="parakatt-normal-startup-") as directory:
        env = dict(os.environ, PARAKATT_DATA_ROOT=directory, CFFIXED_USER_HOME=directory)
        env.pop("PARAKATT_SMOKE_TEST", None)
        env.pop("PARAKATT_STOP_LATENCY", None)
        env.pop("PARAKATT_UI_PROFILE", None)
        command = [
            str(app / "Contents/MacOS/Parakatt"),
            "-hasCompletedOnboarding",
            "YES",
            "-accessibilityPrompted",
            "YES",
            "-lastKnownAppVersion",
            version,
        ]
        log_path = Path(directory) / "startup.log"
        with log_path.open("w") as log:
            process = subprocess.Popen(command, env=env, stdout=log, stderr=log)
            deadline = time.monotonic() + timeout
            ready_at = None
            try:
                while time.monotonic() < deadline:
                    text = log_path.read_text()
                    if process.poll() is not None:
                        raise RuntimeError(
                            f"Normal startup exited with {process.returncode}.\n{text[-4000:]}"
                        )
                    ready = (
                        "[Parakatt] Normal startup complete" in text
                        and "[Parakatt] Engine created" in text
                        and "[Parakatt] Notification permission " in text
                    )
                    if ready:
                        if ready_at is None:
                            ready_at = time.monotonic()
                        if time.monotonic() - ready_at >= settle_seconds:
                            return {
                                "started": True,
                                "mode": "normal",
                                "notification_callback": True,
                            }
                    time.sleep(0.05)
                raise RuntimeError(
                    f"Normal startup did not finish.\n{log_path.read_text()[-4000:]}"
                )
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
