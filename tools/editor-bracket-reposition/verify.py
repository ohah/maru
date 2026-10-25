#!/usr/bin/env python3
"""완료된 비교의 원시 로그·실행 순서·소스·실행 파일을 독립적으로 다시 대조한다."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import statistics
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[2]
NAMES = (
    "flat-3000.zig",
    "flat-15000.zig",
    "flat-50000.zig",
    "real-build.zig",
    "real-host.swift",
)
FIELDS = {
    "key",
    "views",
    "edit_ns",
    "frame_ns",
    "total_ns",
    "resolves",
    "rounds",
    "oracle",
    "tokens_before",
    "tokens_after",
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def samples(log, shared, structure, variant, verify):
    warm = re.findall(
        r"BRACKET_WARM pending_before=([01]) rounds=(\d+) views=([12])\n", log
    )
    require(
        len(warm) == 1
        and 1 <= int(warm[0][1]) <= 4096
        and int(warm[0][2]) == shared + 1,
        "Warm preparation",
    )
    require(
        "All 5 tests passed." in log and "FAIL (" not in log, "Compiled product gate"
    )
    rows = []
    for line in log.splitlines():
        if not line.startswith("BRACKET "):
            continue
        pairs = [part.split("=") for part in line.split()[1:]]
        require(
            all(len(p) == 2 and re.fullmatch(r"\d+", p[1]) for p in pairs),
            "Sample syntax",
        )
        require(
            len(pairs) == len(FIELDS) and {p[0] for p in pairs} == FIELDS,
            "Sample fields",
        )
        row = {k: int(v) for k, v in pairs}
        require(
            row["views"] == shared + 1 and row["oracle"] == int(verify),
            "Views or oracle",
        )
        require(
            row["total_ns"] == row["edit_ns"] + row["frame_ns"]
            and 1 <= row["rounds"] <= 128,
            "Timing or frame budget",
        )
        expected = (
            shared + 1 if structure else (shared + 1) * int(variant == "baseline")
        )
        require(row["resolves"] == expected, "Actual resolver work")
        require(
            row["tokens_before"] > 0
            and row["tokens_after"] == row["tokens_before"] + structure,
            "Canonical structure change",
        )
        if rows:
            require(
                rows[-1]["tokens_after"] == row["tokens_before"],
                "Canonical token continuity",
            )
        rows.append(row)
    require([r["key"] for r in rows] == list(range(20)), "Input order or coverage")
    return rows


def archive_hashes(head):
    process = subprocess.Popen(
        ["git", "archive", head, "src", "build.zig"], cwd=ROOT, stdout=subprocess.PIPE
    )
    hashes = {}
    with tarfile.open(fileobj=process.stdout, mode="r|") as archive:
        for entry in archive:
            if entry.isfile():
                stream = archive.extractfile(entry)
                digest = hashlib.sha256()
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
                hashes[entry.name] = digest.hexdigest()
    require(process.wait() == 0, "Historical source archive")
    return hashes


def verify(root, repetitions=3, historical=True):
    info = json.loads((root / "receipt.json").read_text())
    rows = json.loads((root / "samples.json").read_text())
    require(
        type(info.get("schema")) is int
        and info["schema"] == 1
        and info.get("target") == "bracket-reposition-comparison"
        and info.get("workload_model") == "exact-prefix-and-canonical-delimiter-growth",
        "Comparison model",
    )
    require(
        type(info.get("repetitions")) is int and info["repetitions"] == repetitions,
        "Repetition model",
    )
    require(info.get("original_unchanged") is True, "Incomplete execution")
    require(isinstance(rows, list), "Sample collection")
    require(
        isinstance(info.get("source_head"), str)
        and re.fullmatch(r"[0-9a-f]{40}", info["source_head"]),
        "Historical source identity",
    )
    if historical:
        require(
            archive_hashes(info["source_head"]) == info["original_sha256"],
            "Original historical source",
        )
    original = info["original_sha256"]
    for name in NAMES:
        require(sha(root / "fixtures" / name) == info["fixtures"][name], "Fixture hash")
    require(set(info["fixtures"]) == set(NAMES), "Fixture set")
    require(
        set(info["generators"]) == {"measure.py", "benchmark.zig.inc"}, "Generator set"
    )
    for name, digest in info["generators"].items():
        require(sha(root / name) == digest, "Saved generator hash")
    for variant in ("baseline", "reuse"):
        binary = root / variant / "zig-out/bin/test"
        require(
            not binary.is_symlink()
            and str(binary) == info["binaries"][variant]["path"],
            "Executable owner",
        )
        require(sha(binary) == info["binaries"][variant]["sha256"], "Executable hash")
        inventory = info[variant + "_sha256"]
        require(set(inventory) == set(original), "Source inventory")
        for name, digest in inventory.items():
            require(name == "build.zig" or name.startswith("src/"), "Source path")
            require(
                ".." not in Path(name).parts and not Path(name).is_absolute(),
                "Source traversal",
            )
            require(sha(root / variant / name) == digest, "Instrumented source hash")
        allowed = {
            "build.zig",
            "src/platform/macos/app_session/editor/mod.zig",
            "src/platform/macos/app_session/editor/syntax.zig",
        }
        require(
            {name for name in inventory if inventory[name] != original[name]}
            <= allowed,
            "Unexpected product mutation",
        )
    expected = []
    by_key = {}
    for row in rows:
        require(
            type(row.get("rep")) is int
            and type(row.get("shared")) is int
            and type(row.get("structure")) is int,
            "Case scalar types",
        )
        require(
            isinstance(row.get("samples"), list)
            and all(
                isinstance(sample, dict)
                and set(sample) == FIELDS
                and all(type(value) is int for value in sample.values())
                for sample in row["samples"]
            ),
            "Saved sample types",
        )
        key = f"{row['phase']}-{row['rep']}-{row['file']}-{row['shared']}-{row['structure']}-{row['variant']}"
        require(key not in by_key, "Duplicate case")
        by_key[key] = row
    for phase, repeats in (("run", repetitions), ("verify", 1)):
        for rep in range(repeats):
            for fi, name in enumerate(NAMES):
                for shared in (0, 1):
                    for structure in (0, 1):
                        variants = (
                            ("baseline", "reuse")
                            if (rep + fi + shared + structure) % 2 == 0
                            else ("reuse", "baseline")
                        )
                        for variant in variants:
                            expected.append(
                                f"{phase}-{rep}-{name}-{shared}-{structure}-{variant}"
                            )
    require(
        len(rows) == len(expected) and set(by_key) == set(expected),
        "Case matrix coverage",
    )
    execution = info["execution"]
    require([e.get("key") for e in execution] == expected, "Actual execution order")
    for entry in execution:
        require(
            type(entry.get("exit_code")) is int and entry["exit_code"] == 0,
            "Failed child",
        )
        key = entry["key"]
        row = by_key[key]
        path = root / (key + ".log")
        require(sha(path) == entry["log_sha256"], "Raw log hash")
        parsed = samples(
            path.read_text(),
            row["shared"],
            row["structure"],
            row["variant"],
            row["phase"] == "verify",
        )
        require(parsed == row["samples"], "Saved rows differ from actual raw log")
    counts = Counter(
        (r["phase"], r["file"], r["shared"], r["structure"], r["variant"]) for r in rows
    )
    require(
        all(v == (repetitions if k[0] == "run" else 1) for k, v in counts.items()),
        "Cell repetition coverage",
    )
    summary = []
    for name in NAMES:
        for shared in (0, 1):
            for structure in (0, 1):
                for variant in ("baseline", "reuse"):
                    values = [
                        s
                        for r in rows
                        if (
                            r["phase"],
                            r["file"],
                            r["shared"],
                            r["structure"],
                            r["variant"],
                        )
                        == ("run", name, shared, structure, variant)
                        for s in r["samples"]
                    ]
                    item = dict(
                        file=name,
                        shared=shared,
                        structure=structure,
                        variant=variant,
                        n=len(values),
                    )
                    for field in ("edit_ns", "frame_ns", "total_ns"):
                        numbers = sorted(s[field] / 1e6 for s in values)
                        item[field.replace("_ns", "_ms")] = dict(
                            p50=statistics.median(numbers),
                            p95=numbers[(95 * len(numbers) + 99) // 100 - 1],
                            maximum=max(numbers),
                        )
                    summary.append(item)
    require(summary == json.loads((root / "summary.json").read_text()), "Saved summary")
    return dict(
        processes=len(rows),
        performance_edits=40 * repetitions * 20,
        verified_edits=40 * 20,
        verified_views=60 * 20,
        summary=summary,
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.output.resolve()), indent=2))


if __name__ == "__main__":
    main()
