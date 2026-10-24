#!/usr/bin/env python3
"""접힘 좌표의 이진 탐색과 근처 행 힌트를 같은 제품 사본에서 비교 준비한다."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('frame_measure', ROOT / 'tools/editor-frame-measure/run.py')
frame = importlib.util.module_from_spec(spec)
spec.loader.exec_module(frame)
base = frame.base
baseline = '--baseline' in sys.argv
if baseline:
    sys.argv.remove('--baseline')


def setup(repo, output, deps, mode):
    source = frame.setup(repo, output, deps, mode)
    p = source / 'src/syntax/folds.zig'
    text = p.read_text()
    if baseline:
        for name in ('start', 'end'):
            text = base.once(text, f'        var {name}_hint: usize = 0;\n', '')
        text = base.once(text, 'const start = pointNear(lines, r.lo, &start_hint).value;', 'const start = point(lines, r.lo);')
        text = base.once(text, 'const end = pointNear(lines, r.hi, &end_hint).value;', 'const end = point(lines, r.hi);')
    p.write_text(text)
    p = source / 'src/platform/macos/app_session/editor/mod.zig'
    text = p.read_text()
    anchor = '                for (view.rt.editor_lines, 0..) |line, row| try testing.expectEqualStrings(live_doc.file.lineText(row).?, line);'
    text = base.once(text, anchor, anchor + '\n                try expectFoldMarkLookup(view);')
    anchor = '        try testing.expect(try foldMeasureMatches(view, a, &expected));'
    text = base.once(text, anchor, anchor + '\n        try expectFoldMarkLookup(view);')
    p.write_text(text)
    manifest = output / 'setup-1.json'
    info = json.loads(manifest.read_text())
    for name in ('src/syntax/folds.zig', 'src/platform/macos/app_session/editor/mod.zig', 'src/session/editor/fold.zig'):
        info['original_sha256'][name] = hashlib.sha256((repo / name).read_bytes()).hexdigest()
        info['instrumented_sha256'][name] = hashlib.sha256((source / name).read_bytes()).hexdigest()
    info['comparison_target'] = 'fold-points'
    info['comparison_variant'] = 'binary-search' if baseline else 'cursor'
    manifest.write_text(json.dumps(info, indent=2) + '\n')
    return source


if __name__ == '__main__':
    if '--modes' not in sys.argv:
        sys.argv.extend(['--modes', '1'])
    if '--workloads' not in sys.argv:
        sys.argv.extend(['--workloads', 'typing,structure,paste,undo,shared'])
    base.setup = setup
    base.main()
