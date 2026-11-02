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
import subprocess
import time

from variants import SOURCE, make_variant
from snapshot import freeze, copy
from process_cleanup import cleanup
from log_results import parse

ROOT = Path(__file__).resolve().parents[3]
VARIANTS = ["baseline", "parent-gate", "posix-spawn"]


def digest(data):
    return hashlib.sha256(data.encode()).hexdigest()


def materialize(tree, name, text):
    target = tree / name
    target.unlink()
    target.write_text(text)


def prepare(destination, variant, probe, snapshot, inputs):
    copy(snapshot, destination)
    source = (snapshot / SOURCE).read_text()
    transformed = make_variant(source, variant, inputs)
    materialize(destination, SOURCE, transformed)
    test_name = "tests/session_host_bounded_process.zig"
    extra = inputs["extra_tests.zig.inc"].replace("POC_PROBE_LITERAL", json.dumps(str(probe)))
    combined = (snapshot / test_name).read_text() + extra
    materialize(destination, test_name, combined)
    expected = re.findall(r'^test "([^\"]+)"', combined, re.M)
    build_name = "build/session_host_release_gates.zig"
    build = (snapshot / build_name).read_text()
    old = 'run_bounded_process_tests.addArg("--maru-expect-tests=24");'
    if build.count(old) != 1:
        raise ValueError("bounded test-count guard changed")
    materialize(destination, build_name, build.replace(old, f'run_bounded_process_tests.addArg("--maru-expect-tests={len(expected)}");'))
    return {"baseline_sha256": digest(source), "variant_sha256": digest(transformed), "expected_names": expected}


def execute(command, cwd, path, timeout=600, expected_names=None):
    started = time.monotonic()
    with path.open("wb") as log:
        child = subprocess.Popen(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            cleanup(child.pid)
            child.wait()
            code = "timeout"
    # A successful driver exit must not hide workers reparented after a launch failure.
    leaks = cleanup(child.pid)
    raw = path.read_text(errors="replace")
    parsed = parse(raw, len(expected_names), expected_names=expected_names,
                   required_modes=any(name.startswith("PoC ") for name in expected_names)) if expected_names else {
        "case_results": [], "test_summaries": [], "fence_measurements": [], "validation": {"complete": True, "errors": []}}
    if code == 0 and any(row["failed"] for row in parsed["test_summaries"]):
        parsed["validation"] = {"complete": False, "errors": ["zero exit contradicts failures"]}
    return {"command": command, "exit": code, "seconds": time.monotonic() - started,
            "log": path.name, "log_sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "expected_names": expected_names,
            "leaked_processes": leaks, **parsed}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--only", choices=VARIANTS, action="append")
    parser.add_argument("--skip-race-control", action="store_true")
    parser.add_argument("--bounded-only", action="store_true")
    args = parser.parse_args()
    if args.rounds < 0:
        parser.error("rounds must be non-negative")
    if args.only and len(args.only) != len(set(args.only)):
        parser.error("duplicate variant")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT).decode().strip()
    snapshot = output / "source-snapshot"
    freeze(ROOT, snapshot, head)
    inputs = {name: Path(__file__).with_name(name).read_text() for name in [
        "parent_gate.zig.inc", "posix_spawn.zig.inc", "extra_tests.zig.inc", "probe.c", "race_control.c"]}
    input_dir = output / "inputs"
    input_dir.mkdir()
    for name, text in inputs.items():
        (input_dir / name).write_text(text)
    zig = subprocess.check_output(["mise", "which", "zig"], cwd=ROOT).decode().strip()
    report = {"schema": "maru.spawn-strategy-poc.v2", "head": head, "input_sha256": {name: digest(text) for name, text in inputs.items()}, "platform": os.uname().release,
        "zig_version": subprocess.check_output([zig, "version"]).decode().strip(),
        "rounds": args.rounds, "bounded_only": args.bounded_only, "skip_race_control": args.skip_race_control,
        "requested_variants": args.only or VARIANTS,
        "race_controls": [], "variants": {},
        "limitations": ["Experimental source copies, not a product repair or complete main CI.",
                        "Native spawn failure is intentionally not converted into a synthetic child exit.",
                        "Existing deadline clocks start after launch; startup latency needs separate review."]}
    def save():
        (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    probe = output / "child-probe"
    subprocess.run(["xcrun", "clang", "-O2", "-Wall", "-Wextra", str(input_dir / "probe.c"), "-o", str(probe)], check=True)
    if not args.skip_race_control:
        binary = output / "race-control"
        subprocess.run(["xcrun", "clang", "-O2", "-Wall", "-Wextra", str(input_dir / "race_control.c"), "-o", str(binary)], check=True)
        for ordering in ["overlap", "parent-first", "child-first", "child-only"]:
            row = execute([str(binary), ordering, "6000"], ROOT, output / f"race-{ordering}.log")
            report["race_controls"].append(row)
            save()
            print(f"race ordering={ordering} exit={row['exit']}", flush=True)
    for variant in args.only or VARIANTS:
        tree = output / variant
        hashes = prepare(tree, variant, probe, snapshot, inputs)
        records = []
        report["variants"][variant] = {**hashes, "runs": records}
        targets = [("bounded", "test-session-host-bounded-process")]
        if not args.bounded_only:
            targets += [(f"fence-{round_id}", "test-session-host-release-adapter-profile-authored-attestation-fence") for round_id in range(args.rounds + 1)]
        for label, target in targets:
            command = [zig, "build", target, "-Doptimize=Debug", "-j1"]
            expected_names = hashes["expected_names"] if label == "bounded" else re.findall(
                r'^test "([^\"]+)"', (snapshot / "tests/session_host_release_adapter_profile_authored_attestation_fence.zig").read_text(), re.M)
            row = execute(command, tree, output / f"{variant}-{label}.log", expected_names=expected_names)
            row["label"] = label
            row["warmup"] = label == "fence-0"
            records.append(row)
            save()
            print(f"variant={variant} case={label} exit={row['exit']} seconds={row['seconds']:.2f}", flush=True)
            if not row["test_summaries"]:
                # Compilation/setup failure cannot be turned into a passing or failing test count.
                print(f"variant={variant} no executed test summary; see {row['log']}", flush=True)
                break
        if digest((tree / SOURCE).read_text()) != hashes["variant_sha256"]:
            raise RuntimeError("prototype changed during execution")
    save()
    print(f"results={output / 'results.json'}", flush=True)
    rows = [row for variant in report["variants"].values() for row in variant["runs"]]
    if any(not row["validation"]["complete"] or row["leaked_processes"] or row["exit"] == "timeout" for row in rows):
        raise SystemExit(2)


if __name__ == "__main__":
    main()
