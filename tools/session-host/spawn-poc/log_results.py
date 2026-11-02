"""Validate complete test evidence before it can support a comparison."""
import re


def parse(raw, expected_compiled=26, expected_batches=2, expected_names=None, required_modes=False):
    cases, summaries, batches, measurements, errors = [], [], [], [], []
    batch = None
    modes = []
    for line in raw.splitlines():
        mode = re.search(r"poc_test_mode mode=(\w+)", line)
        if mode:
            modes.append(mode[1])
        header = re.match(r"^(\d+)/(\d+) (.+)\.\.\.(.*)$", line)
        if header:
            ordinal, compiled = int(header[1]), int(header[2])
            if ordinal == 1:
                batch = []
                batches.append(batch)
            if batch is None:
                errors.append("missing first test")
                batch = []
                batches.append(batch)
            if ordinal != len(batch) + 1 or compiled != expected_compiled:
                errors.append("test ordinal or compiled count mismatch")
            row = {"name": header[3], "compiled": compiled, "status": "unknown"}
            if any(previous["name"] == row["name"] for previous in batch):
                errors.append("duplicate test name")
            cases.append(row)
            batch.append(row)
            tail = header[4]
            if tail == "OK": row["status"] = "passed"
            elif tail == "SKIP": row["status"] = "skipped"
            elif tail == "FILTERED": row["status"] = "filtered"
            elif tail.startswith("FAIL ("): row["status"] = "failed"
        elif cases and line == "OK":
            cases[-1]["status"] = "passed"
        if cases and line.startswith("FAIL ("):
            cases[-1]["status"] = "failed"
        summary = re.fullmatch(r"All (\d+) tests passed\.|(\d+) passed; (\d+) skipped; (\d+) failed\.", line)
        if summary:
            reported = {"passed": int(summary[1] or summary[2]), "skipped": 0 if summary[1] else int(summary[3]),
                        "failed": 0 if summary[1] else int(summary[4])}
            actual = {key: sum(row["status"] == key for row in batch or []) for key in reported}
            if actual != reported or len(batch or []) != expected_compiled:
                errors.append("summary contradicts test cases")
            summaries.append(reported)
        if "profile_authored_attestation_fence_process schema=" in line:
            measurements.append(dict(re.findall(r"(\w+)=([^\s]+)", line)))
    if len(batches) != expected_batches or len(summaries) != expected_batches:
        errors.append("missing or duplicate optimization batch")
    if any(len(group) != expected_compiled for group in batches):
        errors.append("truncated batch")
    if any(row["status"] in {"unknown", "filtered"} for row in cases):
        errors.append("unknown or filtered test")
    if expected_names is not None:
        for group in batches:
            if {row["name"].split(".test.", 1)[-1] for row in group} != set(expected_names):
                errors.append("test inventory mismatch")
    if required_modes and (len(modes) != 2 or set(modes) != {"debug", "fast"}):
        errors.append("missing or duplicate optimization mode")
    return {"case_results": cases, "test_summaries": summaries, "fence_measurements": measurements,
            "validation": {"complete": not errors, "errors": sorted(set(errors)), "expected_compiled": expected_compiled}}


def performance_eligible(row, parsed):
    if row["exit"] != 0 or row.get("leaked_processes") or not parsed["validation"]["complete"]:
        return False
    if any(summary["failed"] or summary["skipped"] for summary in parsed["test_summaries"]):
        return False
    records = parsed["fence_measurements"]
    if parsed["validation"]["expected_compiled"] != 15:
        return False
    if len(records) != 2 or {x.get("mode") for x in records} != {"debug", "fast"}:
        return False
    try:
        for record in records:
            if record.get("schema") != "maru.session-host-profile-authored-attestation-fence-process-perf.v1":
                return False
            if any(int(record[key]) != 0 for key in ["failures", "fd_delta", "stderr_bytes", "residue"]):
                return False
            if int(record["samples_per_profile"]) != 20:
                return False
            if [int(record[key]) for key in ["rejected_invalid", "baseline_verifications", "upgrade_verifications"]] != [1, 2, 3]:
                return False
            for profile in ["baseline", "upgrade"]:
                median, p95, maximum = [int(record[f"{profile}_{stat}_ns"]) for stat in ["median", "p95", "max"]]
                if not 0 < median <= p95 <= maximum:
                    return False
    except (KeyError, ValueError, TypeError):
        return False
    return True
