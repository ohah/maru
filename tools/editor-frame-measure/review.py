#!/usr/bin/env python3
"""집계 결함을 메모리 사본에 주입해 독립 검출과 원본 대조군을 기록한다."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import sys
import types
import unittest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    folder = Path(__file__).resolve().parent
    original = (folder / 'summarize.py').read_text()
    tests = (folder / 'test_summary.py').read_text()
    output = args.output.resolve()
    if output.exists() or folder.parents[1] in output.parents:
        parser.error('Use a new directory outside the repository')
    output.mkdir(parents=True)
    cases = [
        ('key-correspondence', "if [r['key'] for r in records] != list(range(len(original))):", 'if False:'),
        ('disjoint-intervals', "if record['edit_ns'] + record['appendPaneFrame'] > total:", 'if False:'),
        ('frame-child-bound', "if any(record[name] > record['appendPaneFrame'] for name in ('advanceSyntax', 'syntaxColors', 'minimapSide', 'buildPaneOps')):", 'if False:'),
        ('edit-child-bound', "if record['refreshViewAfterEditImpl'] > record['edit_ns']:", 'if False:'),
        ('inclusive-double-count', "if any(record[name] > total for name in FIELDS):", 'if sum(record[name] for name in FIELDS) > total:'),
    ]

    def run(name, source):
        module = types.ModuleType('summarize')
        module.__file__ = str(folder / 'summarize.py')
        exec(compile(source, module.__file__, 'exec'), module.__dict__)
        sys.modules['summarize'] = module
        test_module = types.ModuleType('frame_attack_tests')
        exec(compile(tests, str(folder / 'test_summary.py'), 'exec'), test_module.__dict__)
        stream = io.StringIO()
        result = unittest.TextTestRunner(stream=stream, verbosity=2).run(unittest.defaultTestLoader.loadTestsFromModule(test_module))
        (output / (name + '.log')).write_text(stream.getvalue())
        return result

    control = run('control-before', original)
    if not control.wasSuccessful() or control.testsRun != 7:
        raise RuntimeError('Original control failed')
    results = []
    for name, old, new in cases:
        if original.count(old) != 1:
            raise RuntimeError('Ambiguous mutation anchor: ' + name)
        mutated = original.replace(old, new)
        result = run(name, mutated)
        if result.wasSuccessful() or result.errors:
            raise RuntimeError('Mutation survived or did not execute: ' + name)
        results.append(dict(hypothesis=name, result='runtime-detected', original_sha256=hashlib.sha256(original.encode()).hexdigest(), mutated_sha256=hashlib.sha256(mutated.encode()).hexdigest()))
    if not run('control-after', original).wasSuccessful():
        raise RuntimeError('Final control failed')
    (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(output / 'results.json')


if __name__ == '__main__':
    main()
