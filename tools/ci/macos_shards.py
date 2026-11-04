#!/usr/bin/env python3
"""Execute and independently account for the three macOS gate partitions."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time

COUNT = 3
# These commands used to follow/before the monolithic native gate in ci.yml.
# Their single registration here is used by execution and receipt verification.
EXTRAS = (
    (0, "before", "ssh-output-oom", ("python3", "tools/test-ssh-output-oom.py")),
    (0, "after", "ssh-pipe-cleanup", ("python3", "tools/test-ssh-pipe-cleanup.py")),
    (0, "after", "ssh-wait-retry", ("python3", "tools/test-ssh-wait-retry.py")),
    (1, "after", "capture-diagnostics", ("sh", "tools/test-macos-capture-diagnostics.sh")),
    (1, "after", "archive-harness", ("python3", "tools/test-macos-archive-harness.py")),
    (1, "after", "shared-restore-oracles", ("python3", "-m", "unittest", "discover", "-s", "tools/shared-restore-app", "-p", "test_gui_launch.py")),
    (1, "after", "palette-ime-oracles", ("python3", "-m", "unittest", "discover", "-s", "tools/palette-ime", "-p", "test_*.py")),
    (1, "after", "address-ime-oracles", ("python3", "-m", "unittest", "discover", "-s", "tools/address-ime", "-p", "test_*.py")),
    (1, "after", "rename-ime-oracles", ("python3", "-m", "unittest", "discover", "-s", "tools/rename-ime", "-p", "test_*.py")),
    (1, "after", "settings-ime-oracles", ("python3", "-m", "unittest", "discover", "-s", "tools/settings-ime", "-p", "test_*.py")),
    (2, "after", "ssh-fd-isolation", ("python3", "tools/test-ssh-fd-isolation.py")),
    (2, "after", "remote-scm", ("zig", "build", "test-remote-scm", "--summary", "all")),
)


def mode_for(event: str, ref: str, proven: str, changes: str) -> str:
    """Only a successful same-tree proof on trusted main may replace test reruns."""
    return "compile" if (event, ref, proven, changes) == ("push", "refs/heads/main", "true", "success") else "test"


def environment_mode(env=os.environ) -> str:
    return mode_for(env.get("GITHUB_EVENT_NAME", ""), env.get("GITHUB_REF", ""),
                    env.get("PROVEN_MACOS_ONLY", ""), env.get("CHANGES_RESULT", ""))


def sequence(index: int, mode: str):
    if type(index) is not int or not 0 <= index < COUNT or mode not in ("test", "compile"):
        raise ValueError("invalid shard or mode")
    native = ("native-gates", ("zig", "build", "test-macos-only" if mode == "test" else "compile-macos-only",
                                f"-Dmacos-only-shard={index}/{COUNT}", "--summary", "all"))
    if mode == "compile":
        return [native]
    before = [(name, cmd) for owner, phase, name, cmd in EXTRAS if owner == index and phase == "before"]
    after = [(name, cmd) for owner, phase, name, cmd in EXTRAS if owner == index and phase == "after"]
    return before + [native] + after


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load(path: Path):
    def bad(value):
        raise ValueError(f"non-finite JSON constant {value}")
    return json.loads(path.read_text(), parse_constant=bad)


def manifest(value: dict, index: int | None = None):
    if not isinstance(value, dict) or type(value.get("schema")) is not int or value["schema"] != 1:
        raise ValueError("manifest schema")
    count, part = value.get("count"), value.get("shard")
    if type(count) is not int or count < 1 or (part is None and count != 1):
        raise ValueError("manifest partition count")
    if part is not None and (type(part) is not int or not 0 <= part < count):
        raise ValueError("manifest partition index")
    if index is not None and (type(value.get("shard")) is not int or value["shard"] != index or
                              type(value.get("count")) is not int or value["count"] != COUNT):
        raise ValueError("manifest shard identity")
    for key in ("catalog", "selected"):
        items = value.get(key)
        if not isinstance(items, list) or not items or any(type(x) is not str or not x for x in items):
            raise ValueError(f"manifest {key}")
        if items != sorted(set(items)):
            raise ValueError(f"manifest {key} is not sorted and unique")
    if not set(value["selected"]) <= set(value["catalog"]):
        raise ValueError("selected root outside catalog")
    if type(value.get("compile_artifacts")) is not int or value["compile_artifacts"] <= 0:
        raise ValueError("empty compile graph")
    if type(value.get("warm_test_runs")) is not int or value["warm_test_runs"] != 0:
        raise ValueError("warm graph contains test execution")


def coverage(plans: list[dict], full: dict | None = None):
    if len(plans) != COUNT:
        raise ValueError("need exactly three shard manifests")
    for i, plan in enumerate(plans):
        manifest(plan, i)
    catalog = plans[0]["catalog"]
    if any(p["catalog"] != catalog for p in plans):
        raise ValueError("different catalogs")
    selected = [x for plan in plans for x in plan["selected"]]
    if len(selected) != len(set(selected)) or set(selected) != set(catalog):
        raise ValueError("missing or repeated root across shards")
    if full is not None:
        manifest(full)
        if full.get("shard") is not None or full.get("count") != 1 or full["selected"] != catalog or full["catalog"] != catalog:
            raise ValueError("partition differs from the unsharded local gate")
    return len(catalog)


def receipt(value: dict, plan_bytes: bytes, index: int, mode: str, head: str, run_id: str, attempt: int):
    if not isinstance(value, dict) or type(value.get("schema")) is not int or value["schema"] != 1:
        raise ValueError("receipt schema")
    if type(value.get("shard")) is not int or value["shard"] != index or value.get("mode") != mode:
        raise ValueError("receipt shard/mode")
    if not head or value.get("head") != head or value.get("result") != "success":
        raise ValueError("receipt head/result")
    if not run_id or value.get("run_id") != run_id or type(value.get("run_attempt")) is not int or value["run_attempt"] != attempt:
        raise ValueError("receipt run identity")
    if value.get("manifest_sha256") != sha(plan_bytes):
        raise ValueError("manifest/receipt binding")
    stages = value.get("stages")
    expected = sequence(index, mode)
    if not isinstance(stages, list) or any(not isinstance(x, dict) for x in stages) or [x.get("name") for x in stages] != [x[0] for x in expected]:
        raise ValueError("missing or repeated stage")
    for stage in stages:
        seconds = stage.get("seconds")
        if stage.get("result") != "success" or type(seconds) not in (float, int) or not math.isfinite(seconds) or seconds < 0:
            raise ValueError("invalid stage result/timing")


def run(index: int):
    mode = environment_mode()
    commands = sequence(index, mode)
    report = Path("zig-out/macos-only-receipt.json")
    report.parent.mkdir(parents=True, exist_ok=True)
    report.unlink(missing_ok=True)  # A prior local report is never proof of this attempt.
    manifest_path = Path("zig-out/macos-only-manifest.json")
    manifest_path.unlink(missing_ok=True)
    result = dict(schema=1, shard=index, mode=mode, head=os.environ.get("GITHUB_SHA", ""),
                  run_id=os.environ.get("GITHUB_RUN_ID", ""), run_attempt=int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")),
                  result="failed", stages=[])
    try:
        for name, command in commands:
            print(f"macOS shard {index}/{COUNT}: {mode} {name}: {list(command)}", flush=True)
            started = time.monotonic()
            child = subprocess.run(command)
            seconds = time.monotonic() - started
            result["stages"].append(dict(name=name, seconds=seconds, result="success" if child.returncode == 0 else "failed"))
            print(f"macOS stage {name}: {seconds:.3f}s exit={child.returncode}", flush=True)
            if child.returncode:
                raise subprocess.CalledProcessError(child.returncode, command)
        data = manifest_path.read_bytes()
        manifest(json.loads(data), index)
        result["manifest_sha256"] = sha(data)
        result["result"] = "success"
    finally:
        report.write_text(json.dumps(result, indent=2) + "\n")


def verify(directory: Path, env=os.environ):
    result = env.get("WORKERS_RESULT", "")
    if env.get("CHANGES_RESULT") == "success" and env.get("RUNTIME_CHANGED") == "false":
        if result != "skipped":
            raise ValueError("non-runtime classification disagrees with worker result")
        print("macOS-only gates: classified non-runtime change; all workers skipped")
        return
    if result != "success":
        raise ValueError(f"macOS workers did not succeed: {result}")
    mode = environment_mode(env)
    # Keep failed attempt evidence, but bind each selected successful receipt to
    # this run/head. Partial job reruns can reuse other shards from an earlier attempt.
    # Include log-only/empty artifacts too: a newer incomplete attempt cannot
    # disappear from selection and expose an older successful receipt.
    folders = {p for p in directory.iterdir() if p.is_dir()} if directory.is_dir() else set()
    candidates = {i: {} for i in range(COUNT)}
    maximum = int(env.get("GITHUB_RUN_ATTEMPT", "0"))
    for folder in folders:
        match = re.fullmatch(r"macos-only-shard-([0-2])-attempt-([1-9][0-9]*)", folder.name)
        if not match:
            raise ValueError("invalid artifact directory")
        index, attempt = map(int, match.groups())
        if attempt > maximum or attempt in candidates[index]:
            raise ValueError("duplicate or future artifact attempt")
        candidates[index][attempt] = folder
    if any(not attempts for attempts in candidates.values()):
        raise ValueError("missing shard artifacts")
    plans = [None] * COUNT
    stages = 0
    for i, attempts in candidates.items():
        attempt = max(attempts)
        f = attempts[attempt] / "macos-only-manifest.json"
        plan = load(f)
        manifest(plan, i)
        report_path = f.with_name("macos-only-receipt.json")
        report = load(report_path)
        receipt(report, f.read_bytes(), i, mode, env.get("GITHUB_SHA", ""), env.get("GITHUB_RUN_ID", ""), attempt)
        plans[i] = plan
        stages += len(report["stages"])
        print(f"shard {i}/{COUNT}: {len(plan['selected'])} roots; {mode}; {report['stages']}")
    total = coverage(plans)
    print(f"macOS-only gates: {total} roots exactly once; {stages} successful stages; mode={mode}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    runner = commands.add_parser("run")
    runner.add_argument("shard", type=int)
    checker = commands.add_parser("verify")
    checker.add_argument("directory", type=Path)
    planner = commands.add_parser("plans")
    planner.add_argument("full", type=Path)
    planner.add_argument("parts", type=Path, nargs=3)
    args = parser.parse_args()
    if args.command == "run":
        run(args.shard)
    elif args.command == "verify":
        verify(args.directory)
    else:
        total = coverage([load(p) for p in args.parts], load(args.full))
        print(f"macOS plan coverage: {total} roots exactly once")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as exc:
        print(f"macOS gate verification failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
