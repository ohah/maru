#!/usr/bin/env python3
"""불변 batch worker의 신원·예산·취소·소유권 보호를 격리 source에서 검증한다."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix="maru-batch-worker-adversarial-"))
source = root / "source"
subprocess.run(["rsync", "-a", "--exclude=.git", "--exclude=.zig-cache", "--exclude=zig-out", "--exclude=node_modules", "--exclude=references", "--exclude=.env*", "--exclude=.codex-worktrees", str(repo) + "/", str(source) + "/"], check=True)
for name in ("node_modules", "web/node_modules"):
    if (repo / name).exists():
        (source / name).symlink_to(repo / name, target_is_directory=True)
worker = Path("src/platform/macos/app_session/editor/search/batch/worker.zig")
original = (source / worker).read_text()
def mutate(old, new):
    assert original.count(old) == 1, old
    return original.replace(old, new, 1)
cases = [
    ("control", original, True),
    ("publish-cancelled-ready", mutate("if (self.cancelled.load(.acquire)) return error.Cancelled;\n        if (self.failure)", "if (self.cancelled.load(.acquire) and false) return error.Cancelled;\n        if (self.failure)"), False),
    ("ignore-start-ticket", mutate("!std.meta.eql(specification.identity, ticket.identity)", "(!std.meta.eql(specification.identity, ticket.identity) and false)"), False),
    ("ignore-model-identity", mutate("!std.meta.eql(target.source, model.source)", "(!std.meta.eql(target.source, model.source) and false)"), False),
    ("ignore-input-budget", mutate("model.snapshot.byteLen() > total_limit -| bytes", "(model.snapshot.byteLen() > total_limit -| bytes and false)"), False),
    ("lose-start-ticket", mutate(".prepared = self.prepared.?, .ticket = self.ticket", ".prepared = self.prepared.?, .ticket = .{ .identity = self.ticket.identity, .stamp = 0, .settings = 0 }"), False),
    ("equivalent-control", mutate("bytes += model.snapshot.byteLen();", "bytes = bytes + model.snapshot.byteLen();"), True),
    ("restored-control", original, True),
]
results = []
for name, changed, passing in cases:
    (source / worker).write_text(changed)
    result = subprocess.run(["mise", "exec", "--", "zig", "build", "test-editor-project-replace-batch-worker", "-j2", "--cache-dir", str(root / name / "cache")], cwd=source, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=240)
    (root / f"{name}.log").write_text(result.stdout)
    if passing:
        assert result.returncode == 0 and "All 7 tests passed" in result.stdout, (name, result.stdout[-4000:])
    else:
        assert result.returncode != 0 and "FAIL (" in result.stdout, (name, result.stdout[-4000:])
    results.append(dict(name=name, expected_pass=passing, exit_code=result.returncode, sha256=hashlib.sha256(changed.encode()).hexdigest()))
    print(name + ": verified", flush=True)
(source / worker).write_text(original)
(root / "results.json").write_text(json.dumps(dict(scope="detached immutable snapshot worker API; no product batch UI or OS thread-spawn failure simulation", results=results), indent=2) + "\n")
print(root / "results.json", flush=True)
