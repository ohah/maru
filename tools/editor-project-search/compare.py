#!/usr/bin/env python3
"""같은 합성 파일에서 전체 검색·공통 matcher·후보 선별의 비용과 결과를 비교한다."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import selectors
import shutil
import statistics
import subprocess
import sys
import time


def candidate_command(base, query, mode, prefilter):
    """확실한 상위 집합을 만들 수 있는 검색어만 내용 선별을 시도한다."""
    eligible = mode in ("literal", "literal-fold", "word") and bool(query) and query.isascii() and not any(c in query for c in "\r\n\0")
    if prefilter and eligible:
        flags = ["--ignore-case"] if mode == "literal-fold" else ["--case-sensitive"]
        # 바이너리 감지·BOM 변환은 원본 byte의 일치를 지울 수 있다. 최종 파일 정책은 별도다.
        return base + ["--files-with-matches", "--null", "--fixed-strings", "--text", "--encoding", "none"] + flags + ["--regexp", query, "--", "."], True
    return base + ["--files", "--null", "--", "."], False


def execute(command, cwd, environment, artifact, kind):
    """두 pipe를 함께 비우고 직접 wait4하여 해당 자식의 RSS와 수거를 측정한다."""
    start = time.perf_counter()
    child = subprocess.Popen(command, cwd=cwd, env=environment,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    chunks = {"stdout": bytearray(), "stderr": bytearray()}
    pending = bytearray()
    first_ms = None
    usage = None
    elapsed_ms = None
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ, "stdout")
            selector.register(child.stderr, selectors.EVENT_READ, "stderr")
            while selector.get_map() or usage is None:
                if time.perf_counter() - start > 30:
                    raise TimeoutError("비교 자식이 30초 안에 끝나지 않았습니다")
                # pipe를 이미 다 읽은 뒤의 수거 폴링이 짧은 검색에 20 ms를 더하지 않게 한다.
                for key, _ in selector.select(timeout=0.02 if selector.get_map() else 0.001):
                    data = os.read(key.fd, 65536)
                    if not data:
                        selector.unregister(key.fileobj)
                        continue
                    chunks[key.data].extend(data)
                    # 대량 매치 실험도 무한 출력으로 호스트를 소진시키지 않는다.
                    if sum(map(len, chunks.values())) > 128 * 1024 * 1024:
                        raise RuntimeError("실험 출력 128 MiB 초과")
                    observed = key.data == ("stdout" if kind == "rg" else "stderr")
                    if observed and first_ms is None:
                        pending.extend(data)
                        while b"\n" in pending:
                            line, _, pending = pending.partition(b"\n")
                            try:
                                event = json.loads(line)
                            except ValueError:
                                continue
                            if event.get("type") == "match" or event.get("event") == "first-match":
                                first_ms = (time.perf_counter() - start) * 1000
                                break
                if usage is None:
                    pid, status, current_usage = os.wait4(child.pid, os.WNOHANG)
                    if pid:
                        usage = current_usage
                        child.returncode = os.waitstatus_to_exitcode(status)
            elapsed_ms = (time.perf_counter() - start) * 1000
    finally:
        if child.returncode is None:
            child.kill()
            _, status, usage = os.wait4(child.pid, 0)
            child.returncode = os.waitstatus_to_exitcode(status)
        child.stdout.close()
        child.stderr.close()
        artifact.with_suffix(".stdout").write_bytes(chunks["stdout"])
        artifact.with_suffix(".stderr").write_bytes(chunks["stderr"])
    return {
        "exit": child.returncode,
        "elapsed_ms": elapsed_ms,
        "first_ms": first_ms,
        "peak_rss_bytes": usage.ru_maxrss * (1 if sys.platform == "darwin" else 1024),
        "stdout": bytes(chunks["stdout"]),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--rg", default=shutil.which("rg"))
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--files", type=int, default=2048)
    parser.add_argument("--file-bytes", type=int, default=32768)
    args = parser.parse_args()
    if not args.rg or args.runs < 1 or args.files < 16 or args.file_bytes < 128:
        parser.error("rg, runs >= 1, files >= 16, file-bytes >= 128이 필요합니다")
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    corpus = root / "corpus"
    corpus.mkdir()
    home = root / "home"
    home.mkdir()
    environment = {**os.environ, "HOME": str(home), "XDG_CONFIG_HOME": str(home), "LC_ALL": "C"}
    environment.pop("RIPGREP_CONFIG_PATH", None)
    binary = Path(args.rg).resolve(strict=True)
    native = args.native.resolve(strict=True)
    base = [str(binary), "--no-config", "--hidden", "--no-require-git",
            "--no-ignore-parent", "--no-ignore-global", "--glob", "!**/.git/**"]
    rare = (args.files + 15) // 16
    for index in range(args.files):
        folder = corpus / str(index % 32)
        folder.mkdir(exist_ok=True)
        prefix = ("needle 한글\n" if index % 16 == 0 else "filler 한글\n").encode()
        (folder / f"{index}.txt").write_bytes(prefix + b"x" * (args.file_bytes - len(prefix) - 1) + b"\n")
    cases = [
        ("rare", "needle", "literal", rare),
        ("common", "filler", "literal", args.files - rare),
        ("absent", "absent-pattern", "literal", 0),
        ("fold", "NEEDLE", "literal-fold", rare),
        ("common-fold", "FILLER", "literal-fold", args.files - rare),
        ("word", "needle", "word", rare),
        ("unicode", "한글", "literal", args.files),
        ("lookbehind", "(?<=nee)dle", "regex", rare),
    ]
    report = {
        "platform": platform.platform(), "files": args.files,
        "input_bytes": args.files * args.file_bytes, "runs": args.runs,
        "rg_version": subprocess.check_output([str(binary), "--version"], text=True),
        "rg_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "native_sha256": hashlib.sha256(native.read_bytes()).hexdigest(),
        "native_source_sha256": hashlib.sha256(Path(__file__).with_name("native.zig").read_bytes()).hexdigest(),
        "compare_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "cases": {}, "status": "running",
        "limits": "합성 자료·캐시 미제거. 첫 pipe 결과이며 UI 표시 시간이 아님. RSS는 각 CLI 자식의 peak이며 앱·Python 메모리를 포함하지 않음.",
    }
    repository = Path(__file__).resolve().parents[2]
    report["product_base"] = subprocess.check_output(["git", "-C", str(repository), "rev-parse", "HEAD"], text=True).strip()
    report["product_source_sha256"] = {
        path: hashlib.sha256((repository / path).read_bytes()).hexdigest()
        for path in ("src/session/editor/find.zig", "src/session/editor/document.zig",
                     "src/session/editor/line_index.zig", "src/session/editor/selection.zig",
                     "src/terminal/selection.zig", "src/regex.zig")
    }
    if sys.platform == "darwin":
        report["hardware"] = {key: subprocess.check_output(["sysctl", "-n", key], text=True).strip()
                              for key in ("machdep.cpu.brand_string", "hw.memsize", "hw.ncpu")}
    try:
        for name, query, mode, expected in cases:
            # 이 후보 필터의 안전성 주장은 단일 줄 ASCII 평문에만 한정한다.
            variants = ["rg", "native", "prefilter"]
            if mode == "literal":
                variants.append("byte-candidate")
            samples = {variant: [] for variant in variants}
            for run_index in range(args.runs):
                order = variants[run_index % len(variants):] + variants[:run_index % len(variants)]
                for variant in order:
                    artifact = root / f"{name}-{variant}-{run_index}"
                    if variant == "rg":
                        pattern_flags = ["--engine", "auto"] if mode == "regex" else ["--fixed-strings"]
                        flags = ["--ignore-case"] if mode == "literal-fold" else ["--case-sensitive"]
                        if mode == "word":
                            flags.append("--word-regexp")
                        result = execute(base + ["--json", "--crlf"] + pattern_flags + flags + ["--regexp", query, "--", "."], corpus, environment, artifact, "rg")
                        records = [json.loads(line) for line in result.pop("stdout").splitlines()]
                        count = sum(len(record["data"]["submatches"]) for record in records if record["type"] == "match")
                        assert result["exit"] == (0 if expected else 1)
                    else:
                        command, prefilter_used = candidate_command(base, query, mode, variant == "prefilter")
                        listing = execute(command, corpus, environment, artifact.with_name(artifact.name + "-listing"), "listing")
                        assert listing["exit"] in (0, 1)
                        prepare_start = time.perf_counter()
                        paths = [name for name in listing.pop("stdout").split(b"\0") if name]
                        paths_file = artifact.with_suffix(".paths")
                        paths_file.write_bytes(b"".join(os.fsencode(corpus) + b"/" + path + b"\0" for path in paths))
                        preceding_ms = listing["elapsed_ms"] + (time.perf_counter() - prepare_start) * 1000
                        native_mode = "byte-candidate" if variant == "byte-candidate" else mode
                        result = execute([str(native), str(paths_file), query, native_mode], corpus, environment, artifact, "native")
                        statistics_native = json.loads(result.pop("stdout"))
                        assert result["exit"] == 0 and statistics_native["optimize"] == "ReleaseFast"
                        count = statistics_native["matches"]
                        result.update(elapsed_ms=preceding_ms + result["elapsed_ms"],
                                      selected_files=len(paths), read_bytes=statistics_native["bytes"],
                                      listing_ms=listing["elapsed_ms"], listing_peak_rss_bytes=listing["peak_rss_bytes"],
                                      prefilter_used=prefilter_used)
                        if result["first_ms"] is not None:
                            result["first_ms"] += preceding_ms
                    assert count == expected, (name, variant, count, expected)
                    assert (result["first_ms"] is not None) == (expected != 0), (name, variant, "first result")
                    result["matches"] = count
                    samples[variant].append(result)
            report["cases"][name] = {
                "query": query, "mode": mode, "expected": expected,
                "samples": samples,
                "median_ms": {variant: statistics.median(row["elapsed_ms"] for row in rows) for variant, rows in samples.items()},
                "median_first_ms": {variant: statistics.median(row["first_ms"] for row in rows) if expected else None for variant, rows in samples.items()},
            }
            print(name, report["cases"][name]["median_ms"], flush=True)
        report["status"] = "passed"
    except BaseException as error:
        report["status"] = "failed"
        report["error"] = repr(error)
        raise
    finally:
        (root / "comparison.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(root / "comparison.json")


if __name__ == "__main__":
    main()
