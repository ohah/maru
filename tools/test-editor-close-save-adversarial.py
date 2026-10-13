#!/usr/bin/env python3
"""네이티브 닫기 저장의 완료·dirty·CAS·소비자·대상 세대·후속 저장 결함을 실제 실행으로 검증한다."""
import json
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='maru-close-save-adversarial-'))
source = root / 'source'
subprocess.run(['rsync', '-a', '--exclude=.git', '--exclude=.zig-cache', '--exclude=zig-out', '--exclude=node_modules', '--exclude=references', '--exclude=.env*', '--exclude=.codex-worktrees', str(repo)+'/', str(source)+'/'], check=True)
paths = {'session': source/'src/platform/macos/app_session.zig', 'close': source/'src/platform/macos/app_session/editor/save/close.zig', 'format': source/'src/platform/macos/app_session/editor/format.zig', 'local': source/'src/platform/macos/app_session/editor/local_save.zig'}
originals = {key: path.read_text() for key, path in paths.items()}
cases = [
    ('control', None, None, None),
    ('premature-close', 'close', '.pending => return,', '.pending => { cancel(session); closeSurface(session, state); return; },'),
    ('ignore-dirty', 'close', 'if (editor.isDirty(term)) {', 'if (false and editor.isDirty(term)) {'),
    ('ignore-cas', 'local', 'if (expect_disk) |want| if (want != expected) return error.ExternalConflict;', '_ = expect_disk;'),
    ('lost-consumer-release', 'close', 'if (state.receipt) |value| value.release();', 'if (state.receipt) |value| if (false) value.release();'),
    ('ignore-target-generation', 'close', 'if (!std.meta.eql(actual, state.identity) or term.rt.editorDocument().save_target_epoch != state.epoch) return null;', '_ = actual;'),
    ('ignore-following-save', 'close', 'dispatch.hasPendingDocument(state.identity) or', 'false or'),
    ('lost-pipeline-result', 'format', 'if (@import("save/close.zig").receiptFor(self, term)) |receipt| {', 'if (if (self.total_key_events == std.math.maxInt(u64)) @import("save/close.zig").receiptFor(self, term) else null) |receipt| {'),
    ('notice-cancels-close', 'session', 'if (self.pending_confirm == .editor_save_close) @import("app_session/editor/save/close.zig").cancel(self);', '@import("app_session/editor/save/close.zig").cancel(self);'),
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
        run = subprocess.run(['mise', 'exec', '--', 'zig', 'build', 'test-editor-close-save-async', '-j4', '--cache-dir', str(root/'cache')], cwd=source, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=300)
        (root/(name+'.log')).write_text(run.stdout)
        if key:
            verified = run.returncode != 0 and ('FAIL (TestUnexpectedResult)' in run.stdout or 'FAIL (TestExpectedEqual)' in run.stdout or 'FAIL (TestExpectedError)' in run.stdout or ('error return context:' in run.stdout and 'return error.TestExpectedEqual;' in run.stdout and 'panic:' in run.stdout))
        else:
            verified = run.returncode == 0 and 'All 13 tests passed' in run.stdout
        results.append({'case': name, 'mutation': key is not None, 'exit_code': run.returncode, 'verified': verified})
        (root/'results.json').write_text(json.dumps(results, indent=2)+'\n')
        print(name+': '+str(verified), flush=True)
        assert verified, run.stdout[-4000:]
finally:
    for key, path in paths.items():
        path.write_text(originals[key])
print(root/'results.json', flush=True)
