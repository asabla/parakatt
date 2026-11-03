"""Prevent stale systems, changed references, fallback, and false summaries from passing."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("compare-benchmarks.py")


def report(backend, seconds):
    observations = [dict(id=f"{lang}:{i}", language=lang, phase="warm", run=run,
                         words=10, errors=1, audio_secs=10.0, inference_secs=seconds, backend=backend)
                    for lang in ("en_us", "sv_se") for run in range(10) for i in range(100)]
    observations += [dict(observations[0], phase="cold", run=run) for run in range(3)]
    return dict(schema_version=2, model_files_verified=True, os_build="tested-build",
                fixture_manifest_sha256="fixtures", model_manifest_sha256="model",
                runtime_lock_sha256="runtime", binary_sha256="worker", dataset_revision="dataset",
                hardware="tested-hardware", os="tested-os", screening=False, observations=observations,
                summary={lang:dict(wer=.1, median_secs=seconds, p95_secs=seconds) for lang in ("en_us", "sv_se")})


class GateTests(unittest.TestCase):
    def compare(self, candidate, extra=()):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / "base.json").write_text(json.dumps(report("cpu", 1.0)))
            (folder / "candidate.json").write_text(json.dumps(candidate))
            result = subprocess.run([sys.executable, str(SCRIPT), str(folder / "base.json"),
                                     str(folder / "candidate.json"), "--acceleration", *extra], capture_output=True, text=True)
            return result.returncode, json.loads(result.stdout)

    def test_complete_verified_gpu_run_passes(self):
        self.assertEqual(self.compare(report("webgpu", .2))[0], 0)

    def test_new_os_reference_model_or_unverified_files_cannot_pass(self):
        for key, value in [("os_build", "new-build"), ("fixture_manifest_sha256", "new-reference"),
                           ("model_manifest_sha256", "new-model"), ("model_files_verified", False)]:
            with self.subTest(key=key):
                candidate = report("webgpu", .2)
                candidate[key] = value
                self.assertNotEqual(self.compare(candidate)[0], 0)

    def test_one_cpu_retry_does_not_count_as_gpu_acceptance(self):
        candidate = report("webgpu", .2)
        candidate["observations"][0]["backend"] = "cpu"
        self.assertNotEqual(self.compare(candidate)[0], 0)

    def test_fast_summary_cannot_hide_slow_observations(self):
        candidate = report("webgpu", 2.0)
        for summary in candidate["summary"].values():
            summary.update(median_secs=.2, p95_secs=.2)
        self.assertNotEqual(self.compare(candidate)[0], 0)

    def test_repeated_fixture_cannot_replace_missing_audio(self):
        candidate = report("webgpu", .2)
        candidate["observations"][1] = copy.deepcopy(candidate["observations"][0])
        self.assertNotEqual(self.compare(candidate)[0], 0)

    def test_native_candidate_requires_named_backend_and_explicit_model_change(self):
        candidate = report("burnmetal", .2)
        candidate["model_manifest_sha256"] = "candidate-export"
        self.assertNotEqual(self.compare(candidate)[0], 0)
        self.assertEqual(self.compare(candidate, ["--expected-backend", "burnmetal", "--allow-model-change"])[0], 0)


if __name__ == "__main__":
    unittest.main()
