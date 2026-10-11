#!/usr/bin/env python3
"""닫힌 파일 준비의 물리 신원·원문·별칭·점유·총량 보호를 격리 source에서 검증한다."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix="maru-batch-disk-adversarial-"))
source = root / "source"
subprocess.run(["rsync", "-a", "--exclude=.git", "--exclude=.zig-cache", "--exclude=zig-out", "--exclude=node_modules", "--exclude=references", "--exclude=.env*", "--exclude=.codex-worktrees", str(repo) + "/", str(source) + "/"], check=True)
for name in ("node_modules", "web/node_modules"):
    if (repo / name).exists():
        (source / name).symlink_to(repo / name, target_is_directory=True)
disk = Path("src/platform/macos/app_session/editor/search/batch/disk.zig")
verify = Path("src/platform/macos/app_session/editor/search/verify.zig")
original = {path: (source / path).read_text() for path in (disk, verify)}
def mutate(path, old, new):
    assert original[path].count(old) == 1, old
    result = dict(original)
    result[path] = result[path].replace(old, new, 1)
    return result
cases = [
    ("control", original, True),
    ("ignore-inode", mutate(verify, "!self.sameFile(current)", "(!self.sameFile(current) and false)"), False),
    ("ignore-raw-bytes", mutate(verify, "!std.mem.eql(u8, &self.raw_hash, &current.raw_hash)", "(!std.mem.eql(u8, &self.raw_hash, &current.raw_hash) and false)"), False),
    ("ignore-alias", mutate(disk, "prior.proof.sameFile(loaded.proof)", "(prior.proof.sameFile(loaded.proof) and false)"), False),
    ("ignore-occupied", mutate(disk, "identity.eql(loaded.proof.identity)", "(identity.eql(loaded.proof.identity) and false)"), False),
    ("ignore-total-budget", mutate(disk, "@min(file_limit, total_limit -| bytes)", "@min(file_limit, total_limit +| bytes)"), False),
    ("equivalent-control", mutate(disk, "bytes += loaded.bytes.len;", "bytes = bytes + loaded.bytes.len;"), True),
    ("restored-control", original, True),
]
results = []
for name, changed, passing in cases:
    for path, content in changed.items():
        (source / path).write_text(content)
    result = subprocess.run(["mise", "exec", "--", "zig", "build", "test-editor-project-replace-batch-disk", "-j2", "--cache-dir", str(root / name / "cache")], cwd=source, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=240)
    (root / f"{name}.log").write_text(result.stdout)
    if passing:
        assert result.returncode == 0 and "All 6 tests passed" in result.stdout, (name, result.stdout[-4000:])
    else:
        assert result.returncode != 0 and "FAIL (" in result.stdout, (name, result.stdout[-4000:])
    results.append(dict(name=name, expected_pass=passing, exit_code=result.returncode, sha256={str(path): hashlib.sha256(content.encode()).hexdigest() for path, content in changed.items()}))
    print(name + ": verified", flush=True)
for path, content in original.items():
    (source / path).write_text(content)
(root / "results.json").write_text(json.dumps(dict(scope="closed file read and revalidation API; no model loading or product disk batch apply", results=results), indent=2) + "\n")
print(root / "results.json", flush=True)
