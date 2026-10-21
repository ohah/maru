#!/usr/bin/env python3
"""Compile five real sidebar publication defects in an isolated source copy."""
import json
import pathlib
import shutil
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parents[1]
out = pathlib.Path(tempfile.mkdtemp(prefix='maru-sidebar-mutants-', dir='/tmp'))
shutil.copytree(repo / 'src', out / 'src')
(out / 'src/judge.zig').write_text('test { @import("std").testing.refAllDecls(@import("chrome/components/sidebar/published.zig")); }\n')
p = out / 'src/chrome/components/sidebar/published.zig'
original = p.read_text()
variants = [
    ('baseline', None, None, True),
    ('ignore-viewport-clip', 'layout.intersectRect(entry.rect, c)', 'layout.intersectRect(entry.rect, if (c.width >= 0) entry.rect else c)', False),
    ('wrong-scroll', 'p.header, p.metrics, p.scroll)', 'p.header, p.metrics, 0)', False),
    ('wrong-group-parent', 'parent = groups[c.depth] orelse 0;', 'parent = 0;', False),
    ('reuse-model-epoch', 'std.hash.Wyhash.init(model_epoch)', 'std.hash.Wyhash.init(model_epoch -% model_epoch)', False),
    ('keep-failed-publication', 'self.invalidate();\n            return err;', 'return err;', False),
    ('equivalent-coordinate', '.x = 0, .y = @floatFromInt(top)', '.x = 0 + 0, .y = @floatFromInt(top)', True),
    ('restored', None, None, True),
]
results = []
for name, before, after, passes in variants:
    if before is not None:
        assert before in original, name
    p.write_text(original if before is None else original.replace(before, after))
    command = ['mise', 'exec', '--', 'zig', 'test', '--dep', 'type_info_fields', '--dep', 'array_repeat',
               f'-Mroot={out}/src/judge.zig', f'-Mtype_info_fields={repo}/src/compat/type_info_fields.zig',
               f'-Marray_repeat={repo}/src/compat/array_repeat.zig', '--test-filter', 'sidebar']
    r = subprocess.run(command, cwd=repo, capture_output=True, text=True)
    log = r.stdout + r.stderr
    (out / f'{name}.log').write_text(log)
    ok = r.returncode == 0 if passes else r.returncode != 0 and ('TestUnexpectedResult' in log or 'TestExpectedEqual' in log) and 'compilation errors' not in log
    results.append(dict(name=name, passed=ok, expected_pass=passes, returncode=r.returncode))
    (out / 'manifest.json').write_text(json.dumps(dict(passed=all(v['passed'] for v in results), results=results), indent=2))
    print(name, 'PASS' if ok else 'FAIL', flush=True)
    if not ok:
        print(log[-2000:])
        raise SystemExit(1)
print(out / 'manifest.json')
