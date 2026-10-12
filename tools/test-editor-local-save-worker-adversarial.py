#!/usr/bin/env python3
"""저장 worker의 게시 순서·오류·bytes·단계·완료 대상을 실제 실행으로 대조한다."""
import json
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='maru-save-worker-adversarial-'))
source = root / 'source'
subprocess.run(['rsync', '-a', '--exclude=.git', '--exclude=.zig-cache', '--exclude=zig-out', '--exclude=node_modules', '--exclude=references', '--exclude=.env*', '--exclude=.codex-worktrees', str(repo)+'/', str(source)+'/'], check=True)
paths = {'worker': source/'src/platform/macos/app_session/editor/save/worker.zig', 'local': source/'src/platform/macos/app_session/editor/local_save.zig'}
originals = {key: path.read_text() for key, path in paths.items()}
cases = [
    ('control', None, None, None),
    ('publish-before-write', 'worker', '        if (builtin.is_test) if (self.gate) |gate| gate.wait();', '        self.done.store(true, .release);\n        if (builtin.is_test) if (self.gate) |gate| gate.wait();'),
    ('discard-write-error', 'worker', 'self.failure = err;', 'self.failure = if (err == error.ExternalConflict) null else err;'),
    ('write-logical-instead-of-raw', 'local', 'try writeBytes(io, self.path, self.bytes, self.expected_disk);', 'try writeBytes(io, self.path, self.content(), self.expected_disk);'),
    ('restart-completed-material', 'worker', 'if (!save_ops.writable(prepared.written, prepared.finished)) return error.InvalidPhase;', 'if (false and !save_ops.writable(prepared.written, prepared.finished)) return error.InvalidPhase;'),
    ('finish-wrong-target', 'local', 'if (!self.matches(term)) return false;', 'if (false and !self.matches(term)) return false;'),
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
            verified = run.returncode == 0 and 'All 11 tests passed' in run.stdout
        results.append({'case': name, 'mutation': key is not None, 'exit_code': run.returncode, 'verified': verified})
        (root/'results.json').write_text(json.dumps(results, indent=2)+'\n')
        print(name+': '+str(verified), flush=True)
        assert verified, run.stdout[-4000:]
finally:
    for key, path in paths.items():
        path.write_text(originals[key])
print(root/'results.json', flush=True)
