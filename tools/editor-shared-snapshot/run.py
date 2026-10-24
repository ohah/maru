#!/usr/bin/env python3
"""공유 분할 생성·준비·첫 입력을 함께 재서 초기 비용을 숨기지 않는다."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
legacy_ref = None
if '--baseline-ref' in sys.argv:
    index = sys.argv.index('--baseline-ref')
    legacy_ref = sys.argv.pop(index + 1)
    sys.argv.pop(index)
spec = importlib.util.spec_from_file_location('point_measure', ROOT / 'tools/editor-fold-points/run.py')
point = importlib.util.module_from_spec(spec)
spec.loader.exec_module(point)
base = point.base
original_setup = point.frame.storage.original_setup
PRODUCT = ('src/syntax/folds.zig', 'src/syntax/tree_sitter.zig',
           'src/platform/macos/app_session/editor/syntax.zig',
           'src/platform/macos/app_session/editor/mod.zig')


def raw_setup(repo, output, deps, mode):
    source = original_setup(repo, output, deps, mode)
    if legacy_ref:
        commit = subprocess.check_output(['git', 'rev-parse', '--verify', '--end-of-options', legacy_ref + '^{commit}'], cwd=repo, text=True).strip()
        hashes = {}
        for name in PRODUCT:
            raw = subprocess.check_output(['git', 'show', commit + ':' + name], cwd=repo)
            hashes[name] = hashlib.sha256(raw).hexdigest()
            text = raw.decode()
            if name.endswith('/editor/mod.zig'):
                text += '\n' + (repo / 'tools/editor-fold-product/host.zig.inc').read_text().replace('EW2_PRODUCT_MODE', str(mode))
            (source / name).write_text(text)
        manifest = output / 'setup-1.json'
        info = json.loads(manifest.read_text())
        info['legacy_commit'] = commit
        info['legacy_sha256'] = hashes
        manifest.write_text(json.dumps(info, indent=2) + '\n')
    return source


point.frame.storage.original_setup = raw_setup


def setup(repo, output, deps, mode):
    source = point.setup(repo, output, deps, mode)
    path = source / 'src/platform/macos/app_session/editor/mod.zig'
    text = path.read_text()
    start = text.index('test "EW2 fold measure')
    prefix, text = text[:start], text[start:]
    anchor = '    var peer: ?*Term = null;'
    text = base.once(text, anchor, '    const shared_phase_start = frameProbeNow();\n    const shared_phase_parse = syntax_color.syntax.frame_parse_ns;\n    var shared_split_ns: i128 = 0;\n' + anchor)
    anchor = '        try testing.expect(s.runAction("split_editor_right"));'
    text = base.once(text, anchor, '        const shared_split_start = frameProbeNow();\n' + anchor + '\n        shared_split_ns = frameProbeNow() - shared_split_start;')
    ready = '    std.debug.print("FRAME_WARM bracket_ready=1 views='
    text = base.once(text, ready, '    const shared_ready_ns = frameProbeNow() - shared_phase_start;\n' + ready)
    anchor = '    if (std.mem.eql(u8, kind, "folded")) try testing.expect(foldAll(s));'
    text = base.once(text, anchor, '    if (peer) |other| {\n        std.debug.print("SHARED_SPLIT ns={d}\\n", .{shared_split_ns});\n        std.debug.print("SHARED_READY ns={d} native_parse={d} primary_cache={d} peer_cache={d}\\n", .{shared_ready_ns, syntax_color.syntax.frame_parse_ns - shared_phase_parse, @intFromBool(term.rt.editor_syntax.folds.tree != null), @intFromBool(other.rt.editor_syntax.folds.tree != null)});\n    }\n' + anchor)
    path.write_text(prefix + text)
    manifest = output / 'setup-1.json'
    info = json.loads(manifest.read_text())
    for name in PRODUCT:
        info['instrumented_sha256'][name] = hashlib.sha256((source / name).read_bytes()).hexdigest()
    info['comparison_target'] = 'shared-initial-snapshot'
    info['comparison_variant'] = 'binary-search' if legacy_ref else 'cursor'
    info['shared_scope'] = 'split command and both views parse/fold-display/bracket readiness plus all input samples; diagnostic output outside input timers'
    manifest.write_text(json.dumps(info, indent=2) + '\n')
    return source


if __name__ == '__main__':
    if '--modes' not in sys.argv:
        sys.argv.extend(['--modes', '1'])
    if '--workloads' not in sys.argv:
        sys.argv.extend(['--workloads', 'shared'])
    base.setup = setup
    base.main()
