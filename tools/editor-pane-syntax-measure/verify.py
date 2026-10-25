#!/usr/bin/env python3
"""실제 구문 내부 계측 자료에 독립 실패 가설을 적용하고 원본을 보존한다."""
import argparse
import importlib.util
import pathlib
import tempfile
import json
import re
import hashlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("inner", HERE / "summarize.py")
inner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inner)
spec = importlib.util.spec_from_file_location(
    "review", inner.ROOT / "tools/editor-pane-measure/verify.py"
)
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)
review.parent.summary = inner.lower.pane.provider


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=pathlib.Path)
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--receipt", type=pathlib.Path, required=True)
    args = parser.parse_args()
    original = args.root.resolve()
    before = inner.summarize(original, args.repetitions)
    rejected = []
    groups = []
    with tempfile.TemporaryDirectory(prefix="maru-inner-review-") as td:
        root = (pathlib.Path(td) / "fixture").resolve()
        review.parent.fixture(original, root)
        extra = "src/chrome/components/editor_view/syntax_colors.zig"
        (root / "inner-generator.py").write_bytes(
            (original / "inner-generator.py").read_bytes()
        )
        for prefix in ["run", "verify"]:
            (root / f"{prefix}-order.stdout").write_bytes(
                (original / f"{prefix}-order.stdout").read_bytes()
            )
            rows = json.loads((original / f"{prefix}-order.json").read_text())
            for row in rows:
                row["log"] = str(root / pathlib.Path(row["log"]).name)
            (root / f"{prefix}-order.json").write_text(json.dumps(rows))

        def positive():
            if inner.summarize(root, args.repetitions) != before:
                raise RuntimeError("Positive control changed")

        def bad(label, path, text):
            with review.parent.changed(path, text.encode()):
                try:
                    inner.summarize(root, args.repetitions)
                except (ValueError, FileNotFoundError):
                    rejected.append(label)
                else:
                    raise RuntimeError("Accepted corruption: " + label)

        def field(text, name, value):
            return re.sub(
                r"\b" + name + r"=\d+", name + "=" + str(value), text, count=1
            )

        log = root / "run-0-1-flat-3000.zig-shared.log"
        raw = log.read_text()
        first, second = [l for l in raw.splitlines() if l.startswith("INNER ")][:2]
        positive()
        start = len(rejected)
        bad("missing-first", log, raw.replace(first + "\n", "", 1))
        bad("duplicate-key", log, raw.replace(first, first + "\n" + first, 1))
        bad("unknown-field", log, raw.replace(first, first + " other=1", 1))
        lines = raw.splitlines()
        a, b = lines.index(first), lines.index(second)
        lines[a], lines[b] = lines[b], lines[a]
        bad("reordered-input", log, "\n".join(lines) + "\n")
        positive()
        groups.append(
            {"hypothesis": "samples and ordering", "rejected": len(rejected) - start}
        )
        start = len(rejected)
        for name in inner.STAGES:
            bad(
                "wrong-calls-" + name,
                log,
                raw.replace(first, field(first, name + "_calls", 0), 1),
            )
        bad(
            "unexpected-semantic-work",
            log,
            raw.replace(first, field(first, "semanticWork", 1), 1),
        )
        bad(
            "missing-bracket-work",
            log,
            raw.replace(first, field(first, "bracketWork", 0), 1),
        )
        positive()
        groups.append(
            {
                "hypothesis": "pane and body scopes plus actual layer predicates",
                "rejected": len(rejected) - start,
            }
        )
        start = len(rejected)
        bad(
            "negative-query-time",
            log,
            raw.replace(first, field(first, "captureQuery", -1), 1),
        )
        parent_line = next(
            l for l in raw.splitlines() if l.startswith("LOWERING key=0 ")
        )
        parent = dict((k, int(v)) for k, v in re.findall(r"(\w+)=(\d+)", parent_line))
        line_row = dict((k, int(v)) for k, v in re.findall(r"(\w+)=(\d+)", first))
        for label, left, right, limit in [
            (
                "advance-sum-overlap",
                "advanceBrackets",
                "promoteFolds",
                parent["advanceSyntax"],
            ),
            (
                "color-sum-overlap",
                "captureQuery",
                "neutralColor",
                line_row["lineColorsInto"],
            ),
        ]:
            overlap = field(field(first, left, limit // 2 + 1), right, limit // 2 + 1)
            bad(label, log, raw.replace(first, overlap, 1))

        for name in ["resumeParse", "lineColorsInto", "neutralColor"]:
            bad(
                "exceeds-parent-" + name,
                log,
                raw.replace(first, field(first, name, 999999999999), 1),
            )
        positive()
        groups.append(
            {
                "hypothesis": "nested times and disjoint sums",
                "rejected": len(rejected) - start,
            }
        )
        start = len(rejected)
        setup = root / "setup-1.json"
        for name, key, value in [
            ("unknown-schema", "inner_schema", 2),
            ("boolean-schema", "inner_schema", True),
            ("missing-stage", "inner_stages", list(inner.STAGES[:-1])),
            ("wrong-scope", "inner_scope", "all calls"),
            ("wrong-generator", "inner_generator_sha256", "0" * 64),
            ("wrong-target", "inner_target", "other"),
        ]:
            info = json.loads(setup.read_text())
            info[key] = value
            bad(name, setup, json.dumps(info))
        positive()
        groups.append(
            {
                "hypothesis": "schema stage model and generator",
                "rejected": len(rejected) - start,
            }
        )
        start = len(rejected)
        verify = root / "verify-0-1-flat-3000.zig-shared.log"
        bad(
            "missing-full-oracle",
            verify,
            verify.read_text().replace("PANE_ORACLE key=0 views=2 full=1\n", "", 1),
        )
        bad("product-mismatch", log, raw.replace("mismatch=0", "mismatch=1", 1))
        for rel in ["src/platform/macos/app_session/editor/syntax.zig", extra]:
            p = root / "source-1" / rel
            bad("changed-source-" + pathlib.Path(rel).name, p, p.read_text() + "\n")
        info = json.loads((root / "binaries.json").read_text())
        info["1"]["sha256"] = "0" * 64
        bad("changed-binary", root / "binaries.json", json.dumps(info))
        bad(
            "changed-generator",
            root / "inner-generator.py",
            (root / "inner-generator.py").read_text() + "\n",
        )
        # 다른 실행 모델·기존 표본 덮어쓰기·손상된 생성 근거를 CLI로 우회할 수 없다.
        prepared = [
            "--output",
            str(root),
            "--deps",
            str(original / "source-1/zig-pkg"),
            "--resume",
            "--run-only",
            "--repetitions",
            "0",
        ]
        for flags in (
            ["--baseline"],
            ["--baseline-ref=HEAD"],
            ["--modes=0"],
            ["--workloads=paste"],
            ["--workloads=shared,shared"],
            ["--prefix=verify"],
            ["--repetitions=1"],
            ["--refresh"],
        ):
            result = subprocess.run(
                [sys.executable, str(HERE / "run.py"), *prepared, *flags],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            if result.returncode != 2 or "error:" not in result.stderr:
                raise RuntimeError("Invalid CLI accepted: " + str(flags))
            rejected.append("cli-" + ",".join(flags))
        info = json.loads(setup.read_text())
        info["inner_target"] = "other"
        with review.parent.changed(setup, json.dumps(info).encode()):
            result = subprocess.run(
                [sys.executable, str(HERE / "run.py"), *prepared],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            if (
                result.returncode != 2
                or "Unknown pane syntax schema/target" not in result.stderr
            ):
                raise RuntimeError("CLI accepted another measurement model")
        rejected.append("cli-wrong-measurement-model")
        result = subprocess.run(
            [sys.executable, str(HERE / "run.py"), *prepared],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if result.returncode:
            raise RuntimeError("Valid zero-run CLI rejected")
        positive()
        groups.append(
            {
                "hypothesis": "independent product oracle original sources and binary",
                "rejected": len(rejected) - start,
            }
        )
    if inner.summarize(original, args.repetitions) != before:
        raise RuntimeError("Original evidence changed")
    receipt = {
        "independent_hypotheses": 5,
        "groups": groups,
        "rejected": rejected,
        "tool_sha256": {
            p.name: hashlib.sha256(p.read_bytes()).hexdigest()
            for p in [HERE / "run.py", HERE / "summarize.py", HERE / "verify.py"]
        },
        "positive_controls": "before and after every group; unchanged actual artifacts",
    }
    args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
