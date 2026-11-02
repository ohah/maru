"""Adversarial evidence and ownership checks, independent of prototype expectations."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from analyze import read_record
from log_results import parse, performance_eligible
from process_cleanup import live_session
from run import execute
from snapshot import freeze, copy
from variants import make_variant


def log(count=2):
    return "\n".join("\n".join([f"{i}/{count} sample.test.t{i}...OK" for i in range(1, count + 1)]) + f"\nAll {count} tests passed." for _ in range(2))


def perf():
    fields = "schema=maru.session-host-profile-authored-attestation-fence-process-perf.v1 samples_per_profile=20 failures=0 fd_delta=0 stderr_bytes=0 residue=0 rejected_invalid=1 baseline_verifications=2 upgrade_verifications=3 baseline_median_ns=10 baseline_p95_ns=20 baseline_max_ns=30 upgrade_median_ns=20 upgrade_p95_ns=30 upgrade_max_ns=40"
    return log(15) + "\n" + "\n".join(f"profile_authored_attestation_fence_process {fields} mode={mode}" for mode in ["debug", "fast"])


class Evidence(unittest.TestCase):
    def test_complete_control(self): self.assertTrue(parse(log(), 2)["validation"]["complete"])
    def test_empty(self): self.assertFalse(parse("", 2)["validation"]["complete"])
    def test_truncated(self): self.assertFalse(parse(log().rsplit("\n", 2)[0], 2)["validation"]["complete"])
    def test_missing_mode(self): self.assertFalse(parse(log().split("All 2 tests passed.")[0], 2)["validation"]["complete"])
    def test_wrong_compiled_count(self): self.assertFalse(parse(log().replace("/2 ", "/3 "), 2)["validation"]["complete"])
    def test_duplicate_ordinal(self): self.assertFalse(parse(log().replace("2/2", "1/2"), 2)["validation"]["complete"])
    def test_duplicate_name(self): self.assertFalse(parse(log().replace("test.t2", "test.t1"), 2)["validation"]["complete"])
    def test_false_summary(self): self.assertFalse(parse(log().replace("All 2", "All 3"), 2)["validation"]["complete"])
    def test_unknown_status(self): self.assertFalse(parse(log().replace("...OK", "..."), 2)["validation"]["complete"])
    def test_filtered(self): self.assertFalse(parse(log().replace("...OK", "...FILTERED"), 2)["validation"]["complete"])
    def test_inventory(self): self.assertFalse(parse(log(), 2, expected_names=["other", "t2"])["validation"]["complete"])
    def test_modes_present(self): self.assertTrue(parse(log() + "\npoc_test_mode mode=debug\npoc_test_mode mode=fast", 2, required_modes=True)["validation"]["complete"])
    def test_duplicate_modes(self): self.assertFalse(parse(log() + "\npoc_test_mode mode=debug\npoc_test_mode mode=debug", 2, required_modes=True)["validation"]["complete"])
    def test_missing_modes(self): self.assertFalse(parse(log(), 2, required_modes=True)["validation"]["complete"])
    def test_inline_failure(self):
        text = log().replace("test.t2...OK", "test.t2...FAIL (SpawnFailed)").replace("All 2 tests passed.", "1 passed; 0 skipped; 1 failed.")
        parsed = parse(text, 2)
        self.assertTrue(parsed["validation"]["complete"])
        self.assertEqual(sum(x["status"] == "failed" for x in parsed["case_results"]), 2)
    def test_skipped_not_passed(self):
        text = log().replace("test.t2...OK", "test.t2...SKIP").replace("All 2 tests passed.", "1 passed; 1 skipped; 0 failed.")
        parsed = parse(text, 2)
        self.assertTrue(parsed["validation"]["complete"])
        self.assertEqual(sum(x["status"] == "passed" for x in parsed["case_results"]), 2)
    def test_perf_positive(self): self.assertTrue(performance_eligible({"exit": 0}, parse(perf(), 15)))
    def test_failed_run_timing(self): self.assertFalse(performance_eligible({"exit": 1}, parse(perf(), 15)))
    def test_leaked_run_timing(self): self.assertFalse(performance_eligible({"exit": 0, "leaked_processes": [1]}, parse(perf(), 15)))
    def test_missing_perf_field(self): self.assertFalse(performance_eligible({"exit": 0}, parse(perf().replace("failures=0", ""), 15)))
    def test_duplicate_perf_mode(self): self.assertFalse(performance_eligible({"exit": 0}, parse(perf().replace("mode=fast", "mode=debug"), 15)))
    def test_invalid_percentile(self): self.assertFalse(performance_eligible({"exit": 0}, parse(perf().replace("baseline_p95_ns=20", "baseline_p95_ns=1"), 15)))
    def test_invalid_schema(self): self.assertFalse(performance_eligible({"exit": 0}, parse(perf().replace("perf.v1", "perf.v9"), 15)))
    def test_verifier_bypass(self): self.assertFalse(performance_eligible({"exit": 0}, parse(perf().replace("baseline_verifications=2", "baseline_verifications=0"), 15)))
    def test_digest_corruption(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); path = root / "log.txt"; path.write_text(log())
            row = {"log": "log.txt", "exit": 0, "log_sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
            path.write_text(log() + "corruption")
            self.assertEqual(read_record(root, row, 2)[1], "log digest mismatch")
    def test_path_escape(self): self.assertEqual(read_record(Path("."), {"log": "../secret"}, 2)[1], "invalid log path")
    def test_missing_log(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(read_record(Path(directory), {"log": "absent"}, 2)[1], "missing log")
    def test_zero_exit_cannot_hide_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake = log().replace("test.t2...OK", "test.t2...FAIL (Wrong)").replace("All 2 tests passed.", "1 passed; 0 skipped; 1 failed.")
            row = execute([sys.executable, "-c", "print(" + repr(fake) + ")"], root, root / "false-green.log", expected_names=["t1", "t2"])
            self.assertFalse(row["validation"]["complete"])
            self.assertFalse(read_record(root, row, 2)[0]["validation"]["complete"])
    def test_unknown_variant(self):
        with self.assertRaises(ValueError): make_variant("", "typo")
    def test_source_drift(self):
        with self.assertRaises(ValueError): make_variant("", "parent-gate")
    def test_negative_rounds(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "not-created"
            result = subprocess.run([sys.executable, str(Path(__file__).with_name("run.py")), "--output", str(output), "--rounds", "-1"], capture_output=True)
            self.assertEqual(result.returncode, 2); self.assertFalse(output.exists())


class Ownership(unittest.TestCase):
    def test_committed_snapshot_and_independent_copies(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); repo = root / "repo"; repo.mkdir()
            def git(*args): return subprocess.check_output(["git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "-c", "user.name=PoC", "-c", "user.email=poc@example.invalid", *args], cwd=repo)
            git("init", "-q"); (repo / "value").write_text("committed"); git("add", "value"); git("commit", "-qm", "test")
            head = git("rev-parse", "HEAD").decode().strip()
            snapshot = root / "snapshot"; freeze(repo, snapshot, head)
            (repo / "value").write_text("concurrent worktree edit")
            candidate = root / "candidate"; copy(snapshot, candidate)
            self.assertEqual((candidate / "value").read_text(), "committed")
            (candidate / "value").write_text("variant mutation")
            self.assertEqual((snapshot / "value").read_text(), "committed")
            self.assertEqual((repo / "value").read_text(), "concurrent worktree edit")
    def test_reparented_group_cleanup_after_normal_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            code = "import os,time; r,w=os.pipe(); p=os.fork();\nif p==0:\n os.setpgid(0,0); os.write(w,b'x'); time.sleep(30)\nelse:\n os.read(r,1); os._exit(0)"
            row = execute([sys.executable, "-c", code], root, root / "normal.log", timeout=2)
            self.assertEqual(row["exit"], 0); self.assertTrue(row["leaked_processes"])
    def test_timeout_cleans_separate_process_group(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            code = "import os,time; p=os.fork();\nif p==0: os.setpgid(0,0)\ntime.sleep(30)"
            row = execute([sys.executable, "-c", code], root, root / "timeout.log", timeout=0.5)
            self.assertEqual(row["exit"], "timeout")


if __name__ == "__main__": unittest.main(verbosity=2)
