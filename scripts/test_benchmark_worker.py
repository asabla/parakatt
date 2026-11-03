"""A real failing subprocess must leave its completed observations available."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WorkerTests(unittest.TestCase):
    def test_native_thread_flags_cannot_mislabel_runtime_defaults(self):
        for backend in ("burnmetal", "nemometal"):
            with self.subTest(backend=backend):
                result = subprocess.run([sys.executable, str(ROOT / "scripts/benchmark.py"),
                    "--backend", backend, "--binary", "unused", "--model", "unused",
                    "--model-manifest", "unused", "--threads", "4", "--output", "unused"],
                    cwd=ROOT, capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 2)
                self.assertIn("runtime thread policy", result.stderr)

    def test_mid_run_failure_preserves_the_completed_observation(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            payload = b"verified local fixture and model bytes"
            (folder / "input").write_bytes(payload)
            checksum = hashlib.sha256(payload).hexdigest()
            (folder / "model.json").write_text(json.dumps(dict(repo="test", revision="test", files=[dict(name="input", size=len(payload), sha256=checksum)])))
            (folder / "fixtures.json").write_text(json.dumps(dict(revision="test", samples=[dict(id="one", language="en_us", path=str(folder / "input"), reference="word", sha256=checksum)])))
            worker = folder / "worker"
            worker.write_text(f"#!{sys.executable}\n" +
                "import json,sys\n" +
                "print(json.dumps(dict(backend='cpu', load_secs=0)), flush=True)\n" +
                "sys.stdin.readline()\n" +
                "print(json.dumps(dict(backend='cpu', text='word', inference_secs=.1, audio_secs=1)), flush=True)\n" +
                "sys.stdin.readline()\n" +
                "sys.exit(2)\n")
            worker.chmod(0o755)
            result = subprocess.run([sys.executable, str(ROOT / "scripts/benchmark.py"),
                "--binary", str(worker), "--model", str(folder), "--model-manifest", str(folder / "model.json"),
                "--fixtures", str(folder / "fixtures.json"), "--subset", "--cold-runs", "0", "--warm-runs", "2",
                "--output", str(folder / "result")], cwd=ROOT, capture_output=True, text=True, timeout=20)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((folder / "result.json").exists())
            rows = [json.loads(line) for line in (folder / "result.observations.jsonl").read_text().splitlines()]
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["id"], "one")
            self.assertEqual(rows[0]["errors"], 0)


if __name__ == "__main__":
    unittest.main()
