#!/usr/bin/env python3
"""기존 전체 대조와 구문 내부의 호출 범위·중첩 시간·생성 근거를 검증한다."""
import argparse
import importlib.util, json, pathlib, re, statistics, math

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "inner_runner", pathlib.Path(__file__).with_name("run.py")
)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
spec = importlib.util.spec_from_file_location(
    "lower_summary", ROOT / "tools/editor-lowering-measure/summarize.py"
)
lower = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lower)
lower.runner.EXTRA.update(runner.EXTRA)
STAGES = runner.STAGES
FIELDS = (
    ("key",)
    + tuple(x for name in STAGES for x in (name, name + "_calls"))
    + ("semanticWork", "bracketWork")
)
PATTERN = re.compile("INNER " + " ".join(x + r"=(\d+)" for x in FIELDS))


def rows(text, workload, info):
    runner.check_contract(info)
    records = []
    parents = []
    for line in text.splitlines():
        if line.startswith("INNER "):
            m = PATTERN.fullmatch(line)
            if not m:
                raise ValueError("Malformed inner row")
            records.append(dict(zip(FIELDS, map(int, m.groups()))))
        if line.startswith("LOWERING "):
            parents.append(
                dict((k, int(v)) for k, v in re.findall(r"(\w+)=(\d+)", line))
            )
    if len(parents) != 20 or [r["key"] for r in records] != list(range(20)):
        raise ValueError("Inner sample count/order")
    views = 2 if workload == "shared" else 1
    for row, parent in zip(records, parents):
        if row["key"] != parent["key"]:
            raise ValueError("Inner parent key")
        if any(row[name + "_calls"] != views for name in STAGES):
            raise ValueError("Inner scope calls")
        if row["semanticWork"] != 0 or row["bracketWork"] != views:
            raise ValueError("Inner layer branch condition")
        if sum(row[name] for name in STAGES[:3]) > parent["advanceSyntax"]:
            raise ValueError("Advance child overlap")
        if row["lineColorsInto"] > parent["syntaxColors"]:
            raise ValueError("Body colors exceeds parent")
        if sum(row[name] for name in STAGES[4:]) > row["lineColorsInto"]:
            raise ValueError("Body color child overlap")
    return records


def summarize(root, repetitions=3):
    root = root.resolve()
    info = lower.pane.provider.load(root / "setup-1.json")
    runner.check_contract(info)
    lower.pane.provider.digest(
        root / "inner-generator.py", info["inner_generator_sha256"]
    )
    base = lower.summarize(root, repetitions)
    inputs = lower.pane.provider.load(root / "inputs.json")
    groups = {}
    for prefix, count in [("run", repetitions), ("verify", 1)]:
        for filename in sorted(inputs):
            for work in ("typing", "shared"):
                for rep in range(count):
                    records = rows(
                        (root / f"{prefix}-{rep}-1-{filename}-{work}.log").read_text(),
                        work,
                        info,
                    )
                    if prefix == "run":
                        groups.setdefault(filename + "/" + work, []).extend(records)

    def stats(values):
        ordered = sorted(values)
        return {
            "n": len(values),
            "p50_ms": statistics.median(values) / 1e6,
            "p95_ms": ordered[math.ceil(len(values) * 0.95) - 1] / 1e6,
            "max_ms": max(values) / 1e6,
        }

    return {
        "parent": base,
        "inner": {
            key: {name: stats([row[name] for row in records]) for name in STAGES}
            for key, records in groups.items()
        },
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=pathlib.Path)
    parser.add_argument("--repetitions", type=int, default=3)
    args = parser.parse_args()
    result = summarize(args.root, args.repetitions)
    (args.root / "inner-summary.json").write_text(json.dumps(result, indent=2) + "\n")
    for key, group in result["inner"].items():
        print(
            key,
            " ".join(
                name + "=" + str(round(value["p50_ms"], 3))
                for name, value in group.items()
            ),
        )


if __name__ == "__main__":
    main()
