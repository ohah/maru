#!/usr/bin/env python3
"""프로젝트 검색 후보의 실제 CLI 동작을 잰다. 제품·기본 CI에는 연결하지 않는다."""

import argparse
import base64
import errno
import hashlib
import json
import os
from pathlib import Path
import platform
import selectors
import shutil
import statistics
import subprocess
import time


def raw_field(value):
    if "text" in value:
        return value["text"].encode("utf-8")
    return base64.b64decode(value["bytes"], validate=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--rg", default=shutil.which("rg"))
    parser.add_argument("--native", type=Path, help="기존 찾기를 호출하는 비교 바이너리")
    parser.add_argument("--files", type=int, default=2048)
    parser.add_argument("--file-bytes", type=int, default=32768)
    parser.add_argument("--runs", type=int, default=5)
    args = parser.parse_args()
    if not args.rg or args.files < 1 or args.file_bytes < 64 or args.runs < 1:
        parser.error("실행 가능한 rg와 양수 작업량이 필요합니다 (--file-bytes >= 64).")
    binary = Path(args.rg).resolve(strict=True)
    native = args.native.resolve(strict=True) if args.native else None
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    home = output / "home"
    home.mkdir()
    root = output / "fixture"
    root.mkdir()
    # 개인 ignore/config가 결과를 바꾸면 다른 기기에서 같은 계약을 검증할 수 없다.
    environment = os.environ.copy()
    environment.update(HOME=str(home), XDG_CONFIG_HOME=str(home), LC_ALL="C")
    environment.pop("RIPGREP_CONFIG_PATH", None)
    common = [str(binary), "--no-config", "--hidden", "--no-require-git",
              "--no-ignore-parent", "--no-ignore-global", "--crlf", "--json",
              "--glob", "!**/.git/**", "--glob", "!**/.hg/**",
              "--glob", "!**/.svn/**"]
    report = {
        "platform": platform.platform(), "machine": platform.machine(),
        "binary": str(binary), "binary_bytes": binary.stat().st_size,
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "probe_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "version": subprocess.check_output([str(binary), "--version"], text=True),
        "base_argv": common[1:], "checks": [], "not_exercised": [],
    }

    def write(name, data):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def run(name, query, *, regex=False, flags=(), cwd=root, env=None):
        command = common + (["--engine", "auto"] if regex else ["--fixed-strings"])
        command += list(flags) + ["--regexp", query, "--", "."]
        start = time.perf_counter()
        result = subprocess.run(command, cwd=cwd, env=env or environment,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
        elapsed = (time.perf_counter() - start) * 1000
        (output / f"{name}.jsonl").write_bytes(result.stdout)
        (output / f"{name}.stderr").write_bytes(result.stderr)
        records = [json.loads(line) for line in result.stdout.splitlines()]
        matches = [record["data"] for record in records if record["type"] == "match"]
        return result.returncode, matches, elapsed, len(result.stdout)

    def check(name, condition):
        report["checks"].append({"name": name, "passed": bool(condition)})
        if not condition:
            raise AssertionError(name)

    def paths(matches):
        return {raw_field(match["path"]).removeprefix(b"./") for match in matches}

    def native_run(name, file_list, query, mode):
        result = subprocess.run([str(native), str(file_list), query, mode],
                                capture_output=True, timeout=20, check=True)
        (output / f"{name}.native.json").write_bytes(result.stdout)
        (output / f"{name}.native.stderr").write_bytes(result.stderr)
        return json.loads(result.stdout)

    try:
        write("normal.txt", "needle 한글\nalpha alpha\n--\n".encode())
        write(".visible.txt", b"needle\n")
        write(".gitignore", b"ignored/\n*.drop\n!keep.drop\n")
        write(".ignore", b"local.txt\n")
        write(".rgignore", b"rg-local.txt\n")
        write("ignored/file.txt", b"needle\n")
        write("bad.drop", b"needle\n")
        write("keep.drop", b"needle\n")
        write("local.txt", b"needle\n")
        write("rg-local.txt", b"needle\n")
        write(".git/objects/private", b"needle\n")
        write("nested/.gitignore", b"*.txt\n!keep.txt\n")
        write("nested/drop.txt", b"needle\n")
        write("nested/keep.txt", b"needle\n")
        write("binary.dat", b"\x00needle\n")
        write("crlf.txt", b"anchor\r\n")
        write("invalid-content.txt", b"needle\xff\n")
        write("name\nwith-newline.txt", b"needle\n")
        external = output / "outside.txt"
        external.write_bytes(b"needle\n")
        (root / "outside-link.txt").symlink_to(external)
        # JSON의 bytes 표현을 잃으면 손상된 이름으로 다른 파일을 열 위험이 있다.
        expected = {b"normal.txt", b".visible.txt", b"keep.drop", b"nested/keep.txt",
                    b"name\nwith-newline.txt", b"invalid-content.txt"}
        try:
            with open(os.fsencode(root) + b"/invalid-\xff.txt", "wb") as stream:
                stream.write(b"needle\n")
            expected.add(b"invalid-\xff.txt")
        except OSError as error:
            if error.errno != errno.EILSEQ:
                raise
            report["not_exercised"].append("파일 시스템이 잘못된 UTF-8 파일명을 거부함")
        code, matches, _, _ = run("scope", "needle")
        check("숨김 파일·중첩 ignore·되살리기·링크·바이너리·특수 파일명", code == 0 and paths(matches) == expected)
        invalid = [match for match in matches if raw_field(match["path"]).endswith(b"invalid-content.txt")]
        check("JSON bytes 본문 복호화", len(invalid) == 1 and raw_field(invalid[0]["lines"]) == b"needle\xff\n")
        code, matches, _, _ = run("unicode", "한글")
        check("한글 UTF-8 바이트 위치", code == 0 and len(matches) == 1 and
              [(m["start"], m["end"]) for m in matches[0]["submatches"]] == [(7, 13)])
        code, matches, _, _ = run("lookbehind", r"(?<=alpha )alpha", regex=True)
        check("PCRE2 lookbehind 자동 선택", code == 0 and len(matches) == 1)
        code, matches, _, _ = run("backreference", r"(alpha) \1", regex=True)
        check("PCRE2 역참조 자동 선택", code == 0 and len(matches) == 1)
        code, matches, _, _ = run("crlf", r"^anchor$", regex=True)
        check("CRLF 줄 끝", code == 0 and paths(matches) == {b"crlf.txt"})
        code, matches, _, _ = run("dash-query", "--")
        check("검색어를 옵션으로 해석하지 않음", code == 0 and paths(matches) == {b"normal.txt"})
        code, matches, _, _ = run("zero", "absent-pattern")
        check("검색 결과 없음 exit 1", code == 1 and not matches)
        code, _, _, _ = run("invalid-regex", "[", regex=True)
        check("잘못된 정규식 exit 2", code == 2)
        code, matches, _, _ = run("empty-match", r"(?=alpha)", regex=True)
        check("빈 매치 종료와 위치", code == 0 and len(matches) == 1 and
              [(m["start"], m["end"]) for m in matches[0]["submatches"]] == [(0, 0), (6, 6)])
        hostile_config = output / "hostile.rgrc"
        hostile_config.write_text("--glob=!**\n")
        env = {**environment, "RIPGREP_CONFIG_PATH": str(hostile_config)}
        code, matches, _, _ = run("config-isolation", "needle", env=env)
        check("사용자 ripgrep config 격리", code == 0 and paths(matches) == expected)
        code, matches, _, _ = run("include-override", "needle", flags=["--glob", "**/*.drop"])
        check("명시 include가 ignore를 덮는 실제 우선순위", code == 0 and paths(matches) == {b"bad.drop", b"keep.drop"})

        stress = output / "stress"
        stress.mkdir()
        for index in range(args.files):
            folder = stress / str(index % 32)
            folder.mkdir(exist_ok=True)
            prefix = b"needle\n" if index % 16 == 0 else b"filler\n"
            (folder / f"{index}.txt").write_bytes(prefix + b"x" * (args.file_bytes - len(prefix) - 1) + b"\n")
        durations = []
        output_bytes = []
        for index in range(args.runs):
            code, matches, elapsed, size = run(f"stress-{index}", "needle", cwd=stress)
            check(f"실제 파일 검색 {index + 1}", code == 0 and len(matches) == (args.files + 15) // 16)
            durations.append(elapsed)
            output_bytes.append(size)
        report["stress"] = {"files": args.files, "input_bytes": args.files * args.file_bytes,
                            "elapsed_ms": durations, "median_ms": statistics.median(durations),
                            "stdout_bytes": output_bytes,
                            "note": "OS 캐시를 비우지 않은 CLI 측정. 앱 지연·메모리 측정이 아님."}

        if native:
            report["native_binary"] = str(native)
            report["native_binary_sha256"] = hashlib.sha256(native.read_bytes()).hexdigest()
            write("difference.txt", b"foo\n")
            single = output / "single.paths"
            single.write_bytes(os.fsencode(root / "difference.txt") + b"\0")
            code, matches, _, _ = run("empty-alternative-rg", "^|foo", regex=True,
                                      flags=["--glob", "**/difference.txt"])
            native_result = native_run("empty-alternative", single, "^|foo", "regex")
            check("빈 대안의 엔진 차이를 실제 기존 찾기와 대조", code == 0 and len(matches) == 1 and
                  matches[0]["submatches"][0]["end"] == 0 and native_result["first"]["len"] == 3)
            code, matches, _, _ = run("empty-alternative-pcre2", "^|foo", regex=True,
                                      flags=["--pcre2", "--glob", "**/difference.txt"])
            check("PCRE2 강제만으로 빈 대안 반복 규칙이 맞지 않음", code == 0 and len(matches) == 1 and
                  matches[0]["submatches"][0]["end"] == 0)
            write("difference.txt", "foo😀bar\n".encode())
            code, matches, _, _ = run("whole-word-rg", "foo", flags=["--word-regexp", "--glob", "**/difference.txt"])
            native_result = native_run("whole-word", single, "foo", "word")
            check("단어 경계의 엔진 차이를 실제 기존 찾기와 대조", code == 0 and len(matches) == 1 and native_result["matches"] == 0)

            durations = []
            matcher_ns = []
            listing_bytes = []
            file_list = output / "stress.paths"
            listing_command = [str(binary), "--files", "--null", "--no-config", "--hidden",
                               "--no-require-git", "--no-ignore-parent", "--no-ignore-global", "--", "."]
            for index in range(args.runs):
                start = time.perf_counter()
                listing = subprocess.run(listing_command, cwd=stress, env=environment,
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20, check=True)
                names = [name for name in listing.stdout.split(b"\0") if name]
                check(f"후보 목록의 파일 개수 {index + 1}", len(names) == args.files)
                file_list.write_bytes(b"".join(os.fsencode(stress) + b"/" + name + b"\0" for name in names))
                result = native_run(f"stress-{index}", file_list, "needle", "literal")
                durations.append((time.perf_counter() - start) * 1000)
                check(f"기존 찾기로 실제 파일 검색 {index + 1}", result["matches"] == (args.files + 15) // 16 and
                      result["bytes"] == args.files * args.file_bytes and result["files"] == args.files)
                matcher_ns.append(result["elapsed_ns"])
                listing_bytes.append(len(listing.stdout))
            report["listing_and_native"] = {
                "elapsed_ms": durations, "median_ms": statistics.median(durations),
                "matcher_elapsed_ns": matcher_ns, "listing_bytes": listing_bytes,
                "note": "rg 목록 + Python 경로 변환 + 순차 파일 읽기/기존 findMatches. 별도 프로세스·목록 파일 비용 포함. 최적화한 제품 워커가 아님.",
            }
        else:
            report["not_exercised"].append("--native 미지정: 기존 찾기와의 동작·비용 비교")

        # 출력을 실제로 받은 뒤 취소한다. 시작 전 kill은 검색 중 취소를 증명하지 않는다.
        cancellations = []
        for index in range(3):
            child = subprocess.Popen(common + ["--regexp", ".", "--", "."], cwd=stress,
                                     env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(child.stdout, selectors.EVENT_READ)
                    check(f"취소 전 실제 출력 {index + 1}", bool(selector.select(timeout=10)))
                    check(f"취소 전 출력·실행 중 {index + 1}", bool(os.read(child.stdout.fileno(), 128)) and child.poll() is None)
                start = time.perf_counter()
                child.terminate()
                code = child.wait(timeout=5)
                cancellations.append((time.perf_counter() - start) * 1000)
                check(f"취소한 자식 수거 {index + 1}", code < 0)
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=5)
                child.stdout.close()
                child.stderr.close()
        report["cancel_ms"] = cancellations
        report["status"] = "passed"
    except BaseException as error:
        report["status"] = "failed"
        report["error"] = str(error)
        raise
    finally:
        (output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(output / "report.json")


if __name__ == "__main__":
    main()
