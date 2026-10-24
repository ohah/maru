#!/usr/bin/env python3
"""제품을 바꾸지 않고 사본의 접힘 조회를 겹치지 않는 여섯 구간으로 측정한다."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('point_measure', ROOT / 'tools/editor-fold-points/run.py')
point = importlib.util.module_from_spec(spec)
spec.loader.exec_module(point)
base = point.base
STAGES = ('changed_ranges', 'records_update', 'sort', 'dedup', 'coordinates_output', 'snapshot')


def setup(repo, output, deps, mode):
    source = point.setup(repo, output, deps, mode)
    p = source / 'src/syntax/folds.zig'
    text = p.read_text()
    # 관측용 전역은 단일 테스트 프로세스 사본에만 존재한다. 제품 API와 저장 상태는 건드리지 않는다.
    text += '\npub var query_probe_ns: [6]i128 = @splat(0);\nfn queryProbeNow() i128 { return std.Io.Clock.awake.now(std.testing.io).nanoseconds; }\n'
    text = base.once(text, '        if (self.tree) |previous| {\n            var count:', '        var query_probe_start = queryProbeNow();\n        if (self.tree) |previous| {\n            var count:')
    anchor = '            const ranges = c.ts_tree_get_changed_ranges(previous, current, &count);'
    if anchor not in text:
        anchor = '            const ranges = if (shared != null) null else c.ts_tree_get_changed_ranges(previous, current, &count);'
    text = base.once(text, anchor, anchor + '\n            query_probe_ns[0] += queryProbeNow() - query_probe_start;\n            query_probe_start = queryProbeNow();')
    anchor = '        std.mem.sort(Record, self.records.items, {}, struct {'
    text = base.once(text, anchor, '        query_probe_ns[1] += queryProbeNow() - query_probe_start;\n        query_probe_start = queryProbeNow();\n' + anchor)
    anchor = '        }.lt);\n        var n: usize = 0;'
    text = base.once(text, anchor, '        }.lt);\n        query_probe_ns[2] += queryProbeNow() - query_probe_start;\n        query_probe_start = queryProbeNow();\n        var n: usize = 0;')
    anchor = '        var start_hint: usize = 0;'
    text = base.once(text, anchor, '        query_probe_ns[3] += queryProbeNow() - query_probe_start;\n        query_probe_start = queryProbeNow();\n' + anchor)
    anchor = '        const next = c.ts_tree_copy(current) orelse return error.OutOfMemory;'
    text = base.once(text, anchor, '        query_probe_ns[4] += queryProbeNow() - query_probe_start;\n        query_probe_start = queryProbeNow();\n' + anchor)
    anchor = '        self.parser = parser;\n'
    text = base.once(text, anchor, anchor + '        query_probe_ns[5] += queryProbeNow() - query_probe_start;\n')
    p.write_text(text)
    p = source / 'src/platform/macos/app_session/editor/mod.zig'
    text = p.read_text()
    text = base.once(text, '        frame_probe_ns = @splat(0);', '        frame_probe_ns = @splat(0);\n        syntax_color.syntax.fold_cache.query_probe_ns = @splat(0);')
    anchor = '        const live_doc = term.rt.editorDocument().opened.?;'
    fields = ' '.join(name + '={d}' for name in STAGES)
    values = ', '.join('syntax_color.syntax.fold_cache.query_probe_ns[' + str(i) + ']' for i in range(6))
    text = base.once(text, anchor, f'        std.debug.print("FOLD_QUERY key={{d}} {fields}\\n", .{{i, {values}}});\n' + anchor)
    p.write_text(text)
    p = source / 'src/syntax/tree_sitter.zig'
    text = p.read_text()
    text = base.once(text, 'const fold_cache = @import("folds.zig");', 'pub const fold_cache = @import("folds.zig");')
    p.write_text(text)
    manifest = output / 'setup-1.json'
    info = json.loads(manifest.read_text())
    for name in ('src/syntax/folds.zig', 'src/syntax/tree_sitter.zig', 'src/platform/macos/app_session/editor/mod.zig'):
        info['instrumented_sha256'][name] = hashlib.sha256((source / name).read_bytes()).hexdigest()
    info['query_stages'] = STAGES
    info['query_scope'] = 'Exclusive success-path intervals; early return/OOM excluded; single-thread fixture only'
    manifest.write_text(json.dumps(info, indent=2) + '\n')
    return source


if __name__ == '__main__':
    if '--modes' not in sys.argv:
        sys.argv.extend(['--modes', '1'])
    base.setup = setup
    base.main()
