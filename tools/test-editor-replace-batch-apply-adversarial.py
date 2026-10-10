#!/usr/bin/env python3
"""격리 source의 실제 AppSession 배치 판정으로 검증 누락·저장 정산·Undo 결함을 검출한다."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix="maru-batch-apply-adversarial-"))
source = root / "source"
subprocess.run(["rsync", "-a", "--exclude=.git", "--exclude=.zig-cache", "--exclude=zig-out", "--exclude=node_modules", "--exclude=references", "--exclude=.env*", "--exclude=.codex-worktrees", str(repo) + "/", str(source) + "/"], check=True)
for name in ("node_modules", "web/node_modules"):
    if (repo / name).exists():
        (source / name).symlink_to(repo / name, target_is_directory=True)
actor = Path("src/platform/macos/app_session/editor/search/batch.zig")
host = Path("src/platform/macos/app_session/editor/mod.zig")
owner = Path("src/platform/macos/app_session/editor/search/owner.zig")
original = {actor: (source / actor).read_text(), host: (source / host).read_text(), owner: (source / owner).read_text()}
def mutate(path, old, new):
    assert original[path].count(old) == 1, old
    result = dict(original)
    result[path] = result[path].replace(old, new, 1)
    return result
undo_start = original[host].index("        // 배치는 본문을 누른 적 없는 비활성 문서도 편집한다.")
undo_end = original[host].index("        // 반대편 이력은", undo_start)
undo_block = original[host][undo_start:undo_end]
cases = [
    ("control", original, True),
    ("accept-stale-body", mutate(actor, "or !std.mem.eql(u8, opened.file.content, before)", "or (!std.mem.eql(u8, opened.file.content, before) and false)"), False),
    ("ignore-real-root", mutate(actor, "try owner.validateRoots(session);", "if (session.file_tree.rootCount() == 0) try owner.validateRoots(session);"), False),
    ("ignore-edited-input", mutate(actor, "preview.settingsStamp(session) != self.settings)", "(preview.settingsStamp(session) != self.settings and false))"), False),
    ("stop-after-first-save-failure", mutate(actor, "result.save_failed += 1;", "result.save_failed += 1;\n            break;"), False),
    ("save-noops", mutate(actor, "if (target.outcome != .applied) continue;", "if (target.outcome != .applied and false) continue;"), False),
    ("refuse-selectionless-undo", mutate(host, undo_block, "        var sels = selectionsForEdit(self, term) orelse break;\n"), False),
    ("equivalent-control", mutate(actor, "var result: Result = .{};", "var result = Result{};"), True),
    ("restored-control", original, True),
]
results = []
for name, changes, passing in cases:
    for path, text in changes.items():
        (source / path).write_text(text)
    # 결함마다 cache를 따로 둔다. 빠른 파일 재작성 시 옛 실행 파일을 재사용하는 검사를 방지한다.
    result = subprocess.run(["mise", "exec", "--", "zig", "build", "test-editor-project-replace-batch-apply", "-j2", "--cache-dir", str(root / name / "cache")], cwd=source, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (root / f"{name}.log").write_text(result.stdout)
    if passing:
        assert result.returncode == 0 and "All 17 tests passed" in result.stdout, (name, result.stdout[-4000:])
    else:
        assert result.returncode != 0 and "FAIL (" in result.stdout, (name, result.stdout[-4000:])
    results.append(dict(name=name, expected_pass=passing, exit_code=result.returncode, sources={str(p): hashlib.sha256(t.encode()).hexdigest() for p, t in changes.items()}))
    print(name + ": verified", flush=True)
(root / "results.json").write_text(json.dumps(dict(scope="real AppSession all-model apply and CAS save; no product UI entry or physical IME", results=results), indent=2) + "\n")
print(root / "results.json", flush=True)
