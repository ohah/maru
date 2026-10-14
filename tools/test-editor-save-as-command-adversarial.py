#!/usr/bin/env python3
"""실제 Save As 명령 actor의 순서·경로·콜백 경계를 격리 사본과 실제 bytes로 검증한다."""
import json
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='maru-save-as-command-adversarial-'))
source = root / 'source'
subprocess.run(['rsync', '-a', '--exclude=.git', '--exclude=.zig-cache', '--exclude=zig-out', '--exclude=node_modules', '--exclude=references', '--exclude=.env*', '--exclude=.codex-worktrees', str(repo)+'/', str(source)+'/'], check=True)
paths = {'actor': source/'src/platform/macos/app_session/editor/save/as.zig', 'owner': source/'src/platform/macos/app_session/editor/save/owner.zig', 'local': source/'src/platform/macos/app_session/editor/local_save.zig', 'panel': source/'src/platform/macos/app_session/file_panel.zig', 'editor': source/'src/platform/macos/app_session/editor/mod.zig'}
originals = {key: path.read_text() for key, path in paths.items()}
cases = [
    ('control', None, None, None),
    ('drop-deferred-command', 'actor', 'op.save_again = true;', 'op.save_again = false;'),
    ('route-success-to-source', 'actor', 'dispatch.releaseHeld(op.token.id, op.lease, success);', 'dispatch.releaseHeld(op.token.id, op.lease, false);'),
    ('ignore-callback-token', 'actor', 'const op = get(id) orelse return;', 'const op = if (operations.items.len > 0) operations.items[0] else get(id) orelse return;'),
    ('ignore-parent-identity', 'local', 'if (wanted.device != @as(u64, @intCast(stat.dev)) or wanted.inode != @as(u64, @intCast(stat.ino))) return error.ExternalConflict;', 'if (wanted.device != @as(u64, @intCast(stat.dev)) or wanted.inode != @as(u64, @intCast(stat.ino))) {}'),
    ('bypass-held-admission', 'owner', 'const admitted = if (held) |hold|', 'const admitted = if (if (false) held else null) |hold|'),
    ('bypass-panel-reservation', 'panel', 'if (@import("editor/save/as.zig").reservedPath(self, path, null)) {', 'if (false and @import("editor/save/as.zig").reservedPath(self, path, null)) {'),
    ('hardlink-as-ordinary-save', 'actor', 'const relation = aliasRelation(session, op.source_path, file, info) catch .unknown;', 'const relation = if (true) reservations.NamespaceRelation.same else aliasRelation(session, op.source_path, file, info) catch .unknown;'),
    ('equivalent-epoch-parentheses', 'actor', 'state.save_target_epoch == op.source_epoch and', '(state.save_target_epoch == op.source_epoch) and'),
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
            if name == "bypass-panel-reservation" and target == "editor":
                guard = 'if (@import("save/as.zig").reservedPath(self, path, null)) return error.MutationPending;'
                assert text.count(guard) == 1
                text = text.replace(guard, guard.replace("if (", "if (false and "), 1)
            path.write_text(text)
        run = subprocess.run(['mise', 'exec', '--', 'zig', 'build', 'test-editor-save-as-command', '-j4', '--cache-dir', str(root/'cache')], cwd=source, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=300)
        (root/(name+'.log')).write_text(run.stdout)
        equivalent = name.startswith("equivalent-")
        if key and not equivalent:
            verified = run.returncode != 0 and ('FAIL (TestUnexpectedResult)' in run.stdout or 'FAIL (TestExpectedEqual)' in run.stdout or 'FAIL (TestExpectedError)' in run.stdout or ('error return context:' in run.stdout and 'return error.TestExpectedEqual;' in run.stdout and 'panic:' in run.stdout))
        else:
            verified = run.returncode == 0 and 'All 16 tests passed' in run.stdout
        results.append({'case': name, 'mutation': key is not None, 'equivalent': equivalent, 'exit_code': run.returncode, 'verified': verified})
        (root/'results.json').write_text(json.dumps(results, indent=2)+'\n')
        print(name+': '+str(verified), flush=True)
        assert verified, run.stdout[-4000:]
finally:
    for key, path in paths.items():
        path.write_text(originals[key])
print(root/'results.json', flush=True)
