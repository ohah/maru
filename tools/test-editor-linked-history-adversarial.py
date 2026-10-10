#!/usr/bin/env python3
"""실제 EditableFile을 사용하는 연결 편집 판정에 컴파일 가능한 결함을 주입한다."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--host-only", action="store_true", help="이미 실행한 모델 변이 대신 actor의 다섯 관점만 실행한다")
parser.add_argument("--host-binary", type=Path, help="LHG1~11과 초기화 4개가 컴파일된 실제 actor 판정 바이너리")
args = parser.parse_args()
if args.host_binary and not args.host_binary.is_file():
    parser.error("Host binary does not exist")
if args.host_only and not args.host_binary:
    parser.error("--host-only requires --host-binary")
repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix="maru-linked-history-adversarial-"))
editor = root / "editor"
(editor / "history").mkdir(parents=True)
for name in ("buffer", "delta", "selection", "line_index", "document", "edit_doc", "history"):
    shutil.copy2(repo / f"src/session/editor/{name}.zig", editor / f"{name}.zig")
shutil.copy2(repo / "src/session/editor/history/step.zig", editor / "history/step.zig")
forward = editor / "history/forward.zig"
original = (repo / "src/session/editor/history/forward.zig").read_text()
(root / "judge.zig").write_text('test { @import("std").testing.refAllDecls(@import("editor/history/forward.zig")); }\n')
cases = [
    ("control", original, True),
    ("skip-final-validation", original.replace("for (self.items.items) |item| {", "for (self.items.items[0..0]) |item| {", 1), False),
    ("publish-A-before-B-prepared", original.replace("prepared.items.appendAssumeCapacity(try prepareOne(t));", "prepared.items.appendAssumeCapacity(try prepareOne(t));\n            if (i == 0 and targets.len > 1) try prepared.commit();", 1), False),
    ("accept-noop-document", original.replace("if (std.mem.eql(u8, next.content, t.file.content))", "if (std.mem.eql(u8, next.content, t.file.content) and false)", 1), False),
    ("discard-one-extra-history-entry", original.replace("history.stack_limit - 1", "history.stack_limit - 2", 1), False),
    ("skip-reserved-id-revalidation", original.replace("h.next_id != item.next_id or", "", 1), False),
    ("equivalent-control", original.replace("const drop = t.state.undo_len - keep;", "const drop = (t.state.undo_len - keep);", 1), True),
    ("restored-control", original, True),
]
results = []
for name, source, passes in ([] if args.host_only else cases):
    if name != "control" and name != "restored-control":
        assert source != original, name
    forward.write_text(source)
    result = subprocess.run(["mise", "exec", "--", "zig", "test", "judge.zig", "--test-filter", "LHT", "--cache-dir", str(root / name / "cache")], cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (root / f"{name}.log").write_text(result.stdout)
    if passes:
        assert result.returncode == 0 and "All 5 tests passed" in result.stdout, (name, result.stdout[-4000:])
    else:
        assert result.returncode != 0 and "FAIL (" in result.stdout, (name, result.stdout[-4000:])
    results.append(dict(name=name, expected_pass=passes, exit_code=result.returncode, source_sha256=hashlib.sha256(source.encode()).hexdigest()))
    print(f"{name}: verified", flush=True)
reviews = []
if args.host_binary:
    for scope, tests in (
        ("input-and-confirmation", (1, 2, 11)),
        ("followup-and-pending-invalidation", (3, 4)),
        ("view-lifetime-and-history-order", (5, 9)),
        ("composition-and-cross-window-refusal", (6, 8)),
        ("allocation-and-identity-exhaustion", (7, 10)),
    ):
        env = dict(os.environ)
        env["MARU_TEST_KEEP_ONLY_PREFIX"] = ",".join(f"app_session.editor.mod.test.LHG{number} " for number in tests)
        result = subprocess.run([str(args.host_binary.resolve()), "--maru-expect-tests=15", f"--maru-expect-passed={len(tests)}"], cwd=repo, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (root / f"{scope}.log").write_text(result.stdout)
        assert result.returncode == 0, (scope, result.stdout[-4000:])
        reviews.append(dict(scope=scope, tests=list(tests), exit_code=result.returncode))
        print(f"{scope}: verified", flush=True)
(root / "results.json").write_text(json.dumps(dict(focused_reviews=reviews, scope="real EditableFile forward prepare commit; actor UI tested separately", results=results), indent=2) + "\n")
print(root / "results.json", flush=True)
