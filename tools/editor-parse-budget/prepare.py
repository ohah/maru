"""제품은 그대로 두고 기존 경계 타이머가 있는 실험 사본을 만든다."""
import hashlib
import importlib.util
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('budget_provider', ROOT / 'tools/editor-provider-measure/run.py')
provider = importlib.util.module_from_spec(spec)
saved = sys.argv
try:
    sys.argv = saved[:1]
    spec.loader.exec_module(provider)
finally:
    sys.argv = saved


def setup(output, deps):
    source = provider.setup(ROOT, output, deps, 1)
    path = source / 'src/syntax/tree_sitter.zig'
    text = path.read_text()
    # 실제 C 반환을 별도로 보존한다. progress 콜백을 추가하거나 만료를 강제하지 않는다.
    anchor = '        const next = c.ts_parser_parse_with_options(self.parser, old_tree, input, opts);'
    text = provider.base.once(text, anchor, anchor + '\n        budget_probe_done = next != null;')
    text += '\npub var budget_probe_done: bool = false;\n' + Path(__file__).with_name('probe.zig.inc').read_text()
    path.write_text(text)
    path = source / 'src/platform/macos/app_session/editor/syntax.zig'
    path.write_text(path.read_text() + '\n' + Path(__file__).with_name('state.zig.inc').read_text())
    build = source / 'build.zig'
    added = '''    const budget_measure = addProjectTest(b, .{ .root_module = syntax_mod, .filters = &.{".test.budget measure "} });
    const run_budget_measure = b.addRunArtifact(budget_measure);
    run_budget_measure.has_side_effects = true;
    run_budget_measure.addArg("--maru-expect-tests=4");
    run_budget_measure.addArg("--maru-expect-passed=4");
    b.step("test-native-budget-measure", "Measure incremental parser slices").dependOn(&run_budget_measure.step);
    const budget_state = addProjectTest(b, .{ .root_module = editor_tests.root_module, .filters = &.{".test.budget state contract "} });
    const run_budget_state = b.addRunArtifact(budget_state);
    run_budget_state.has_side_effects = true;
    run_budget_state.addArg("--maru-expect-tests=2");
    run_budget_state.addArg("--maru-expect-passed=2");
    b.step("test-native-budget-state", "Check existing pending syntax ownership contracts").dependOn(&run_budget_state.step);
'''
    build.write_text(provider.base.once(build.read_text(), '    const syntax_tests =', added + '    const syntax_tests ='))
    return source
