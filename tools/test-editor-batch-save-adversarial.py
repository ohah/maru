#!/usr/bin/env python3
"""배치의 조기 성공·native 패널 누락·소비자 수명·CAS·현재 본문 재시도 결함을 실제 실행으로 검증한다."""
import json
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='maru-batch-save-adversarial-'))
source = root / 'source'
subprocess.run(['rsync', '-a', '--exclude=.git', '--exclude=.zig-cache', '--exclude=zig-out', '--exclude=node_modules', '--exclude=references', '--exclude=.env*', '--exclude=.codex-worktrees', str(repo)+'/', str(source)+'/'], check=True)
paths = {'owner': source/'src/platform/macos/app_session/editor/save/owner.zig', 'dispatch': source/'src/platform/macos/app_session/editor/save/dispatch.zig', 'batch': source/'src/platform/macos/app_session/editor/search/batch.zig', 'local': source/'src/platform/macos/app_session/editor/local_save.zig', 'ui': source/'src/platform/macos/app_session/editor/search/batch/ui.zig', 'coordinator': source/'src/platform/macos/app_session/editor/search/batch/coordinator.zig'}
originals = {key: path.read_text() for key, path in paths.items()}
cases = [
    ('control', None, None, None),
    ('premature-success', 'batch', 'result.saving += 1;', 'result.saved += 1;'),
    ('native-panel-rejected', 'dispatch', '    if (term.file_entry) |entry| if (!entry.native_editor or entry.usesEditorBridge()) return null;\n    return enqueueNative(session, term, null, receipt, false);', '    if (term.file_entry != null) return null;\n    return enqueueNative(session, term, null, receipt, false);'),
    ('lost-request-reference', 'owner', 'if (receipt) |value| value.retain();', 'if (receipt) |value| if (false) value.retain();'),
    ('ignore-external-cas', 'local', 'if (expect_disk) |want| if (want != expected) return error.ExternalConflict;', '_ = expect_disk;'),
    ('retry-old-plan', 'ui', '    const receipt = Receipt.create(self.allocator) catch |err| {', '    const old_after = st.ready.?.prepared.items.items[index].plan.after;\n    var changes = [_]maru.session.editor.delta.Change{.{ .start = 0, .end = term.rt.editorDocument().opened.?.file.content.len, .text = old_after }};\n    _ = @import("../../mod.zig").applyEditAsOneWithUndo(self, term, &changes);\n    const receipt = Receipt.create(self.allocator) catch |err| {'),
    ('duplicate-consumer', 'coordinator', 'try search.batch.validateSaveReceipts(slots);', 'if (false) try search.batch.validateSaveReceipts(slots);'),
    ('stale-sidebar-band', 'coordinator', '@import("../../../sidebar.zig").rebuildSidebar(session) catch {};', '@import("../../../tab.zig").recomputeVisibleTabs(session);'),
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
        run = subprocess.run(['mise', 'exec', '--', 'zig', 'build', 'test-editor-batch-save-async', '-j4', '--cache-dir', str(root/'cache')], cwd=source, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=300)
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
