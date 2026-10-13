#!/usr/bin/env python3
"""저장 완료 소비자의 수명·결과 게시 결함을 실제 실행과 정상·복원 대조군으로 검증한다."""
import json
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='maru-save-receipt-adversarial-'))
source = root / 'source'
subprocess.run(['rsync', '-a', '--exclude=.git', '--exclude=.zig-cache', '--exclude=zig-out', '--exclude=node_modules', '--exclude=references', '--exclude=.env*', '--exclude=.codex-worktrees', str(repo)+'/', str(source)+'/'], check=True)
paths = {'owner': source/'src/platform/macos/app_session/editor/save/owner.zig', 'receipt': source/'src/session/editor/ops/save_receipt.zig'}
originals = {key: path.read_text() for key, path in paths.items()}
cases = [
    ('control', None, None, None),
    ('premature-success', 'owner', 'if (receipt) |value| value.retain();', 'if (receipt) |value| { value.retain(); value.complete(null); }'),
    ('lost-request-reference', 'owner', 'if (receipt) |value| value.retain();', 'if (receipt) |value| if (false) value.retain();'),
    ('lost-failure', 'owner', 'value.complete(failure);', '_ = failure; value.complete(null);'),
    ('rejected-ack-publication', 'owner', 'try self.queue.ack(accepted);', 'for (self.references.items) |entry| if (entry.receipt) |value| value.complete(failure);\n        try self.queue.ack(accepted);'),
    ('duplicate-overwrite', 'receipt', 'if (self.result != .pending) return;', 'if (false) return;'),
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
        run = subprocess.run(['mise', 'exec', '--', 'zig', 'build', 'test-editor-save-receipts', '-j4', '--cache-dir', str(root/'cache')], cwd=source, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=300)
        (root/(name+'.log')).write_text(run.stdout)
        if key:
            verified = run.returncode != 0 and ('FAIL (TestUnexpectedResult)' in run.stdout or 'FAIL (TestExpectedEqual)' in run.stdout or 'FAIL (TestExpectedError)' in run.stdout or ('error return context:' in run.stdout and 'return error.TestExpectedEqual;' in run.stdout and 'panic:' in run.stdout))
        else:
            verified = run.returncode == 0 and 'All 9 tests passed' in run.stdout
        results.append({'case': name, 'mutation': key is not None, 'exit_code': run.returncode, 'verified': verified})
        (root/'results.json').write_text(json.dumps(results, indent=2)+'\n')
        print(name+': '+str(verified), flush=True)
        assert verified, run.stdout[-4000:]
finally:
    for key, path in paths.items():
        path.write_text(originals[key])
print(root/'results.json', flush=True)
