#!/usr/bin/env python3
"""격리 저장소에서 정상 포매터의 6초 지연과 잘못된 5초 판정 시한을 대조한다."""
import json
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix="maru-formatter-wait-"))
source = root / "source"
subprocess.run(["rsync", "-a", "--exclude=.git", "--exclude=.zig-cache", "--exclude=zig-out", "--exclude=node_modules", "--exclude=.codex-worktrees", "--exclude=references", "--exclude=.env*", str(repo) + "/", str(source) + "/"], check=True)
# SmtFixture.open은 가장 가까운 저장소를 사용한다. 이 표시가 없으면 LSP 준비부터 실패한다.
subprocess.run(["git", "init", "--quiet", str(source)], check=True)
path = source / "src/platform/macos/app_session/editor/mod.zig"
original = path.read_text()
start = original.index('test "EXFB3 ')
end = original.index("\ntest ", start + 5)
block = original[start:end]
marker = '    try installFakeFormatter(&f.fx, "node_modules/.bin/biome");'
wait = "@as(u64, test_formatter_timeout_ms) + 2_000"
assert block.count(marker) == block.count(wait) == 1
results = []
try:
    for name, delay, short in [("control", False, False), ("delayed-valid", True, False), ("premature-failure", True, True), ("restored", True, False)]:
        changed = block
        if delay:
            changed = changed.replace(marker, marker + '\n    try f.fx.dir.dir.writeFile(testing.io, .{ .sub_path = "node_modules/.bin/biome", .data = "#!/bin/sh\\n/bin/sleep 6\\n" ++ fake_formatter_script });')
        if short:
            changed = changed.replace(wait, "5000")
        path.write_text(original[:start] + changed + original[end:])
        run = subprocess.run(["mise", "exec", "--", "zig", "build", "test-editor-save-pipeline", "-j4"], cwd=source, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=300)
        (root / (name + ".log")).write_text(run.stdout)
        if short:
            verified = run.returncode != 0 and "EXFB3_WAIT stage=biome" in run.stdout and "FAIL (TestUnexpectedResult)" in run.stdout
        else:
            verified = run.returncode == 0 and "All 10 tests passed" in run.stdout
        results.append(dict(case=name, exit_code=run.returncode, verified=verified))
        (root / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        print(name + ": " + str(verified), flush=True)
        assert verified, run.stdout[-3500:]
finally:
    path.write_text(original)
print(root / "results.json", flush=True)
