#!/usr/bin/env python3
"""격리 명세와 전체 Plan 준비에 결함을 주입해 소유·검증·취소·집계를 검사한다."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix="maru-replace-batch-adversarial-"))
for name in ("request", "event", "query"):
    shutil.copy2(repo / f"src/session/editor/search/{name}.zig", root / f"{name}.zig")
original = (repo / "src/session/editor/search/batch.zig").read_text()
(root / "judge.zig").write_text('test { @import("std").testing.refAllDecls(@import("batch.zig")); }\n')
cases = [
    ("control", original, True),
    ("discard-glob-content", original.replace("try a.dupe(u8, glob);", "try a.dupe(u8, glob[0..0]);", 1), False),
    ("keep-duplicate-matches", original.replace("if (std.meta.eql(previous, range)) continue;", "if (std.meta.eql(previous, range) and false) continue;", 1), False),
    ("accept-conflicting-documents", original.replace("if (!same_path or !std.meta.eql(target.source, chosen.source))", "if ((!same_path or !std.meta.eql(target.source, chosen.source)) and false)", 1), False),
    ("accept-overlapping-ranges", original.replace("if (lessPosition(range.start, previous.end))", "if (lessPosition(range.start, previous.end) and false)", 1), False),
    ("accept-incomplete-results", original.replace("if (status != .complete)", "if (status != .complete and false)", 1), False),
    ("equivalent-control", original.replace("var count: usize = 0;", "var count: usize = @as(usize, 0);", 1), True),
    ("restored-control", original, True),
]
results = []
for name, source, passing in cases:
    if name not in ("control", "restored-control"):
        assert source != original, name
    (root / "batch.zig").write_text(source)
    result = subprocess.run(["mise", "exec", "--", "zig", "test", "judge.zig", "--test-filter", "RPB", "--cache-dir", str(root / name / "cache")], cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (root / f"{name}.log").write_text(result.stdout)
    if passing:
        assert result.returncode == 0 and "All 6 tests passed" in result.stdout, (name, result.stdout[-4000:])
    else:
        assert result.returncode != 0 and "FAIL (" in result.stdout, (name, result.stdout[-4000:])
    results.append(dict(name=name, expected_pass=passing, exit_code=result.returncode, source_sha256=hashlib.sha256(source.encode()).hexdigest()))
    print(f"{name}: verified", flush=True)
(root / "results.json").write_text(json.dumps(dict(scope="owned neutral selection specifications; no editor writes or UI", results=results), indent=2) + "\n")
print(root / "results.json", flush=True)

# Plan 검증은 실제 PCRE2/편집기 모듈로 실행한다. 제품 checkout에는 결함을 쓰지 않는다.
plan_root = root / "plans"
shutil.copytree(repo / "src", plan_root / "src")
(plan_root / "src/judge.zig").write_text('test { @import("std").testing.refAllDecls(@import("session/editor/search/batch_plan.zig")); }\n')
headers = sorted((repo / "zig-pkg").glob("pcre2-*/src/pcre2.h.generic"))
libraries = sorted((repo / ".zig-cache/o").glob("*/libpcre2-8.a"), key=lambda p: p.stat().st_mtime, reverse=True)
assert headers and libraries, "먼저 zig build test-editor-project-replace-batch를 실행하세요"
plan_path = plan_root / "src/session/editor/search/batch_plan.zig"
plan_original = plan_path.read_text()
plan_cases = [
    ("plans-control", plan_original, True),
    ("accept-wrong-source", plan_original.replace("or !std.meta.eql(target.source, body.source)", "or (!std.meta.eql(target.source, body.source) and false)", 1), False),
    ("ignore-total-budget", plan_original.replace("if (body.text.len > total_limit -| bytes)", "if (body.text.len > total_limit -| bytes and false)", 1), False),
    ("ignore-cancel", plan_original.replace("const delta =", "const never_cancelled = std.atomic.Value(bool).init(false);\nconst delta =", 1).replace("if (cancelled.load(.acquire))", "if (cancelled.load(.acquire) and false)").replace("file_limit, cancelled);", "file_limit, &never_cancelled);", 1), False),
    ("count-noops", plan_original.replace("if (changes.len > 0)", "if (changes.len >= 0)", 1), False),
    ("drop-second-plan", plan_original.replace("for (spec.targets.items, bodies) |target, body| {\n            var plan", "for (spec.targets.items[0..@min(1, spec.targets.items.len)], bodies[0..@min(1, bodies.len)]) |target, body| {\n            var plan", 1), False),
    ("plans-equivalent", plan_original.replace("bytes += body.text.len;", "bytes = bytes + body.text.len;", 1), True),
    ("plans-restored", plan_original, True),
]
plan_results = []
for name, source, passing in plan_cases:
    if name not in ("plans-control", "plans-restored"):
        assert source != plan_original, name
    plan_path.write_text(source)
    result = subprocess.run(["mise", "exec", "--", "zig", "test", "src/judge.zig", "--test-filter", "RPBP", "-I", str(headers[0].parent), str(libraries[0]), "-lc", "--cache-dir", str(root / name / "cache")], cwd=plan_root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (root / f"{name}.log").write_text(result.stdout)
    if passing:
        assert result.returncode == 0 and "All 6 tests passed" in result.stdout, (name, result.stdout[-4000:])
    else:
        assert result.returncode != 0 and "FAIL (" in result.stdout, (name, result.stdout[-4000:])
    plan_results.append(dict(name=name, expected_pass=passing, exit_code=result.returncode, source_sha256=hashlib.sha256(source.encode()).hexdigest()))
    print(f"{name}: verified", flush=True)
(root / "plan-results.json").write_text(json.dumps(dict(scope="prepared neutral plans; no model commit, save or UI", library=str(libraries[0]), results=plan_results), indent=2) + "\n")
print(root / "plan-results.json", flush=True)
