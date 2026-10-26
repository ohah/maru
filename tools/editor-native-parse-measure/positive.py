#!/usr/bin/env python3
"""계수가 0에 고정되지 않았음을 별도의 실제 C 실행으로 확인한다."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess

import prepare
from run import ROOT, inventory, sha


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--deps', type=Path, required=True)
    args = parser.parse_args()
    output, deps = args.output.resolve(), args.deps.resolve()
    if output.exists() or output == ROOT or ROOT in output.parents or not deps.is_dir():
        parser.error('Use a new directory outside the repository and existing dependencies')
    original = inventory(ROOT)
    output.mkdir(parents=True)
    source = prepare.setup(ROOT, output, deps)
    syntax = source / 'src/syntax/tree_sitter.zig'
    before = syntax.read_text()
    once = prepare.provider.base.once
    text = once(before, '        const cancelled = monotonicNs() >= ctx.deadline_ns;',
                '        const cancelled = native_probe_force_expired or monotonicNs() >= ctx.deadline_ns;')
    syntax.write_text(text + '\npub var native_probe_force_expired: bool = false;\n')
    host = source / 'src/platform/macos/app_session/editor/mod.zig'
    fixture = Path(__file__).with_name('positive.zig.inc')
    host.write_text(host.read_text() + '\n' + fixture.read_text())
    build = source / 'build.zig'
    added = '''    const native_probe_controls = addProjectTest(b, .{ .root_module = editor_tests.root_module, .filters = &.{".test.native probe control "} });
    const run_native_probe_controls = b.addRunArtifact(native_probe_controls);
    run_native_probe_controls.setCwd(b.path("."));
    run_native_probe_controls.has_side_effects = true;
    run_native_probe_controls.addArg("--maru-expect-tests=2");
    run_native_probe_controls.addArg("--maru-expect-passed=2");
    b.step("test-native-probe-positives", "Verify cold parse and positive native counters").dependOn(&run_native_probe_controls.step);
'''
    build.write_text(once(build.read_text(), '    const edit_cost_tests =', added + '    const edit_cost_tests ='))
    observed = inventory(source)
    manifest = output / 'setup-1.json'
    setup = json.loads(manifest.read_text())
    for name in setup['instrumented_sha256']:
        setup['instrumented_sha256'][name] = observed[name]
    setup['native_positive_control'] = 'Separate cold/structural/forced-expiry/resume binary'
    manifest.write_text(json.dumps(setup, indent=2) + '\n')
    proof = dict(original=original, instrumented=observed, force_condition_scope='Only this control binary forces progress expiry; baseline and diagnostic binaries do not',
                 fixture_sha256=sha(fixture), producer_sha256=sha(Path(__file__)))
    (output / 'control-source.json').write_text(json.dumps(proof, indent=2) + '\n')
    shutil.copy2(__file__, output / 'positive.py')
    shutil.copy2(fixture, output / fixture.name)
    cache = source / '.zig-cache'
    cache.mkdir(exist_ok=True)
    with (cache / 'measurement-active.lock').open('ab'):
        log = output / 'build.log'
        with log.open('xb') as stream:
            subprocess.run(['mise', 'exec', '--', 'zig', 'build', 'test-native-probe-positives', '-Doptimize=ReleaseFast', '-j2', '--verbose'],
                           cwd=source, stdout=stream, stderr=subprocess.STDOUT, check=True)
        text = log.read_text()
        # 전용 C 대조 한 개와 editor_judges의 import 검사 한 개다.
        assert 'All 2 tests passed.' in text
        rows = re.findall(r'NATIVE_POSITIVE cold_old=(\d+) cold_reads=(\d+) cold_eof=(\d+) structural_items=(\d+) forced_cancel=(\d+) pending=(\d+) resume_done=(\d+)', text)
        assert len(rows) == 1
        values = tuple(map(int, rows[0]))
        assert values[0] == 0 and min(values[1:5]) > 0 and values[5:] == (1, 1)
        paths = re.findall(r'(\./\.zig-cache/o/[0-9a-f]+/test) --maru-expect-tests=2', text)
        assert paths
        shutil.copy2(source / paths[-1], output / 'archived-test')
        assert inventory(ROOT) == original and inventory(source) == observed
        result = dict(complete=True, controls=dict(zip(('cold_old', 'cold_reads', 'cold_eof', 'structural_items', 'forced_cancel', 'pending', 'resume_done'), values)),
                      log_sha256=sha(log), binary_sha256=sha(output / 'archived-test'), source_sha256=sha(output / 'control-source.json'),
                      scope='Actual C cold/structural/cancel/resume controls; forced expiry is isolated to this binary; no performance samples')
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print('NATIVE_PROBE_POSITIVE_CONTROLS_PASS', values, flush=True)


if __name__ == '__main__':
    main()
