#!/usr/bin/env python3
"""Run unchanged Maru contracts against isolated process-launch prototypes.

Failures are comparison results, never rewritten expectations. No product source is edited.
The output keeps every command, exit code, source hash, test count, and performance record.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

from variants import SOURCE, make_variant

ROOT = Path(__file__).resolve().parents[3]
VARIANTS = ["baseline", "parent-gate", "posix-spawn"]


def digest(data):
    return hashlib.sha256(data.encode()).hexdigest()


def materialize(tree, name, text):
    target = tree / name
    target.unlink()
    target.write_text(text)


def prepare(destination, variant, probe):
    destination.mkdir(parents=True, exist_ok=False)
    names = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
    for name in filter(None, names):
        source = ROOT / name
        if not source.is_file():
            continue
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.symlink_to(source)
    if (ROOT / "zig-pkg").exists():
        (destination / "zig-pkg").symlink_to(ROOT / "zig-pkg", target_is_directory=True)
    source = (ROOT / SOURCE).read_text()
    transformed = make_variant(source, variant)
    materialize(destination, SOURCE, transformed)
    test_name = "tests/session_host_bounded_process.zig"
    extra = Path(__file__).with_name("extra_tests.zig.inc").read_text().replace("POC_PROBE_LITERAL", json.dumps(str(probe)))
    materialize(destination, test_name, (ROOT / test_name).read_text() + extra)
    build_name = "build/session_host_release_gates.zig"
    build = (ROOT / build_name).read_text()
    assert build.count('run_bounded_process_tests.addArg("--maru-expect-tests=24");') == 1
    materialize(destination, build_name, build.replace('run_bounded_process_tests.addArg("--maru-expect-tests=24");', 'run_bounded_process_tests.addArg("--maru-expect-tests=26");'))
    return {"baseline_sha256": digest(source), "variant_sha256": digest(transformed)}


def execute(command, cwd, path, timeout=600):
    started = time.monotonic()
    with path.open("wb") as log:
        child = subprocess.Popen(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            # Experimental launch bugs must not leave a blocked child after the driver times out.
            pairs = [tuple(map(int, line.split())) for line in subprocess.check_output(
                ["ps", "-axo", "pid=,ppid="]).decode().splitlines()]
            owned = {child.pid}
            while True:
                expanded = owned | {pid for pid, parent in pairs if parent in owned}
                if expanded == owned:
                    break
                owned = expanded
            for pid in reversed(sorted(owned)):
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            child.wait()
            code = "timeout"
    raw = path.read_text(errors="replace")
    summaries = []
    for match in re.finditer(r"All (\d+) tests passed\.|(\d+) passed; (\d+) skipped; (\d+) failed\.", raw):
        passed = int(match[1] or match[2])
        skipped, failed = (0, 0) if match[1] else (int(match[3]), int(match[4]))
        summaries.append({"passed": passed, "skipped": skipped, "failed": failed})
    measurements = []
    cases = []
    for line in raw.splitlines():
        header = re.match(r"^(\d+)/(\d+) (.+)\.\.\.(.*)$", line)
        if header:
            cases.append({"name": header[3], "compiled": int(header[2]), "status": "unknown"})
            tail = header[4]
            if tail == "OK":
                cases[-1]["status"] = "passed"
            elif tail == "SKIP":
                cases[-1]["status"] = "skipped"
            elif tail.startswith("FAIL ("):
                cases[-1]["status"] = "failed"
        elif cases and line == "OK":
            cases[-1]["status"] = "passed"
        if cases and line.startswith("FAIL ("):
            cases[-1]["status"] = "failed"
        if "profile_authored_attestation_fence_process schema=" in line:
            measurements.append(dict(re.findall(r"(\w+)=([^\s]+)", line)))
    return {"command": command, "exit": code, "seconds": time.monotonic() - started,
            "log": path.name, "test_summaries": summaries, "case_results": cases,
            "fence_measurements": measurements}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--only", choices=VARIANTS, action="append")
    parser.add_argument("--skip-race-control", action="store_true")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    zig = subprocess.check_output(["mise", "which", "zig"], cwd=ROOT).decode().strip()
    report = {"schema": "maru.spawn-strategy-poc.v1", "head": subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT).decode().strip(), "platform": os.uname().release,
        "zig_version": subprocess.check_output([zig, "version"]).decode().strip(),
        "rounds": args.rounds, "race_controls": [], "variants": {},
        "limitations": ["Experimental source copies, not a product repair or complete main CI.",
                        "Native spawn failure is intentionally not converted into a synthetic child exit.",
                        "Existing deadline clocks start after launch; startup latency needs separate review."]}
    def save():
        (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    probe = output / "child-probe"
    subprocess.run(["xcrun", "clang", "-O2", "-Wall", "-Wextra", str(Path(__file__).with_name("probe.c")), "-o", str(probe)], check=True)
    if not args.skip_race_control:
        binary = output / "race-control"
        subprocess.run(["xcrun", "clang", "-O2", "-Wall", "-Wextra", str(Path(__file__).with_name("race_control.c")), "-o", str(binary)], check=True)
        for ordering in ["overlap", "parent-first", "child-first", "child-only"]:
            row = execute([str(binary), ordering, "6000"], ROOT, output / f"race-{ordering}.log")
            report["race_controls"].append(row)
            save()
            print(f"race ordering={ordering} exit={row['exit']}", flush=True)
    for variant in args.only or VARIANTS:
        tree = output / variant
        hashes = prepare(tree, variant, probe)
        records = []
        report["variants"][variant] = {**hashes, "runs": records}
        targets = [("bounded", "test-session-host-bounded-process")]
        targets += [(f"fence-{round_id}", "test-session-host-release-adapter-profile-authored-attestation-fence") for round_id in range(args.rounds + 1)]
        for label, target in targets:
            command = [zig, "build", target, "-Doptimize=Debug", "-j1"]
            row = execute(command, tree, output / f"{variant}-{label}.log")
            row["label"] = label
            row["warmup"] = label == "fence-0"
            records.append(row)
            save()
            print(f"variant={variant} case={label} exit={row['exit']} seconds={row['seconds']:.2f}", flush=True)
            if not row["test_summaries"]:
                # Compilation/setup failure cannot be turned into a passing or failing test count.
                print(f"variant={variant} no executed test summary; see {row['log']}", flush=True)
                break
        assert digest((tree / SOURCE).read_text()) == hashes["variant_sha256"]
    assert (ROOT / SOURCE).read_text() == (output / "baseline" / SOURCE).read_text() if "baseline" in report["variants"] else True
    save()
    print(f"results={output / 'results.json'}", flush=True)


if __name__ == "__main__":
    main()
