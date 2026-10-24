#!/usr/bin/env python3
"""행 힌트와 표식은 유지하고 변경 범위 재사용만 전후 비교한다."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import subprocess

ROOT = Path(__file__).resolve().parents[2]
diagnostic = '--diagnostic' in sys.argv
if diagnostic:
    sys.argv.remove('--diagnostic')
legacy_ref = None
if '--baseline-ref' in sys.argv:
    index = sys.argv.index('--baseline-ref')
    if index + 1 >= len(sys.argv):
        raise SystemExit('--baseline-ref requires a commit')
    legacy_ref = sys.argv.pop(index + 1)
    sys.argv.pop(index)
if legacy_ref and diagnostic:
    raise SystemExit('Use a separate diagnostic run')
baseline = '--baseline' in sys.argv
if baseline:
    sys.argv.remove('--baseline')
spec = importlib.util.spec_from_file_location('point_measure', ROOT / 'tools/editor-fold-points/run.py')
point = importlib.util.module_from_spec(spec)
spec.loader.exec_module(point)
base = point.base


def setup(repo, output, deps, mode):
    source = point.setup(repo, output, deps, mode)
    p = source / 'src/syntax/tree_sitter.zig'
    text = p.read_text()
    legacy_sources = {}
    legacy_commit = None
    if legacy_ref:
        legacy_commit = subprocess.check_output(['git', 'rev-parse', '--verify', '--end-of-options', legacy_ref + '^{commit}'], cwd=repo, text=True).strip()
        # 선행 제품 소스 자체를 가져오고, 기존 프레임 측정의 nativeParse 타이머만 다시 넣는다.
        for name in ('src/syntax/tree_sitter.zig', 'src/syntax/folds.zig'):
            raw = subprocess.check_output(['git', 'show', legacy_commit + ':' + name], cwd=repo)
            legacy_sources[name] = hashlib.sha256(raw).hexdigest()
            if name.endswith('/folds.zig'):
                (source / name).write_bytes(raw)
            else:
                text = raw.decode()
        call = '        const next = c.ts_parser_parse_with_options(self.parser, old_tree, input, opts);'
        text = base.once(text, call, '        const frame_native_start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;\n' + call + '\n        frame_parse_ns += std.Io.Clock.awake.now(std.testing.io).nanoseconds - frame_native_start;')
        text += '\npub var frame_parse_ns: i128 = 0;\n'
    elif baseline:
        # 저장·대조 코드는 양쪽에 두고 사용 여부만 바꿔 차이를 분리한다.
        text = base.once(text, 'if (self.fold_changes_before) |before_gen|', 'if (@as(?u64, null)) |before_gen|')
    if diagnostic:
        call = '        const ranges = c.ts_tree_get_changed_ranges(old, new, &count);'
        text = base.once(text, call, call + '\n        std.debug.print("FOLD_PROVIDER_CHANGES count={d} before={d}\\n", .{ count, self.tree_gen });')
    p.write_text(text)
    if diagnostic:
        view_path = source / 'src/platform/macos/app_session/editor/mod.zig'
        view = view_path.read_text()
        anchor = '    const initial_nodes = term.rt.editor_syntax.provider.?.stats.fold_nodes;'
        view = base.once(view, anchor, '    const change_initial_reused = term.rt.editor_syntax.folds.reused_changes;\n    const change_initial_compared = term.rt.editor_syntax.folds.compared_changes;\n' + anchor)
        anchor = '        const live_doc = term.rt.editorDocument().opened.?;'
        view = base.once(view, anchor, '        std.debug.print("FOLD_CHANGES key={d} reused={d} compared={d} available={d} generation={d} edits={d}\\n", .{ i, term.rt.editor_syntax.folds.reused_changes - change_initial_reused, term.rt.editor_syntax.folds.compared_changes - change_initial_compared, @intFromBool(term.rt.editor_syntax.provider.?.fold_changes_before != null), term.rt.editor_syntax.provider.?.tree_gen, term.rt.editor_syntax.folds.edits });\n' + anchor)
        view_path.write_text(view)
    manifest = output / 'setup-1.json'
    info = json.loads(manifest.read_text())
    for name in ('src/syntax/folds.zig', 'src/syntax/tree_sitter.zig', 'src/platform/macos/app_session/editor/mod.zig'):
        info['original_sha256'][name] = hashlib.sha256((repo / name).read_bytes()).hexdigest()
        info['instrumented_sha256'][name] = hashlib.sha256((source / name).read_bytes()).hexdigest()
    info['comparison_target'] = 'fold-changes'
    info['comparison_variant'] = 'binary-search' if baseline or legacy_ref else 'cursor'
    info['diagnostic'] = diagnostic
    info['legacy_commit'] = legacy_commit
    info['legacy_sha256'] = legacy_sources
    info['comparison_scope'] = 'Actual predecessor syntax sources versus current product' if legacy_ref else 'Provider range collection is enabled on both sides; only fold-cache reuse differs'
    manifest.write_text(json.dumps(info, indent=2) + '\n')
    return source


if __name__ == '__main__':
    if '--modes' not in sys.argv:
        sys.argv.extend(['--modes', '1'])
    base.setup = setup
    base.main()
