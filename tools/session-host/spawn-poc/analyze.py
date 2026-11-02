#!/usr/bin/env python3
"""Summarize observed PoC logs without treating prototype failures as driver failures."""
import json
from pathlib import Path
import re
import statistics
import sys


from log_results import parse, performance_eligible
import hashlib


def cases(raw):
    return parse(raw)["case_results"]


def read_payload(root, row):
    name = row.get("log", "")
    if not name or Path(name).name != name or "\\" in name:
        return b"", "invalid log path"
    try:
        payload = (root / name).read_bytes()
    except OSError:
        return b"", "missing log"
    if row.get("log_sha256") and hashlib.sha256(payload).hexdigest() != row["log_sha256"]:
        return b"", "log digest mismatch"
    return payload, None


def read_record(root, row, expected=26):
    payload, error = read_payload(root, row)
    if error:
        return parse("", expected), error
    expected_names = row.get("expected_names")
    parsed = parse(payload.decode(errors="replace"), len(expected_names) if expected_names else expected,
                   expected_names=expected_names, required_modes=any(name.startswith("PoC ") for name in expected_names or []))
    if row["exit"] == 0 and any(summary["failed"] for summary in parsed["test_summaries"]):
        parsed["validation"]["complete"] = False
        parsed["validation"]["errors"].append("zero exit contradicts failures")
    return parsed, None


def summarize(root):
    original = json.loads((root / "results.json").read_text())
    result = {"head": original["head"], "platform": original["platform"], "race_controls": [], "variants": {}, "evidence_complete": True}
    for row in original["race_controls"]:
        payload, error = read_payload(root, row)
        controls = []
        for line in payload.decode(errors="replace").splitlines():
            if line.startswith("summary "):
                controls.append(dict(re.findall(r"(\w+)=([^\s]+)", line)))
        if error or row["exit"] != 0 or len(controls) != 1:
            result["evidence_complete"] = False
        result["race_controls"].extend(controls)
    if original.get("schema") == "maru.spawn-strategy-poc.v2" and not original.get("skip_race_control"):
        if {record.get("mode") for record in result["race_controls"]} != {"overlap", "parent-first", "child-first", "child-only"}:
            result["evidence_complete"] = False
    for name, variant in original["variants"].items():
        bounded = next((row for row in variant["runs"] if row["label"] == "bounded"), None)
        parsed, bounded_error = read_record(root, bounded) if bounded else (parse(""), "missing bounded run")
        observed = parsed["case_results"]
        complete = parsed["validation"]["complete"] and bounded_error is None and not bounded.get("leaked_processes") if bounded else False
        launch = []
        if bounded:
            for line in (root / bounded["log"]).read_text(errors="replace").splitlines() if bounded_error is None else []:
                if "poc_group_launch mode=" in line:
                    launch.append(dict(re.findall(r"(\w+)=([^\s]+)", line)))
        groups = {}
        for label, supplement in [("existing_contracts", False), ("poc_supplements", True)]:
            selected = [row for row in observed if (".test.PoC " in row["name"]) == supplement]
            groups[label] = {"observed_cases": len(selected), "passed": sum(row["status"] == "passed" for row in selected),
                             "failed": sum(row["status"] == "failed" for row in selected),
                             "unknown": sum(row["status"] == "unknown" for row in selected),
                             "skipped": sum(row["status"] == "skipped" for row in selected),
                             "failures": [row["name"] for row in selected if row["status"] == "failed"]}
        timings = {}
        fence_runs = [row for row in variant["runs"] if row["label"].startswith("fence-")]
        accepted = []
        valid_runs = []
        for row in fence_runs:
            fence_parsed, fence_error = read_record(root, row, 15)
            valid = fence_error is None and performance_eligible(row, fence_parsed)
            complete = complete and fence_parsed["validation"]["complete"] and fence_error is None
            if row["exit"] == 0 and not valid:
                complete = False
            if valid:
                valid_runs.append(row["label"])
            if not valid or row["warmup"]:
                continue
            accepted.append(row["label"])
            for measure in fence_parsed["fence_measurements"]:
                mode = measure["mode"]
                for profile in ["baseline", "upgrade"]:
                    bucket = timings.setdefault(f"{mode}/{profile}", {"round_medians_ns": [], "round_p95_ns": [], "samples": 0})
                    bucket["round_medians_ns"].append(int(measure[f"{profile}_median_ns"]))
                    bucket["round_p95_ns"].append(int(measure[f"{profile}_p95_ns"]))
                    bucket["samples"] += int(measure["samples_per_profile"])
        for bucket in timings.values():
            bucket["median_of_round_medians_ns"] = statistics.median(bucket["round_medians_ns"])
        expected_runs = 0 if original.get("bounded_only") else original["rounds"] + 1
        complete = complete and len(fence_runs) == expected_runs
        result["evidence_complete"] = result["evidence_complete"] and complete
        result["variants"][name] = {"evidence_complete": complete, "bounded_evidence_error": bounded_error,
            "bounded_validation": parsed["validation"], "accepted_timing_runs": accepted, **groups, "launch_measurements": launch, "bounded_exit": bounded["exit"] if bounded else None,
            "fence_runs": len(fence_runs), "fence_successes": len(valid_runs),
            "timings": timings}
    requested = original.get("requested_variants", list(original["variants"]))
    result["evidence_complete"] = result["evidence_complete"] and bool(requested) and set(requested) == set(original["variants"])
    (root / "comparison.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    summarize(Path(sys.argv[1]))
