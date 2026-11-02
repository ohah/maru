#!/usr/bin/env python3
"""Summarize observed PoC logs without treating prototype failures as driver failures."""
import json
from pathlib import Path
import re
import statistics
import sys


def cases(raw):
    found = []
    for line in raw.splitlines():
        match = re.match(r"^(\d+)/(\d+) (.+)\.\.\.(.*)$", line)
        if match:
            found.append({"name": match[3], "compiled": int(match[2]), "status": "unknown"})
            if match[4] == "OK":
                found[-1]["status"] = "passed"
            elif match[4] == "SKIP":
                found[-1]["status"] = "skipped"
            elif match[4].startswith("FAIL ("):
                found[-1]["status"] = "failed"
        elif found and line == "OK":
            found[-1]["status"] = "passed"
        if found and line.startswith("FAIL ("):
            found[-1]["status"] = "failed"
    return found


def summarize(root):
    original = json.loads((root / "results.json").read_text())
    result = {"head": original["head"], "platform": original["platform"], "race_controls": [], "variants": {}}
    for row in original["race_controls"]:
        for line in (root / row["log"]).read_text().splitlines():
            if line.startswith("summary "):
                result["race_controls"].append(dict(re.findall(r"(\w+)=([^\s]+)", line)))
    for name, variant in original["variants"].items():
        bounded = next((row for row in variant["runs"] if row["label"] == "bounded"), None)
        observed = cases((root / bounded["log"]).read_text(errors="replace")) if bounded else []
        launch = []
        if bounded:
            for line in (root / bounded["log"]).read_text(errors="replace").splitlines():
                if "poc_group_launch mode=" in line:
                    launch.append(dict(re.findall(r"(\w+)=([^\s]+)", line)))
        groups = {}
        for label, supplement in [("existing_contracts", False), ("poc_supplements", True)]:
            selected = [row for row in observed if (".test.PoC " in row["name"]) == supplement]
            groups[label] = {"observed_cases": len(selected), "passed": sum(row["status"] == "passed" for row in selected),
                             "failed": sum(row["status"] == "failed" for row in selected),
                             "unknown": sum(row["status"] == "unknown" for row in selected),
                             "failures": [row["name"] for row in selected if row["status"] == "failed"]}
        timings = {}
        fence_runs = [row for row in variant["runs"] if row["label"].startswith("fence-")]
        for row in fence_runs:
            if row["warmup"]:
                continue
            for measure in row["fence_measurements"]:
                mode = measure["mode"]
                for profile in ["baseline", "upgrade"]:
                    bucket = timings.setdefault(f"{mode}/{profile}", {"round_medians_ns": [], "round_p95_ns": [], "samples": 0})
                    bucket["round_medians_ns"].append(int(measure[f"{profile}_median_ns"]))
                    bucket["round_p95_ns"].append(int(measure[f"{profile}_p95_ns"]))
                    bucket["samples"] += int(measure["samples_per_profile"])
        for bucket in timings.values():
            bucket["median_of_round_medians_ns"] = statistics.median(bucket["round_medians_ns"])
        result["variants"][name] = {**groups, "launch_measurements": launch, "bounded_exit": bounded["exit"] if bounded else None,
            "fence_runs": len(fence_runs), "fence_successes": sum(row["exit"] == 0 for row in fence_runs),
            "timings": timings}
    (root / "comparison.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    summarize(Path(sys.argv[1]))
