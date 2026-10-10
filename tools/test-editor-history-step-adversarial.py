#!/usr/bin/env python3
"""격리 소스의 실제 문서/이력 판정으로 사전 준비·재검증·신원 보호의 효과를 확인한다."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix="maru-history-step-adversarial-"))
editor = root / "editor"
(editor / "history").mkdir(parents=True)
for name in ("buffer", "delta", "selection", "line_index", "document", "edit_doc", "history"):
    shutil.copy2(repo / f"src/session/editor/{name}.zig", editor / f"{name}.zig")
step = editor / "history/step.zig"
original_step = (repo / "src/session/editor/history/step.zig").read_text()
original_history = (editor / "history.zig").read_text()
(root / "judge.zig").write_text('test { @import("std").testing.refAllDecls(@import("editor/history/step.zig")); }\n')
cases = [
    ("control", original_step, original_history, True),
    ("skip-final-validation", original_step.replace("for (self.items.items) |item| {", "for (self.items.items[0..0]) |item| {", 1), original_history, False),
    ("publish-before-B-ready", original_step.replace("prepared.items.appendAssumeCapacity(try prepareItem(t, direction));", "prepared.items.appendAssumeCapacity(try prepareItem(t, direction));\n            if (i == 0 and targets.len > 1) try prepared.commit();", 1), original_history, False),
    ("recycle-history-id", original_step, original_history.replace("self.epoch +|= 1;", "self.epoch +|= 1;\n        self.next_id = 1;", 1), False),
    ("restored-control", original_step, original_history, True),
]
results = []
for name, text, hist, passing in cases:
    if not passing:
        assert text != original_step or hist != original_history, name
    step.write_text(text)
    (editor / "history.zig").write_text(hist)
    result = subprocess.run(["mise", "exec", "--", "zig", "test", "judge.zig", "--test-filter", "HST", "--cache-dir", str(root / name / "cache")], cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (root / f"{name}.log").write_text(result.stdout)
    if passing:
        assert result.returncode == 0 and "All 6 tests passed" in result.stdout, (name, result.stdout[-4000:])
    else:
        assert result.returncode != 0 and "FAIL (" in result.stdout, (name, result.stdout[-4000:])
    results.append(dict(name=name, exit_code=result.returncode, expected_pass=passing, step_sha256=hashlib.sha256(text.encode()).hexdigest(), history_sha256=hashlib.sha256(hist.encode()).hexdigest()))
    print(f"{name}: verified", flush=True)
(root / "results.json").write_text(json.dumps(dict(scope="real EditableFile/history; no AppSession/UI or FS writes", results=results), indent=2) + "\n")
print(root / "results.json", flush=True)
