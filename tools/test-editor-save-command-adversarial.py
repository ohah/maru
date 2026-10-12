#!/usr/bin/env python3
"""사용자 저장의 BOM·동기 저장 순서·알림·닫힌 문서 완료 결함을 실제 실행으로 대조한다."""
import json
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='maru-save-command-adversarial-'))
source = root / 'source'
subprocess.run(['rsync', '-a', '--exclude=.git', '--exclude=.zig-cache', '--exclude=zig-out', '--exclude=node_modules', '--exclude=references', '--exclude=.env*', '--exclude=.codex-worktrees', str(repo)+'/', str(source)+'/'], check=True)
paths = {'queue': source/'src/platform/macos/app_session/editor/save/queue.zig', 'ops': source/'src/session/editor/ops/save_ops.zig', 'local': source/'src/platform/macos/app_session/editor/local_save.zig', 'mod': source/'src/platform/macos/app_session/editor/mod.zig', 'dispatch': source/'src/platform/macos/app_session/editor/save/dispatch.zig', 'format': source/'src/platform/macos/app_session/editor/format.zig'}
originals = {key: path.read_text() for key, path in paths.items()}
cases = [
    ('control', None, None, None),
    ('raw-bom-as-logical', 'local', 'maru.session.editor.save_ops.markSaved(&state.opened.?, self.content());', 'maru.session.editor.save_ops.markSaved(&state.opened.?, self.bytes);'),
    ('skip-sync-barrier', 'mod', '@import("save/dispatch.zig").drainForSynchronousCaller();', 'if (false) @import("save/dispatch.zig").drainForSynchronousCaller();'),
    ('clobber-overlay', 'dispatch', 'if (canAskConflict(view.session)) {', 'if (true) {'),
    ('drop-closed-completion', 'dispatch', '} else accepted = owner.queue.applyRetained(entry.lease, live.?);', '} else accepted = if (false) owner.queue.applyRetained(entry.lease, live.?) else false;'),
    ('early-saved-notice', 'format', 'if (then_save) success_notice = .{ .key = .fmt_stale_saved } else self.showResponseNotice(.fmt_stale, &.{});', 'if (then_save) { success_notice = .{ .key = .fmt_stale_saved }; self.showResponseNotice(.fmt_stale_saved, &.{}); } else self.showResponseNotice(.fmt_stale, &.{});'),
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
