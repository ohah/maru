#!/usr/bin/env python3
"""비활성 문서 준비의 외부 변경·점유·예약·용량·BOM 보호를 격리 source에서 검증한다."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix="maru-batch-load-adversarial-"))
source = root / "source"
subprocess.run(["rsync", "-a", "--exclude=.git", "--exclude=.zig-cache", "--exclude=zig-out", "--exclude=node_modules", "--exclude=references", "--exclude=.env*", "--exclude=.codex-worktrees", str(repo) + "/", str(source) + "/"], check=True)
for name in ("node_modules", "web/node_modules"):
    if (repo / name).exists():
        (source / name).symlink_to(repo / name, target_is_directory=True)
load = Path("src/platform/macos/app_session/editor/search/batch/load.zig")
model = Path("src/platform/macos/app_session/editor/mod.zig")
original = {path: (source / path).read_text() for path in (load, model)}
def mutate(path, old, new, count=1):
    assert original[path].count(old) == count, old
    result = dict(original)
    result[path] = result[path].replace(old, new)
    return result
cases = [
    ("control", original, True),
    ("ignore-inplace-change", mutate(load, "!proof.matchesStat(current)", "(!proof.matchesStat(current) and false)"), False),
    ("ignore-outside-occupancy", mutate(load, "try occupied(session,", "if (false) try occupied(session,", 2), False),
    ("lose-reservation-release", mutate(load, "self.session.editor_batch_reserved_entries -= self.reserved;", "self.session.editor_batch_reserved_entries -= 0;"), False),
    ("ignore-capacity", mutate(load, "if (targets.len > dock.max_entries -| count -| session.editor_batch_reserved_entries)", "if ((targets.len > dock.max_entries -| count -| session.editor_batch_reserved_entries) and false)"), False),
    ("drop-bom-format", mutate(model, "file.format.has_bom = has_bom;", "file.format.has_bom = has_bom and false;"), False),
    ("equivalent-control", mutate(load, "count += 1;", "count = count + 1;"), True),
    ("restored-control", original, True),
]
results = []
for name, changed, passing in cases:
    for path, content in changed.items():
        (source / path).write_text(content)
    result = subprocess.run(["mise", "exec", "--", "zig", "build", "test-editor-project-replace-batch-load", "-j2", "--cache-dir", str(root / name / "cache")], cwd=source, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=240)
    (root / f"{name}.log").write_text(result.stdout)
    if passing:
        assert result.returncode == 0 and "All 10 tests passed" in result.stdout, (name, result.stdout[-4000:])
    else:
        assert result.returncode != 0 and "FAIL (" in result.stdout, (name, result.stdout[-4000:])
    results.append(dict(name=name, expected_pass=passing, exit_code=result.returncode, sha256={str(path): hashlib.sha256(content.encode()).hexdigest() for path, content in changed.items()}))
    print(name + ": verified", flush=True)
for path, content in original.items():
    (source / path).write_text(content)
(root / "results.json").write_text(json.dumps(dict(scope="inactive model staging API; no pane publication or product disk batch apply", results=results), indent=2) + "\n")
print(root / "results.json", flush=True)
