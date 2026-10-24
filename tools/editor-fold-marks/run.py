#!/usr/bin/env python3
"""제품의 순차 표식과 기존 이진 탐색을 같은 관측기로 비교 준비한다."""
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
    p = source / 'src/platform/macos/app_session/editor/mod.zig'
    text = p.read_text()
    if baseline:
        text = base.once(text, '    var mark_cursor: editor_fold.HeadCursor = .{ .ranges = term.rt.editor_fold_ranges, .folded = heads };\n', '')
        text = replace_both(text)
    anchor = '                for (view.rt.editor_lines, 0..) |line, row| try testing.expectEqualStrings(live_doc.file.lineText(row).?, line);'
    text = base.once(text, anchor, anchor + '\n                try expectFoldMarkLookup(view);')
    anchor = '        try testing.expect(try foldMeasureMatches(view, a, &expected));'
    text = base.once(text, anchor, anchor + '\n        try expectFoldMarkLookup(view);')
    p.write_text(text)
    manifest = output / 'setup-1.json'
    info = json.loads(manifest.read_text())
    info['instrumented_sha256']['src/platform/macos/app_session/editor/mod.zig'] = hashlib.sha256(p.read_bytes()).hexdigest()
    info['mark_variant'] = 'binary-search' if baseline else 'cursor'
    name = 'src/session/editor/fold.zig'
    info['original_sha256'][name] = hashlib.sha256((repo / name).read_bytes()).hexdigest()
    info['instrumented_sha256'][name] = hashlib.sha256((source / name).read_bytes()).hexdigest()
    manifest.write_text(json.dumps(info, indent=2) + '\n')
    return source


def replace_both(text):
    old = 'nextFoldMark(&mark_cursor, @intCast(i))'
    if text.count(old) != 2:
        raise RuntimeError('Expected exactly two product mark loops')
    return text.replace(old, 'markFor(term, @intCast(i))')


if __name__ == '__main__':
    if '--modes' not in sys.argv:
        sys.argv.extend(['--modes', '1'])
    if '--workloads' not in sys.argv:
        sys.argv.extend(['--workloads', 'typing,structure,paste,undo,shared'])
    base.setup = setup
    base.main()
