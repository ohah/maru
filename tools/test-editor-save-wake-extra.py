#!/usr/bin/env python3
"""여러 창·연속 요청·닫기 격리·실패 회복·재진입을 사본에서 추가 검증한다."""
from pathlib import Path
import hashlib
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
output = Path(tempfile.mkdtemp(prefix='maru-save-wake-extra-'))
source = output / 'source'
subprocess.run(['rsync', '-a', '--exclude=.git', '--exclude=.zig-cache', '--exclude=zig-out', '--exclude=node_modules', '--exclude=references', '--exclude=.env*', str(root) + '/', str(source) + '/'], check=True, timeout=120)
print(output, flush=True)
base = 'src/platform/macos/app_session/'
def replace(path, old, new):
    s = path.read_text()
    if s.count(old) != 1: raise ValueError('Non-unique fixture anchor: ' + old)
    path.write_text(s.replace(old, new))
mod = source / (base + 'editor/mod.zig')
mod.write_text(mod.read_text() + '\n' + (root / 'tools/editor-save-wake-extra.zig.inc').read_text())
wake = source / (base + 'editor/save/wake.zig')
replace(wake, '    defer pumping = false;', '    defer pumping = false;\n    if (extra_hook) |hook| hook();')
wake.write_text(wake.read_text() + '''
// 격리 검증용 관측점이며 원본 제품에는 존재하지 않는다.
pub var extra_hook: ?*const fn () void = null;
pub fn extraPumping() bool { return pumping; }
pub fn extraQueued() bool { return queued.load(.acquire); }
''')
replace(source / 'build.zig', '.filters = &.{"SAVEWAKE"},', '.filters = &.{"SAVEWAKEEXTRA"},')
for field in ['tests', 'passed']:
    replace(source / 'build.zig', f'run_save_wake_tests.addArg("--maru-expect-{field}=12")', f'run_save_wake_tests.addArg("--maru-expect-{field}=10")')
paths = [base + 'editor/save/wake.zig', base + 'editor/save/as.zig', base + 'editor/save/dispatch.zig', base + 'editor/save/worker.zig', base + 'editor/save/close.zig', base + 'editor/mod.zig', 'build.zig']
(output / 'provenance.json').write_text(json.dumps(dict(head=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(), original={p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in paths}, fixture=hashlib.sha256((root/'tools/editor-save-wake-extra.zig.inc').read_bytes()).hexdigest()), indent=2))
results=[]
def run(label, expected=True, optimize='Debug'):
    with (output / (label + '.log')).open('w') as log:
        p = subprocess.run(['mise', 'exec', '--', 'zig', 'build', 'test-editor-save-wake', '-j2', '-Doptimize=' + optimize], cwd=source, stdout=log, stderr=subprocess.STDOUT, timeout=600)
    log=(output / (label + '.log')).read_text()
    semantic='FAIL (' in log and any(s in log for s in ['SaveWakeTimedOut','TestUnexpectedResult','TestExpectedEqual'])
    ok=p.returncode == 0 if expected else p.returncode != 0 and semantic
    results.append(dict(name=label, exit=p.returncode, expected_success=expected, semantic_failure=semantic, passed=ok))
    (output/'results.json').write_text(json.dumps(results,indent=2))
    print(label, 'PASS' if ok else 'FAIL',flush=True)
    if not ok: raise SystemExit(str(output))
run('normal')
mutations=[
 ('window-starvation',base+'editor/save/as.zig','    for (operations.items) |op| {\n        if (op.selected == null or op.completed) continue;','    for (operations.items) |op| {\n        if (op.token.origin.window != host.editorSaveWindows()[0].recovered_session_window_generation) continue;\n        if (op.selected == null or op.completed) continue;'),
 ('burst-dropped',base+'editor/save/dispatch.zig','    if (active == null) active = owner_mod.Owner.init(allocator());','    if (requestCount() != 0) return null;\n    if (active == null) active = owner_mod.Owner.init(allocator());'),
 ('close-starvation',base+'editor/save/wake.zig','        const session = host.editorSaveWindows()[i];','        const session = host.editorSaveWindows()[i];\n        if (session.ime_active) return;'),
 ('failure-poisons-baseline',base+'editor/save/dispatch.zig','        owner.ack(accepted) catch unreachable;','        if (outcome.failure != null) entry.lease.owner.get(entry.lease).?.opened.?.disk_hash = 0;\n        owner.ack(accepted) catch unreachable;'),
 ('nested-drain',base+'editor/save/wake.zig','    if (pumping) {\n        request();\n        return;\n    }',''),
]
for label, name, old, new in mutations:
    path=source/name
    original=path.read_bytes()
    try:
        replace(path,old,new)
        run(label,False)
    finally:
        path.write_bytes(original)
        assert path.read_bytes()==original
run('restored')
run('release',optimize='ReleaseFast')
print(output,flush=True)
