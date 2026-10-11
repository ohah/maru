#!/usr/bin/env python3
"""혼합 worker의 hash·점유·취소·총량·source 보호를 격리 source에서 검증한다."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix="maru-mixed-worker-adversarial-"))
source = root / "source"
subprocess.run(["rsync", "-a", "--exclude=.git", "--exclude=.zig-cache", "--exclude=zig-out", "--exclude=node_modules", "--exclude=references", "--exclude=.env*", "--exclude=.codex-worktrees", str(repo) + "/", str(source) + "/"], check=True)
for name in ("node_modules", "web/node_modules"):
    if (repo / name).exists():
        (source / name).symlink_to(repo / name, target_is_directory=True)
worker = Path("src/platform/macos/app_session/editor/search/batch/mixed_worker.zig")
disk = Path("src/platform/macos/app_session/editor/search/batch/disk.zig")
original = {path: (source / path).read_text() for path in (worker, disk)}
def mutate(path, old, new):
    assert original[path].count(old) == 1, old
    result = dict(original)
    result[path] = result[path].replace(old, new, 1)
    return result
no_hash = dict(original)
no_hash[disk] = no_hash[disk].replace("if (!std.mem.eql(u8, &loaded.hash, &target.hash))", "if (false and !std.mem.eql(u8, &loaded.hash, &target.hash))").replace("if (!std.mem.eql(u8, &current.hash, &target.hash))", "if (false and !std.mem.eql(u8, &current.hash, &target.hash))")
no_limit = dict(original)
no_limit[worker] = no_limit[worker].replace("self.total_limit - model_bytes, self.file_limit", "self.total_limit + model_bytes, self.file_limit").replace("bodies, self.total_limit, self.file_limit", "bodies, self.total_limit + model_bytes, self.file_limit")
cases = [
    ("control", original, True),
    ("ignore-disk-hash", no_hash, False),
    ("ignore-occupancy", mutate(worker, "targets, self.occupied, &self.control", "targets, &.{}, &self.control"), False),
    ("publish-cancelled-result", mutate(worker, "if (self.control.cancelled.load(.acquire)) return error.Cancelled;\n        if (self.failure)", "if (false and self.control.cancelled.load(.acquire)) return error.Cancelled;\n        if (self.failure)"), False),
    ("lose-mixed-budget", no_limit, False),
    ("lose-source-binding", mutate(worker, ".source = model.source, .text = text", ".source = .disk, .text = text"), False),
    ("equivalent-control", mutate(worker, "model_bytes += model.snapshot.byteLen()", "model_bytes = model_bytes + model.snapshot.byteLen()"), True),
    ("restored-control", original, True),
]
results = []
for name, changed, passing in cases:
    for path, content in changed.items():
        (source / path).write_text(content)
    result = subprocess.run(["mise", "exec", "--", "zig", "build", "test-editor-project-replace-mixed-worker", "-j2", "--cache-dir", str(root / name / "cache")], cwd=source, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=240)
    (root / f"{name}.log").write_text(result.stdout)
    if passing:
        assert result.returncode == 0 and "All 11 tests passed" in result.stdout, (name, result.stdout[-4000:])
    else:
        assert result.returncode != 0 and "FAIL (" in result.stdout, (name, result.stdout[-4000:])
    results.append(dict(name=name, expected_pass=passing, exit_code=result.returncode, sha256={str(path): hashlib.sha256(content.encode()).hexdigest() for path, content in changed.items()}))
    print(name + ": verified", flush=True)
for path, content in original.items():
    (source / path).write_text(content)
(root / "results.json").write_text(json.dumps(dict(scope="mixed snapshot/disk worker and coordinator fixture; no project-wide product UI", results=results), indent=2) + "\n")
print(root / "results.json", flush=True)
