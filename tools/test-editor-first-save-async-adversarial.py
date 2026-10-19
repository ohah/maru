#!/usr/bin/env python3
"""첫 저장의 완료·dirty·도크·후속 저장·닫기·배타 생성 보호를 격리 사본에서 검증한다."""
import json
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='maru-first-save-async-adversarial-'))
source = root / 'source'
subprocess.run(['rsync', '-a', '--exclude=.git', '--exclude=.zig-cache', '--exclude=zig-out',
                '--exclude=node_modules', '--exclude=references', '--exclude=.env*', '--exclude=.codex-worktrees',
                str(repo) + '/', str(source) + '/'], check=True)
paths = {key: source / ('src/platform/macos/app_session/editor/' + name) for key, name in
         [('destination', 'save/destination.zig'), ('actor', 'save/as.zig'), ('local', 'local_save.zig')]}
originals = {key: path.read_text() for key, path in paths.items()}
cases = [
    ('control', None, None, None),
    ('ignore-origin', 'destination', 'if (!self.source.matches(live)) return false;', 'if (false and !self.source.matches(live)) return false;'),
    ('redundant-saved-guard-control', 'destination', 'ops.markSaved(&state.opened.?, work.content());', 'ops.markSaved(&state.opened.?, state.opened.?.file.content);'),
    ('mark-current-clean', 'actor', '@import("../backup.zig").markClean(session, term, saved,', '@import("../backup.zig").markClean(session, term, term.rt.editorDocument().opened.?.file.content,'),
    ('drop-entry', 'actor', 'item.created != null and term.file_entry == null', 'item.created != null and false and term.file_entry == null'),
    ('drop-save-again', 'actor', 'op.save_again = true;', 'op.save_again = false;'),
    ('wrong-close-surface', 'actor', '.surface = term.surface.id, .target = target };', '.surface = term.surface.id + 1, .target = target };'),
    ('disable-exclusive-create', 'local', '.{ .exclusive = true }', '.{ .exclusive = false }'),
    ('restored-control', None, None, None),
]
results = []
try:
    for name, key, old, new in cases:
        for role, path in paths.items():
            text = originals[role]
            if role == key:
                assert text.count(old) == 1, (name, text.count(old))
                text = text.replace(old, new, 1)
            if name == 'mark-current-clean' and role == 'destination':
                text = text.replace('ops.markSaved(&state.opened.?, work.content());', 'ops.markSaved(&state.opened.?, state.opened.?.file.content);')
            path.write_text(text)
        run = subprocess.run(['mise', 'exec', '--', 'zig', 'build', 'test-editor-first-save-async', '-j2',
                              '--cache-dir', str(root / 'cache')], cwd=source, capture_output=True, text=True, timeout=300)
        log = run.stdout + run.stderr
        (root / (name + '.log')).write_text(log)
        verified = (run.returncode != 0 and 'FAIL (' in log) if key and name != 'redundant-saved-guard-control' else (run.returncode == 0 and 'All 16 tests passed' in log)
        results.append(dict(case=name, exit_code=run.returncode, verified=verified))
        (root / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(name + ': ' + str(verified), flush=True)
        assert verified, log[-4000:]
finally:
    for key, path in paths.items(): path.write_text(originals[key])
print(root / 'results.json', flush=True)
