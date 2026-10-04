#!/usr/bin/env python3
"""후보 선별·byte 탐색 실험이 기존 찾기의 파일별 모든 범위를 보존하는지 대조한다."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import subprocess

from compare import candidate_command


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--rg", default=shutil.which("rg"))
    args = parser.parse_args()
    if not args.rg:
        parser.error("실행 가능한 rg가 필요합니다")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    home = output / "home"
    home.mkdir()
    environment = {**os.environ, "HOME": str(home), "XDG_CONFIG_HOME": str(home), "LC_ALL": "C"}
    environment.pop("RIPGREP_CONFIG_PATH", None)
    native = args.native.resolve(strict=True)
    binary = Path(args.rg).resolve(strict=True)
    base = [str(binary), "--no-config", "--hidden", "--no-require-git",
            "--no-ignore-parent", "--no-ignore-global"]
    valid = output / "valid"
    valid.mkdir()
    contents = {
        "boundary.txt": "foo foobar foo😀bar foo$bar foo_bar 한foo글 foo-foo\n",
        "case.txt": "needle NEEDLE NeeDle foo FOO I İ ı i k K K s S ſ\n",
        "overlap.txt": "aaaaa foofoo aaa abababa\n",
        "only-substring.txt": "xneedlex\n",
        "anchors.txt": "foo\n\nfoo\r\nneedle\r\n",
        "normalization.txt": "한글 한 한글 é é 가 가\n",
        "--name\nwith space.txt": "-- .* $ _ needle\n",
        ".hidden.txt": "needle\n",
        "empty.txt": "",
    }
    randomizer = random.Random(4134)
    alphabet = ["foo", "needle", "NEEDLE", "aaa", "😀", "한글", "é", "$", "_", " ", "\n"]
    for index in range(16):
        contents[f"random-{index}.txt"] = "".join(randomizer.choice(alphabet) for _ in range(128))
    for name, body in contents.items():
        (valid / name).write_bytes(body.encode())
    raw = output / "raw"
    raw.mkdir()
    (raw / "binary.bin").write_bytes(b"\x00needle\n")
    (raw / "bom.bin").write_bytes(b"\xff\xfeneedle\n")
    (raw / "malformed.txt").write_bytes(b"\xe0needle \xf0foo needle\n")
    cases = [
        (valid, query, mode) for query, mode in [
            ("needle", "literal"), ("NEEDLE", "literal-fold"), ("needle", "word"),
            ("foo", "word"), ("FOO", "literal-fold"), ("I", "literal-fold"),
            ("k", "literal-fold"), ("s", "literal-fold"), ("aa", "literal"),
            ("--", "literal"), (".*", "literal"), ("$", "word"), ("_", "word"),
            ("absent-pattern", "literal"), ("한글", "literal"), ("é", "literal"),
            ("é", "literal"), ("^|foo", "regex"), ("(?<=foo)bar", "regex"),
            (r"(foo)\1", "regex"), ("(?=한)|$", "regex"),
        ]
    ] + [(raw, "needle", "literal"), (raw, "NEEDLE", "literal-fold"), (raw, "foo", "literal")]
    report = {
        "status": "running", "cases": [],
        "native_sha256": hashlib.sha256(native.read_bytes()).hexdigest(),
        "rg_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "source_sha256": {name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
                          for name in ("native.zig", "compare.py", "verify.py")},
        "limits": "합성 자료의 모든 범위 대조. raw 자료는 선별 누락 탐지용이며 제품의 바이너리·인코딩 지원을 뜻하지 않음.",
    }

    def run(command, cwd, name):
        result = subprocess.run(command, cwd=cwd, env=environment, capture_output=True, timeout=20)
        (output / f"{name}.stdout").write_bytes(result.stdout)
        (output / f"{name}.stderr").write_bytes(result.stderr)
        return result

    def paths_for(corpus, query, mode, prefilter, name):
        command, used = candidate_command(base, query, mode, prefilter)
        result = run(command, corpus, name)
        assert result.returncode in (0, 1), (name, result.stderr)
        names = sorted(path for path in result.stdout.split(b"\0") if path)
        assert len(names) == len(set(names)), name
        return names, used

    def ranges_for(corpus, names, query, mode, name):
        paths = output / f"{name}.paths"
        paths.write_bytes(b"".join(os.fsencode(corpus) + b"/" + path + b"\0" for path in names))
        result = run([str(native), str(paths), query, mode, "--ranges"], corpus, name)
        assert result.returncode == 0, (name, result.stderr)
        records = [json.loads(line) for line in result.stdout.splitlines()]
        summary = records.pop()
        assert summary["files"] == len(names) == len(records), name
        assert summary["matches"] == sum(len(record["ranges"]) for record in records), name
        assert summary["optimize"] == "ReleaseFast", name
        assert [record["file_index"] for record in records] == list(range(len(names))), name
        return {os.fsdecode(names[index]): record["ranges"] for index, record in enumerate(records) if record["ranges"]}

    try:
        for index, (corpus, query, mode) in enumerate(cases):
            name = f"case-{index}"
            all_paths, _ = paths_for(corpus, query, mode, False, name + "-all")
            candidates, used = paths_for(corpus, query, mode, True, name + "-candidates")
            expected = ranges_for(corpus, all_paths, query, mode, name + "-native")
            filtered = ranges_for(corpus, candidates, query, mode, name + "-filtered")
            row = {"corpus": corpus.name, "query": query, "mode": mode,
                   "files": len(all_paths), "candidates": len(candidates), "prefilter_used": used,
                   "matches": sum(map(len, expected.values())), "prefilter_equal": expected == filtered,
                   "missing_files": sorted(expected.keys() - filtered.keys())}
            if mode == "literal":
                byte_ranges = ranges_for(corpus, all_paths, query, "byte-candidate", name + "-byte")
                row["byte_equal"] = expected == byte_ranges
            report["cases"].append(row)
        for query, mode in [("", "literal"), ("a\nb", "literal"), ("a\rb", "literal"),
                            ("a\0b", "literal"), ("한글", "literal"), ("foo", "regex")]:
            _, used = candidate_command(base, query, mode, True)
            assert not used, (query, mode, "선별하면 안 되는 검색어")
        failures = [row for row in report["cases"] if not row["prefilter_equal"] or not row.get("byte_equal", True)]
        assert not failures, failures
        report["status"] = "passed"
    except BaseException as error:
        report["status"] = "failed"
        report["error"] = repr(error)
        raise
    finally:
        (output / "verification.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(output / "verification.json")


if __name__ == "__main__":
    main()
