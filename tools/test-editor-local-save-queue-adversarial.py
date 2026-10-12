#!/usr/bin/env python3
"""저장 큐의 기준 인계·합류·예산·대상 세대 결함을 실제 실행으로 대조한다."""
import json
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='maru-save-queue-adversarial-'))
source = root / 'source'
subprocess.run(['rsync', '-a', '--exclude=.git', '--exclude=.zig-cache', '--exclude=zig-out', '--exclude=node_modules', '--exclude=references', '--exclude=.env*', '--exclude=.codex-worktrees', str(repo)+'/', str(source)+'/'], check=True)
paths = {'queue': source/'src/platform/macos/app_session/editor/save/queue.zig', 'ops': source/'src/session/editor/ops/save_ops.zig'}
originals = {key: path.read_text() for key, path in paths.items()}
cases = [
    ('control', None, None, None),
    ('omit-success-baseline', 'ops', 'return if (before == queued) written else queued;', 'return if (before == queued) queued else @as(?u64, written);'),
    ('inherit-failed-baseline', 'queue', 'if (accepted and outcome.failure == null) {', 'if (true) {'),
    ('join-older-request', 'queue', 'return if (ops.sameRequest(target, prepared.bytes, prepared.expected_disk, entry.target(), entry.prepared.bytes, entry.prepared.expected_disk)) entry.id else null;', 'if (ops.sameRequest(target, prepared.bytes, prepared.expected_disk, entry.target(), entry.prepared.bytes, entry.prepared.expected_disk)) return entry.id;'),
    ('omit-running-cost', 'queue', 'return self.waiting.items.len + @intFromBool(self.running != null);', 'return self.waiting.items.len;'),
    ('ignore-target-epoch', 'ops', 'return self.epoch == current.epoch and self.token.matches(current.token);', 'return self.token.matches(current.token);'),
    ('cap-dynamic-queue', 'queue', 'return init(a, .{ .requests = std.math.maxInt(usize), .bytes = std.math.maxInt(usize) });', 'return init(a, .{ .requests = 32, .bytes = std.math.maxInt(usize) });'),
    ('lose-start-failure', 'queue', '.failure = failure };', '.failure = if (failure == error.OutOfMemory) error.StaleTarget else failure };'),
    ('restored-control', None, None, None),
]
results = []
try:
    for name, key, old, new in cases:
        for target, path in paths.items():
            text = originals[target]
            if target == key:
                assert text.count(old) == 1, (name, text.count(old))
                text = text.replace(old, new, 1)
            path.write_text(text)
        run = subprocess.run(['mise', 'exec', '--', 'zig', 'build', 'test-editor-local-save', '-j4', '--cache-dir', str(root/'cache')], cwd=source, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=300)
        (root/(name+'.log')).write_text(run.stdout)
        if key:
            verified = run.returncode != 0 and ('FAIL (TestUnexpectedResult)' in run.stdout or 'FAIL (TestExpectedEqual)' in run.stdout or 'FAIL (TestExpectedError)' in run.stdout)
        else:
            verified = run.returncode == 0 and 'All 28 tests passed' in run.stdout
        results.append({'case': name, 'mutation': key is not None, 'exit_code': run.returncode, 'verified': verified})
        (root/'results.json').write_text(json.dumps(results, indent=2)+'\n')
        print(name+': '+str(verified), flush=True)
        assert verified, run.stdout[-4000:]
finally:
    for key, path in paths.items():
        path.write_text(originals[key])
print(root/'results.json', flush=True)
