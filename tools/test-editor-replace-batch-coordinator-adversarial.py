#!/usr/bin/env python3
"""혼합 source coordinator의 최종 검증·게시·변경 없음·Plan·Undo 보호를 격리 source에서 검증한다."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix="maru-batch-coordinator-adversarial-"))
source = root / "source"
subprocess.run(["rsync", "-a", "--exclude=.git", "--exclude=.zig-cache", "--exclude=zig-out", "--exclude=node_modules", "--exclude=references", "--exclude=.env*", "--exclude=.codex-worktrees", str(repo) + "/", str(source) + "/"], check=True)
for name in ("node_modules", "web/node_modules"):
    if (repo / name).exists():
        (source / name).symlink_to(repo / name, target_is_directory=True)
coordinator = Path("src/platform/macos/app_session/editor/search/batch/coordinator.zig")
history = Path("src/platform/macos/app_session/editor/history.zig")
original = {path: (source / path).read_text() for path in (coordinator, history)}
def mutate(path, old, new):
    assert original[path].count(old) == 1, old
    result = dict(original)
    result[path] = result[path].replace(old, new, 1)
    return result
corrupt_plan = dict(original)
corrupt_plan[coordinator] = corrupt_plan[coordinator].replace("if (edit.after_start > edit.after_end or", "if (false and (edit.after_start > edit.after_end or", 1).replace("item.plan.after[edit.after_start..edit.after_end])) return error.StalePlan;", "item.plan.after[edit.after_start..edit.after_end]))) return error.StalePlan;", 1).replace("if (!std.mem.eql(u8, pending.model.?.items.items[effective].next.content, item.plan.after))", "if ((!std.mem.eql(u8, pending.model.?.items.items[effective].next.content, item.plan.after)) and false)", 1)
cases = [
    ("control", original, True),
    ("ignore-final-disk-proof", mutate(coordinator, "for (closed) |source| try load.validateTarget(session, source.target, source.file.proof, &staged);", "for (closed) |source| if (false) try load.validateTarget(session, source.target, source.file.proof, &staged);"), False),
    ("lose-tab-publication", mutate(coordinator, "load.publish(&staged, destination);", "if (false) load.publish(&staged, destination);"), False),
    ("publish-noop-documents", mutate(coordinator, "if (item.changes.len > 0) {\n                targets.appendAssumeCapacity(source.target);", "if (item.changes.len >= 0) {\n                targets.appendAssumeCapacity(source.target);"), False),
    ("trust-corrupt-plan", corrupt_plan, False),
    ("ignore-last-history-failure", mutate(history, "if (inputs.len > 1) result.record = try self.editor_documents.links.prepare(self.editor_documents.allocator, members);", "if (inputs.len > 1) result.record = if (self.editor_documents.links.prepare(self.editor_documents.allocator, members)) |record| record else |_| null;"), False),
    ("equivalent-control", mutate(coordinator, "next += 1;", "next = next + 1;"), True),
    ("restored-control", original, True),
]
results = []
for name, changed, passing in cases:
    for path, content in changed.items():
        (source / path).write_text(content)
    result = subprocess.run(["mise", "exec", "--", "zig", "build", "test-editor-project-replace-batch-coordinator", "-j2", "--cache-dir", str(root / name / "cache")], cwd=source, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=240)
    (root / f"{name}.log").write_text(result.stdout)
    if passing:
        assert result.returncode == 0 and "All 14 tests passed" in result.stdout, (name, result.stdout[-4000:])
    else:
        assert result.returncode != 0 and "FAIL (" in result.stdout, (name, result.stdout[-4000:])
    results.append(dict(name=name, expected_pass=passing, exit_code=result.returncode, sha256={str(path): hashlib.sha256(content.encode()).hexdigest() for path, content in changed.items()}))
    print(name + ": verified", flush=True)
for path, content in original.items():
    (source / path).write_text(content)
(root / "results.json").write_text(json.dumps(dict(scope="mixed source coordinator and real model publication API; no project-wide product UI", results=results), indent=2) + "\n")
print(root / "results.json", flush=True)
