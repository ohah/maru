"""합성 반례로 판독기 경계를 검사한다. 제품 실행 증거와 구분한다."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import subprocess
import sys

spec = importlib.util.spec_from_file_location('promotion_summary', Path(__file__).with_name('summarize.py'))
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)
runner = summary.runner


def info():
    sources = {'build.zig': '2' * 64, 'src/example.zig': '3' * 64}
    return dict(
        head='1' * 40, mode=1, comparison_target='provider-edit-attribution', inner_schema=1, inner_target=runner.inner.TARGET,
        inner_scope=runner.inner.SCOPE, inner_stages=list(runner.inner.STAGES), inner_generator_sha256='0' * 64,
        lowering_schema=2, lowering_target='pane-lowering-attribution', lowering_stages=list(runner.inner.lower.STAGES),
        pane_schema=3, pane_summary_execution='retained-ranges',
        promotion_schema=1, promotion_target=runner.TARGET, promotion_scope=runner.SCOPE,
        promotion_stages=list(runner.STAGES), promotion_generator_sha256='0' * 64,
        promotion_source_head='1' * 40, promotion_original_unchanged=True,
        original_sha256=copy.deepcopy(sources), instrumented_sha256=copy.deepcopy(sources),
        promotion_original_sha256=copy.deepcopy(sources), promotion_instrumented_sha256=copy.deepcopy(sources),
        promotion_inputs={name: dict(bytes=8, lf=1, sha256='0' * 64) for name in runner.NAMES},
    )


def log(views=1):
    result = []
    inner_values = dict(resumeParse=1, advanceBrackets=10, promoteFolds=120, lineColorsInto=60,
                        captureQuery=10, captureRoles=10, semanticLayer=1, bracketLayer=10, lineBounds=10, neutralColor=10)
    values = dict(promote=100, query=20, ranges=20, install=50, visible=10, finish=10)
    for key in range(20):
        result.append(f'LOWERING key={key} advanceSyntax={140 * views} syntaxColors={70 * views}')
        fields = ' '.join(f'{name}={inner_values[name] * views} {name}_calls={views}' for name in runner.inner.STAGES)
        result.append(f'INNER key={key} {fields} semanticWork=0 bracketWork={views}')
        fields = ' '.join(f'{name}={values[name] * views} {name}_calls={views}' for name in runner.STAGES)
        result.append(f'FOLD_PROMOTION key={key} {fields} spans={10 * views}')
    return '\n'.join(result) + '\n'


class PromotionValidation(unittest.TestCase):
    def good(self):
        for views, workload in ((1, 'typing'), (2, 'shared')):
            self.assertEqual(len(summary.rows(log(views), workload, info())), 20)

    def rejects(self, text, metadata=None, workload='typing'):
        self.good()
        with self.assertRaises(ValueError):
            summary.rows(text, workload, info() if metadata is None else metadata)
        self.good()

    def test_population_and_field_syntax(self):
        source = log()
        lines = source.splitlines()
        for changed in (
            '\n'.join(lines[:-1]), source + lines[-1] + '\n',
            source.replace('FOLD_PROMOTION key=0 ', 'FOLD_PROMOTION key=1 ', 1),
            source.replace('spans=10', 'spans=10 extra=1', 1),
            source.replace('query=20', 'query=-1', 1),
            source.replace('query=20', 'query=20 query=20', 1),
        ):
            self.rejects(changed)

    def test_scope_and_nonempty_work(self):
        for stage in runner.STAGES:
            for calls in (0, 2):
                self.rejects(log().replace(stage + '_calls=1', stage + '_calls=' + str(calls), 1))
        self.rejects(log().replace('spans=10', 'spans=0', 1))
        self.rejects(log(), workload='shared')
        self.rejects(log(), workload='structure')

    def test_time_hierarchy_and_disjoint_children(self):
        for old, new in (('promote=100', 'promote=121'), ('query=20', 'query=31'),
                         ('ranges=20', 'ranges=31'), ('install=50', 'install=61'),
                         ('visible=10', 'visible=41'), ('finish=10', 'finish=41')):
            self.rejects(log().replace(old, new, 1))

    def test_schema_and_source_contract(self):
        for key, value in (
            ('promotion_schema', True), ('promotion_schema', 2), ('promotion_target', 'other'),
            ('promotion_scope', ''), ('promotion_stages', list(reversed(runner.STAGES))),
            ('promotion_generator_sha256', '0' * 63), ('promotion_source_head', '4' * 40),
            ('promotion_original_unchanged', False), ('promotion_original_unchanged', 1),
        ):
            metadata = info()
            metadata[key] = value
            self.rejects(log(), metadata)
        for edit in (
            lambda d: d['promotion_original_sha256'].pop('build.zig'),
            lambda d: d['promotion_instrumented_sha256'].update({'src/extra.zig': '0' * 64}),
            lambda d: d['promotion_original_sha256'].update({'build.zig': True}),
            lambda d: d['promotion_original_sha256'].update({'src/../escape.zig': '0' * 64}),
            lambda d: d['original_sha256'].update({'build.zig': '9' * 64}),
        ):
            metadata = info()
            edit(metadata)
            self.rejects(log(), metadata)

    def test_recorded_files_and_input_facts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'fixtures').mkdir()
            metadata = info()
            inputs = {}
            for name in runner.NAMES:
                path = root / 'fixtures' / name
                path.write_bytes(b'x\n')
                metadata['promotion_inputs'][name] = dict(bytes=2, lf=1, sha256=runner.sha(path))
                inputs[name] = dict(bytes=2, sha256=runner.sha(path))
            (root / 'inputs.json').write_text(json.dumps(inputs))
            runner.check_inputs(root, metadata)
            path.write_bytes(b'y\n')
            with self.assertRaises(ValueError):
                runner.check_inputs(root, metadata)
            path.write_bytes(b'x\n')
            runner.check_inputs(root, metadata)
            metadata['promotion_inputs'][name]['lf'] = 2
            with self.assertRaises(ValueError):
                runner.check_inputs(root, metadata)
            metadata['promotion_inputs'][name]['lf'] = 1
            runner.check_inputs(root, metadata)
            # JSON의 true가 정수 1과 같게 비교돼도 원래 타입을 잃지 않아야 한다.
            path.write_bytes(b'\n')
            metadata['promotion_inputs'][name] = dict(bytes=1, lf=1, sha256=runner.sha(path))
            inputs[name] = dict(bytes=True, sha256=runner.sha(path))
            (root / 'inputs.json').write_text(json.dumps(inputs))
            with self.assertRaises(ValueError):
                runner.check_inputs(root, metadata)
            inputs[name]['bytes'] = 1
            (root / 'inputs.json').write_text(json.dumps(inputs))
            runner.check_inputs(root, metadata)
            order = []
            for filename in runner.NAMES:
                for workload in ('typing', 'shared'):
                    target = root / f'run-0-1-{filename}-{workload}.log'
                    target.write_text('synthetic unit fixture\n')
                    order.append(dict(log=str(target)))
            (root / 'run-order.json').write_text(json.dumps(order))
            for filename in ('setup-1.json', 'binaries.json', 'promotion-generator.py', 'run-order.stdout'):
                (root / filename).write_text('synthetic unit fixture\n')
            execution = dict(repetitions=1, workloads=['typing', 'shared'], oracle=0)
            runner.record_run_proof(root, 'run', execution)
            summary.check_phase_proof(root, 'run', 1)
            for filename in ('setup-1.json', 'inputs.json', 'binaries.json', 'promotion-generator.py',
                             'run-order.stdout', target.name):
                path = root / filename
                saved = path.read_bytes()
                path.write_bytes(saved + b'changed')
                with self.assertRaises(ValueError):
                    summary.check_phase_proof(root, 'run', 1)
                path.write_bytes(saved)
                summary.check_phase_proof(root, 'run', 1)
            with self.assertRaises(FileExistsError):
                runner.record_run_proof(root, 'run', execution)

    def test_cli_rejects_wrong_models_before_output_creation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            deps = root / 'deps'
            deps.mkdir()
            output = root / 'output'
            common = [sys.executable, str(Path(runner.__file__)), '--output', str(output),
                      '--deps', str(deps), '--fixtures', str(root / 'missing-fixtures')]
            for flags in (['--baseline'], ['--baseline-ref', 'HEAD'], ['--modes', '0'],
                          ['--workloads', 'typing,typing'], ['--prefix', 'verify'],
                          ['--run-only'], ['--refresh'], ['--repetitions', '-1'],
                          ['--delay-ms', '150'], []):
                result = subprocess.run(common + flags, capture_output=True, text=True)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(output.exists())

    def test_codegen_error_union_and_source_drift(self):
        source = (runner.ROOT / runner.HOST).read_text()
        source = runner.inner.enter_function(source, 'promoteFoldRangesToSyntax', 2,
                                             'inner_probe_advance', 'syntax_color.')
        source += '\nfn probeReset() void {\n        lowering_probe_calls = @splat(0);\n}\n'
        source += '\nfn probePrint() void {\n        const live_doc = term.rt.editorDocument().opened.?;\n}\n'
        generated = runner.instrument_host(source)
        self.assertIn('fn rebuildVisible(self: *AppSession, term: *Term) error{OutOfMemory}!void {\n    const promotion_call_start', generated)
        self.assertEqual(generated.count('const ranges = promotion_build:'), 1)
        for damaged in (source.replace('    defer syntax_color.innerProbeFinish(2, inner_start);\n', ''),
                        source + '\npub fn installFoldRanges(x: usize) bool {\n}\n',
                        source.replace('        ranges[i] = .{', '        ranges[i] = wrong;', 1)):
            with self.assertRaises((ValueError, RuntimeError)):
                runner.instrument_host(damaged)


if __name__ == '__main__':
    unittest.main()
