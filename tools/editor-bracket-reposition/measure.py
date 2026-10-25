#!/usr/bin/env python3
"""같은 제품 사본의 재사용 경로 유무를 순서 교대하며 비교한다. 원시 자료는 덮어쓰지 않는다."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[2]
HOST = "src/platform/macos/app_session/editor/mod.zig"
SYNTAX = "src/platform/macos/app_session/editor/syntax.zig"
NAMES = (
    "flat-3000.zig",
    "flat-15000.zig",
    "flat-50000.zig",
    "real-build.zig",
    "real-host.swift",
)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--deps", type=Path, required=True)
    parser.add_argument("--repetitions", type=int, default=3)
    args = parser.parse_args()
    out = args.output.expanduser().resolve()
    if out.exists() or out.is_relative_to(ROOT) or args.repetitions < 1:
        parser.error("Use a new external output and positive repetitions")
    out.mkdir(parents=True)
    fixtures = out / "fixtures"
    fixtures.mkdir()
    for name in NAMES:
        shutil.copyfile(args.fixtures / name, fixtures / name)
    original = {
        str(p.relative_to(ROOT)): sha(p)
        for p in (ROOT / "src").rglob("*")
        if p.is_file()
    }
    original["build.zig"] = sha(ROOT / "build.zig")
    receipt = dict(
        schema=1,
        target="bracket-reposition-comparison",
        workload_model="exact-prefix-and-canonical-delimiter-growth",
        repetitions=args.repetitions,
        source_head=subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
        ).strip(),
        original_sha256=original,
        fixtures={n: sha(fixtures / n) for n in NAMES},
        generators={
            p.name: sha(p)
            for p in (Path(__file__), Path(__file__).with_name("benchmark.zig.inc"))
        },
        binaries={},
        execution=[],
    )
    for name in receipt["generators"]:
        shutil.copyfile(Path(__file__).with_name(name), out / name)
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    binaries = {}
    for variant in ("baseline", "reuse"):
        source = out / variant
        subprocess.run(
            [
                "rsync",
                "-a",
                "--exclude=.git",
                "--exclude=.zig-cache",
                "--exclude=zig-out",
                "--exclude=zig-pkg",
                "--exclude=node_modules",
                "--exclude=references",
                "--exclude=.env*",
                "--exclude=.codex-worktrees",
                str(ROOT) + "/",
                str(source) + "/",
            ],
            check=True,
        )
        (source / "zig-pkg").symlink_to(args.deps.resolve(), target_is_directory=True)
        syntax = source / SYNTAX
        text = syntax.read_text()
        if variant == "baseline":
            begin = text.index(
                "        // 판정은 중립이 맡고, native 목록은 값으로 전달한다."
            )
            end = text.index("\n    }\n    self.bracket_resolved = null;", begin)
            text = text[:begin] + text[end:]
        syntax.write_text(text)
        host = source / HOST
        bench = (
            Path(__file__)
            .with_name("benchmark.zig.inc")
            .read_text()
            .replace("BRACKET_EXPECT_RESOLVES", "1" if variant == "baseline" else "0")
        )
        host.write_text(host.read_text() + "\n" + bench)
        build = source / "build.zig"
        text = build.read_text()
        anchor = "    const edit_cost_tests = addProjectTest"
        index = text.index(anchor)
        text = (
            text[:index]
            + """    const bracket_bench = addProjectTest(b, .{ .root_module = editor_tests.root_module, .filters = &.{"bracket coordinate benchmark"} });
    const install_bracket_bench = b.addInstallArtifact(bracket_bench, .{});
    b.step("build-editor-bracket-benchmark", "Build isolated bracket benchmark").dependOn(&install_bracket_bench.step);
