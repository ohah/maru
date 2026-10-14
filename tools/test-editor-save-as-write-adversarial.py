#!/usr/bin/env python3
"""새 대상 쓰기·모델 전환의 실패 경계를 격리 사본과 실제 bytes로 검증한다."""
import json
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='maru-save-as-write-adversarial-'))
source = root / 'source'
subprocess.run(['rsync', '-a', '--exclude=.git', '--exclude=.zig-cache', '--exclude=zig-out', '--exclude=node_modules', '--exclude=references', '--exclude=.env*', '--exclude=.codex-worktrees', str(repo)+'/', str(source)+'/'], check=True)
paths = {'destination': source/'src/platform/macos/app_session/editor/save/destination.zig', 'local': source/'src/platform/macos/app_session/editor/local_save.zig'}
originals = {key: path.read_text() for key, path in paths.items()}
cases = [
    ('control', None, None, None),
    ('premature-adopt', 'destination', 'self.adopted or !work.written or work.finished', 'self.adopted or work.finished'),
    ('ignore-origin', 'destination', 'if (!self.source.matches(live)) return false;', 'if (!self.source.matches(live) and self.adopted) return false;'),
    ('ignore-epoch', 'destination', 'const live: ops.Target = .{ .epoch = state.save_target_epoch', 'const live: ops.Target = .{ .epoch = self.source.epoch'),
    ('ignore-destination-cas', 'local', 'if (expect_disk) |want| if (want != expected) return error.ExternalConflict;', '_ = expect_disk;'),
    ('ignore-exclusive-create', 'local', '.{ .exclusive = true }', '.{ .exclusive = false }'),
    ('mark-current-clean', 'destination', 'ops.markSaved(&state.opened.?, work.content());', 'ops.markSaved(&state.opened.?, state.opened.?.file.content);'),
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
        run = subprocess.run(['mise', 'exec', '--', 'zig', 'build', 'test-editor-save-as-write', '-j4', '--cache-dir', str(root/'cache')], cwd=source, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=300)
        (root/(name+'.log')).write_text(run.stdout)
        if key:
            verified = run.returncode != 0 and ('FAIL (TestUnexpectedResult)' in run.stdout or 'FAIL (TestExpectedEqual)' in run.stdout or 'FAIL (TestExpectedError)' in run.stdout or ('error return context:' in run.stdout and 'return error.TestExpectedEqual;' in run.stdout and 'panic:' in run.stdout))
        else:
            verified = run.returncode == 0 and 'All 10 tests passed' in run.stdout
        results.append({'case': name, 'mutation': key is not None, 'exit_code': run.returncode, 'verified': verified})
        (root/'results.json').write_text(json.dumps(results, indent=2)+'\n')
        print(name+': '+str(verified), flush=True)
        assert verified, run.stdout[-4000:]
finally:
    for key, path in paths.items():
        path.write_text(originals[key])
print(root/'results.json', flush=True)
