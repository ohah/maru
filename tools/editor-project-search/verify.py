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
    parser.add_argument("--baseline-native", type=Path, help="수정 전 바이너리와 모든 범위를 대조")
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
    baseline = args.baseline_native.resolve(strict=True) if args.baseline_native else None
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
        "bom.txt": "\ufeffneedle\r\n",
        "bom-only.txt": "\ufeff",
        "double-cr.txt": "needle\r\r\n",
        "lone-cr.txt": "needle\r",
        "nul.txt": "\0needle\n",
        "unicode-case.txt": "é É Ÿ ÿ Σ σ А а K K ſ S İ I\n",
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
            ("é", "literal-fold"), ("Ÿ", "literal-fold"), ("Σ", "literal-fold"), ("А", "literal-fold"),
            (r"(foo)\1", "regex"), ("(?=한)|$", "regex"),
        ]
    ] + [(raw, "needle", "literal"), (raw, "NEEDLE", "literal-fold"), (raw, "foo", "literal")]
    report = {
        "status": "running", "cases": [], "document_oracles": [],
        "native_sha256": hashlib.sha256(native.read_bytes()).hexdigest(),
        "rg_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "source_sha256": {name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
                          for name in ("native.zig", "compare.py", "verify.py")},
        "limits": "합성 자료의 모든 범위 대조. raw 자료는 선별 누락 탐지용이며 제품의 바이너리·인코딩 지원을 뜻하지 않음.",
    }
    if baseline:
        report["baseline_native_sha256"] = hashlib.sha256(baseline.read_bytes()).hexdigest()
    repository = Path(__file__).resolve().parents[2]
    report["product_source_sha256"] = {
        path: hashlib.sha256((repository / path).read_bytes()).hexdigest()
        for path in ("src/session/editor/find.zig", "src/session/editor/document.zig",
                     "src/session/editor/line_index.zig", "src/terminal/selection.zig")
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

    def ranges_for(corpus, names, query, mode, name, matcher=native):
        paths = output / f"{name}.paths"
        paths.write_bytes(b"".join(os.fsencode(corpus) + b"/" + path + b"\0" for path in names))
        raw_options = ["--raw-bytes"] if corpus == raw else []
        result = run([str(matcher), str(paths), query, mode, "--ranges"] + raw_options, corpus, name)
        assert result.returncode == 0, (name, result.stderr)
        records = [json.loads(line) for line in result.stdout.splitlines()]
        summary = records.pop()
        assert summary["files"] == len(names) == len(records), name
        assert summary["matches"] == sum(len(record["ranges"]) for record in records), name
        assert summary["optimize"] == "ReleaseFast", name
        assert [record["file_index"] for record in records] == list(range(len(names))), name
        return {os.fsdecode(names[index]): record["ranges"] for index, record in enumerate(records) if record["ranges"]}

    try:
        # 비교 양쪽이 같은 오류를 가져도 실패하도록 제품 계약의 기대 범위를 별도로 고정한다.
        for index, (filename, query, mode, spans) in enumerate([
            ("bom.txt", "needle", "literal", [[0, 0, 6]]),
            ("bom.txt", "^needle$", "regex", [[0, 0, 6]]),
            ("bom-only.txt", "^$", "regex", [[0, 0, 0]]),
            ("double-cr.txt", "^needle$", "regex", []),
            ("lone-cr.txt", "^needle$", "regex", []),
            ("lone-cr.txt", r"\r$", "regex", [[0, 6, 1]]),
            ("nul.txt", "needle", "literal", [[0, 1, 6]]),
        ]):
            path = "./" + filename
            observed = ranges_for(valid, [path.encode()], query, mode, f"document-{index}")
            expected = {path: spans} if spans else {}
            report["document_oracles"].append({"file": filename, "query": query, "expected": expected, "observed": observed})
            assert observed == expected, ("제품 문서 계약", filename, observed, expected)
        invalid_paths = output / "invalid-document.paths"
        invalid_paths.write_bytes(os.fsencode(raw / "malformed.txt") + b"\0")
        rejected = run([str(native), str(invalid_paths), "needle", "literal"], raw, "invalid-document")
        report["invalid_document_rejected"] = rejected.returncode != 0 and b"NotUtf8" in rejected.stderr
        assert report["invalid_document_rejected"], "제품 경로는 잘못된 UTF-8을 거부해야 함"
        invalid_query = run([str(native), str(invalid_paths), b"\xf0", "literal", "--raw-bytes"], raw, "invalid-query")
        assert invalid_query.returncode == 0, invalid_query.stderr
        report["invalid_query_matches"] = json.loads(invalid_query.stdout)["matches"]
        assert report["invalid_query_matches"] == 0, "깨진 검색어는 매치 0이어야 함"
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
            if baseline:
                original = ranges_for(corpus, all_paths, query, mode, name + "-baseline", baseline)
                row["baseline_equal"] = expected == original
            if mode == "literal":
                byte_ranges = ranges_for(corpus, all_paths, query, "byte-candidate", name + "-byte")
                row["byte_equal"] = expected == byte_ranges
            report["cases"].append(row)
        for query, mode in [("", "literal"), ("a\nb", "literal"), ("a\rb", "literal"),
                            ("a\0b", "literal"), ("한글", "literal"), ("foo", "regex")]:
            _, used = candidate_command(base, query, mode, True)
            assert not used, (query, mode, "선별하면 안 되는 검색어")
        failures = [row for row in report["cases"] if not row["prefilter_equal"] or not row.get("byte_equal", True) or not row.get("baseline_equal", True)]
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