"""
            + text[index:]
        )
        build.write_text(text)
        inst = {
            str(p.relative_to(source)): sha(p)
            for p in (source / "src").rglob("*")
            if p.is_file()
        }
        inst["build.zig"] = sha(build)
        receipt[variant + "_sha256"] = inst
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        result = subprocess.run(
            [
                "mise",
                "exec",
                "--",
                "zig",
                "build",
                "build-editor-bracket-benchmark",
                "-Doptimize=ReleaseFast",
                "-j2",
            ],
            cwd=source,
            capture_output=True,
            text=True,
            timeout=900,
        )
        (out / (variant + "-build.log")).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(result.stderr[-6000:])
        binary = source / "zig-out/bin/test"
        if not binary.is_file():
            raise RuntimeError("Missing installed benchmark")
        binaries[variant] = binary
        receipt["binaries"][variant] = dict(path=str(binary), sha256=sha(binary))
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    rows = []
    for phase, repeats in (("run", args.repetitions), ("verify", 1)):
        for rep in range(repeats):
            for fi, name in enumerate(NAMES):
                for shared in (0, 1):
                    for structure in (0, 1):
                        order = (
                            ("baseline", "reuse")
                            if (rep + fi + shared + structure) % 2 == 0
                            else ("reuse", "baseline")
                        )
                        for variant in order:
                            binary = binaries[variant]
                            if sha(fixtures / name) != receipt["fixtures"][name]:
                                raise ValueError("Fixture changed")
                            if sha(binary) != receipt["binaries"][variant]["sha256"]:
                                raise ValueError("Binary changed")
                            env = dict(
                                os.environ,
                                MARU_BRACKET_FILE=str(fixtures / name),
                                MARU_BRACKET_SHARED=str(shared),
                                MARU_BRACKET_STRUCTURE=str(structure),
                                MARU_BRACKET_VERIFY=str(int(phase == "verify")),
                            )
                            result = subprocess.run(
                                [
                                    str(binary),
                                    "--maru-expect-tests=5",
                                    "--maru-expect-passed=5",
                                ],
                                cwd=out / variant,
                                env=env,
                                capture_output=True,
                                text=True,
                                timeout=300,
                            )
                            log = result.stdout + result.stderr
                            key = f"{phase}-{rep}-{name}-{shared}-{structure}-{variant}"
                            (out / (key + ".log")).write_text(log)
                            samples = []
                            for line in log.splitlines():
                                if line.startswith("BRACKET "):
                                    fields = dict(
                                        (k, int(v))
                                        for k, v in re.findall(r"(\w+)=(-?\d+)", line)
                                    )
                                    samples.append(fields)
                            if result.returncode or [
                                s.get("key") for s in samples
                            ] != list(range(20)):
                                raise RuntimeError(key + "\n" + log[-4000:])
                            for sample in samples:
                                if (
                                    sample["views"] != shared + 1
                                    or sample["oracle"] != int(phase == "verify")
                                    or min(sample["edit_ns"], sample["frame_ns"]) < 0
                                    or not 1 <= sample.get("rounds", 0) <= 128
                                    or sample["total_ns"]
                                    != sample["edit_ns"] + sample["frame_ns"]
                                ):
                                    raise ValueError("Invalid sample: " + key)
                            expected = (
                                shared + 1
                                if structure
                                else (shared + 1) * int(variant == "baseline")
                            )
                            for sample in samples:
                                if (
                                    sample["resolves"] != expected
                                    or sample["tokens_before"] <= 0
                                    or sample["tokens_after"]
                                    != sample["tokens_before"] + structure
                                ):
                                    raise ValueError(
                                        "Wrong actual canonical work: " + key
                                    )

                            rows.append(
                                dict(
                                    phase=phase,
                                    rep=rep,
                                    file=name,
                                    shared=shared,
                                    structure=structure,
                                    variant=variant,
                                    samples=samples,
                                )
                            )
                            receipt["execution"].append(
                                dict(
                                    key=key,
                                    exit_code=result.returncode,
                                    log_sha256=sha(out / (key + ".log")),
                                )
                            )
                            (out / "receipt.json").write_text(
                                json.dumps(receipt, indent=2) + "\n"
                            )
                            (out / "samples.json").write_text(
                                json.dumps(rows, indent=2) + "\n"
                            )
                            print(key, "passed", flush=True)
    summary = []
    for name in NAMES:
        for shared in (0, 1):
            for structure in (0, 1):
                for variant in ("baseline", "reuse"):
                    values = [
                        s
                        for row in rows
                        if row["phase"] == "run"
                        and (
                            row["file"],
                            row["shared"],
                            row["structure"],
                            row["variant"],
                        )
                        == (name, shared, structure, variant)
                        for s in row["samples"]
                    ]
                    entry = dict(
                        file=name,
                        shared=shared,
                        structure=structure,
                        variant=variant,
                        n=len(values),
                    )
                    for field in ("edit_ns", "frame_ns", "total_ns"):
                        nums = sorted(s[field] / 1e6 for s in values)
                        entry[field.replace("_ns", "_ms")] = dict(
                            p50=statistics.median(nums),
                            p95=nums[(len(nums) * 95 + 99) // 100 - 1],
                            maximum=max(nums),
                        )
                    summary.append(entry)
    if {name: sha(ROOT / name) for name in original} != original:
        raise ValueError("Original source changed during measurement")
    for variant in ("baseline", "reuse"):
        if {
            name: sha(out / variant / name) for name in receipt[variant + "_sha256"]
        } != receipt[variant + "_sha256"]:
            raise ValueError("Instrumented source changed")
    for name, digest in receipt["generators"].items():
        if sha(out / name) != digest or sha(Path(__file__).with_name(name)) != digest:
            raise ValueError("Generator changed")
    receipt["original_unchanged"] = True
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(out / "summary.json", flush=True)


if __name__ == "__main__":
    main()
