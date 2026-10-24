#!/usr/bin/env python3
"""차용 경로·세대·편집 수·실제 범위·실패 시 게시를 독립 결함으로 공격한다."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--deps', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    if output.exists() or output == repo or repo in output.parents:
        parser.error('Use a new external output')
    source = output/'source'
    source.mkdir(parents=True)
    subprocess.run(['rsync', '-a', '--exclude=.git', '--exclude=.zig-cache', '--exclude=zig-out', '--exclude=node_modules', '--exclude=zig-pkg', '--exclude=references', '--exclude=.env*', str(repo)+'/', str(source)+'/'], check=True)
    (source/'zig-pkg').symlink_to(args.deps.resolve(), target_is_directory=True)
    paths = dict(changes=source/'src/syntax/changes.zig', summary=source/'src/syntax/symbols.zig')
    originals = {key: path.read_text() for key, path in paths.items()}
    cases = [
        ('reuse-disabled', 'summary', 'value.borrow(self.generation, generation, self.edits)', 'if (self.edits > 0) null else value.borrow(self.generation, generation, self.edits)'),
        ('previous-generation', 'changes', 'previous != self.before', '(previous != self.before and false)'),
        ('pending-edit-count', 'changes', 'edits != 1', '(edits != 1 and false)'),
        ('actual-edit-range', 'summary', '            if (self.edited) |r| {', '            if (if (work.reused_changes > 0) null else self.edited) |r| {'),
        ('early-publication', 'summary', '            var before: Nodes = .empty;', '            self.generation = generation;\n            var before: Nodes = .empty;'),
    ]
    def run(label):
        log = output/(label+'.log')
        with log.open('w') as stream:
            code = subprocess.run(['mise', 'exec', '--', 'zig', 'build', 'test-editor-sticky-changes', 'test-editor-sticky-symbols', 'test-editor-fold-changes', 'test-editor-fold-cache', '-j2'], cwd=source, stdout=stream, stderr=subprocess.STDOUT, timeout=600).returncode
        return code, log.read_text()
    def positive(label):
        code, text = run(label)
        if code or text.count('All 6 tests passed.') != 2 or any(f'All {n} tests passed.' not in text for n in (12, 9)):
            raise RuntimeError('Original control failed: '+label)
    positive('control-before')
    results = []
    try:
        for name, key, old, new in cases:
            original = originals[key]
            if original.count(old) != 1:
                raise ValueError('Nonunique mutation anchor: '+name)
            mutated = original.replace(old, new)
            paths[key].write_text(mutated)
            code, text = run(name)
            if not code or 'FAIL (' not in text:
                raise RuntimeError('Mutation survived or did not reach runtime: '+name)
            results.append(dict(hypothesis=name, result='runtime-detected', file=str(paths[key].relative_to(source)), original_sha256=hashlib.sha256(original.encode()).hexdigest(), mutated_sha256=hashlib.sha256(mutated.encode()).hexdigest()))
            paths[key].write_text(original)
            print(name+': runtime-detected', flush=True)
    finally:
        for key, path in paths.items():
            path.write_text(originals[key])
    positive('control-after')
    # 검사에 영향을 주는 제품 파일도 묶어, 다른 checkout의 결과로 오인하지 않게 한다.
    product = {name: hashlib.sha256((source/name).read_bytes()).hexdigest() for name in ('src/syntax/changes.zig', 'src/syntax/folds.zig', 'src/syntax/symbols.zig', 'src/syntax/tree_sitter.zig', 'build.zig')}
    (output/'results.json').write_text(json.dumps(dict(mutations=results, product_sha256=product), indent=2)+'\n')
    print(output/'results.json')


if __name__ == '__main__':
    main()
