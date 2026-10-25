#!/usr/bin/env python3
"""격리 사본에서 다섯 독립 보호 결함과 각 전후 정상 대조군을 실행한다."""
import argparse
import hashlib
import json
import re
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
COLORS = "src/session/editor/bracket_colors.zig"
HOST = "src/platform/macos/app_session/editor/syntax.zig"
FILES = (
    COLORS,
    HOST,
    "src/session/editor/brackets.zig",
    "src/platform/macos/app_session/editor/mod.zig",
    "build.zig",
)
CASES = (
    (
        "disabled-reuse",
        HOST,
        "if (reuse.finish()) {",
        "if (false and reuse.finish()) {",
        "bracket reposition product coordinate edits",
    ),
    (
        "ignored-pool",
        COLORS,
        "previous_pool != current_pool or scratch.len / 2 < tokens.len",
        "(previous_pool != current_pool and false) or scratch.len / 2 < tokens.len",
        "bracket reposition product changed shape and pool",
    ),
    (
        "ignored-colorized",
        COLORS,
        " or old.colorized != t.colorized",
        "",
        "bracket reposition rejects pool structural attributes",
    ),
    (
        "skipped-long-line-filter",
        COLORS,
        "self.failed or !self.filter.includes(t)",
        "self.failed",
        "bracket reposition uses current Unicode CRLF",
    ),
    (
        "early-coordinate-publication",
        COLORS,
        "        const old = self.tokens[self.matched];",
        "        self.tokens[self.matched].start = t.start;\n        const old = self.tokens[self.matched];",
        "bracket reposition late mismatch",
    ),
)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    output = args.output.expanduser().resolve()
    if output.exists() or output.is_relative_to(ROOT):
        parser.error("Use a new output directory outside the repository")
    output.mkdir(parents=True)
    source = output / "source"
    subprocess.run(
        [
            "rsync",
            "-a",
            "--exclude=.git",
            "--exclude=.zig-cache",
            "--exclude=zig-out",
            "--exclude=node_modules",
            "--exclude=references",
            "--exclude=.env*",
            "--exclude=.codex-worktrees",
            str(ROOT) + "/",
            str(source) + "/",
        ],
        check=True,
    )
    originals = {name: (source / name).read_text() for name in FILES}
    hashes = {name: digest(ROOT / name) for name in FILES}
    receipt = dict(
        source_head=subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
        ).strip(),
        files=hashes,
        generator_sha256=digest(Path(__file__)),
        cases=[],
    )
    (output / "generator.py").write_bytes(Path(__file__).read_bytes())

    def execute(name, defect=None):
        for path, text in originals.items():
            if defect is not None and path == defect[1]:
                if text.count(defect[2]) != 1:
                    raise ValueError("Ambiguous mutation: " + defect[0])
                text = text.replace(defect[2], defect[3], 1)
            (source / path).write_text(text)
        result = subprocess.run(
            [
                "mise",
                "exec",
                "--",
                "zig",
                "build",
                "test-editor-bracket-reposition",
                "--summary",
                "all",
                "-j2",
                "--cache-dir",
                str(output / "cache"),
            ],
            cwd=source,
            capture_output=True,
            text=True,
            timeout=900,
        )
        log = result.stdout + result.stderr
        (output / (name + ".log")).write_text(log)
        if defect is None:
            ok = (
                result.returncode == 0
                and "All 7 tests passed." in log
                and "All 33 tests passed." in log
            )
        else:
            # 컴파일 오류·표본 선택 오류는 결함을 검출한 증거가 아니다.
            block = re.search(
                r"(?ms)^\d+/\d+ [^\n]*"
                + re.escape(defect[4])
                + r"[^\n]*(?:\n(?!\d+/\d+ )[^\n]*)*",
                log,
            )
            ok = (
                result.returncode != 0
                and block is not None
                and "FAIL (" in block.group()
            )
        receipt["cases"].append(
            dict(name=name, exit_code=result.returncode, verified=ok)
        )
        (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(name, ok, flush=True)
        if not ok:
            raise RuntimeError(log[-6000:])

    try:
        for case in CASES:
            execute(case[0] + "-before")
            execute(case[0], case)
            execute(case[0] + "-restored")
    finally:
        for name, text in originals.items():
            (source / name).write_text(text)
    if {name: digest(ROOT / name) for name in FILES} != hashes:
        raise RuntimeError("Original source changed during review")
    receipt["original_unchanged"] = True
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(output / "receipt.json", flush=True)


if __name__ == "__main__":
    main()
