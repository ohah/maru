#!/usr/bin/env python3
"""실제 검색 배치 UI의 범위·이력 결과 보존을 격리 source에서 검증한다."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix="maru-batch-ui-adversarial-"))
source = root / "source"
subprocess.run(["rsync", "-a", "--exclude=.git", "--exclude=.zig-cache", "--exclude=zig-out", "--exclude=node_modules", "--exclude=references", "--exclude=.env*", "--exclude=.codex-worktrees", str(repo) + "/", str(source) + "/"], check=True)
for name in ("node_modules", "web/node_modules"):
    if (repo / name).exists():
        (source / name).symlink_to(repo / name, target_is_directory=True)
ui = Path("src/platform/macos/app_session/editor/search/batch/ui.zig")
original = (source / ui).read_text()
def mutate(old, new):
    assert original.count(old) == 1, old
    return original.replace(old, new, 1)
cases = [
    ("control", original, True),
    ("skip-collapsed-targets", mutate("for (st.result.model.groups.items) |group| {", "for (st.result.model.groups.items) |group| {\n        if (group.collapsed) continue;"), False),
    ("hide-closed-files", mutate(".omitted = omitted.count()", ".omitted = 0"), False),
    ("lose-save-outcomes", mutate("transaction.phase = .completed;", "transaction.result.saved = 0;\n    transaction.phase = .completed;"), False),
    ("forget-historical-outcomes", mutate("if (!self.active() or self.phase == .completed) return;", "if (!self.active()) return;"), False),
    ("drop-result-ime-guard", mutate("if (self.ime_active or self.ime_editor_commit_pending or !self.tryCommitComposition()) return;", "if (!self.tryCommitComposition() and false) return;"), False),
    ("equivalent-control", mutate("captured += 1;", "captured = captured + 1;"), True),
    ("restored-control", original, True),
]
results = []
for name, changed, passing in cases:
    (source / ui).write_text(changed)
    result = subprocess.run(["mise", "exec", "--", "zig", "build", "test-editor-project-replace-batch-ui", "-j2", "--cache-dir", str(root / name / "cache")], cwd=source, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=300)
    (root / f"{name}.log").write_text(result.stdout)
    if passing:
        assert result.returncode == 0 and "All 10 tests passed" in result.stdout, (name, result.stdout[-4000:])
    else:
        assert result.returncode != 0 and "FAIL (" in result.stdout and "FAIL (Timeout)" not in result.stdout, (name, result.stdout[-4000:])
    results.append(dict(name=name, expected_pass=passing, exit_code=result.returncode, sha256=hashlib.sha256(changed.encode()).hexdigest()))
    print(name + ": verified", flush=True)
(source / ui).write_text(original)
(root / "results.json").write_text(json.dumps(dict(scope="actual completed search, open-model batch UI controller, worker and actor; no physical IME or GUI pixels", results=results), indent=2) + "\n")
print(root / "results.json", flush=True)
