#!/usr/bin/env python3
"""실제 50프로세스 자료의 격리 사본에서 잘못된 결론을 거절하고 정상 전후를 대조한다."""
import argparse
from contextlib import contextmanager
import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

import verify


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def clone(original, target):
    target.mkdir()
    for name in ('result.json', 'setup-1.json', 'all-source.json', 'inputs.json'):
        shutil.copy2(original / name, target / name)
    for name in ('archived-test', 'build-1.log'):
        (target / name).symlink_to(original / name)
    source = target / 'source-1'
    source.mkdir()
    manifest = verify.load(original / 'all-source.json')
    files = list(manifest['instrumented']) + ['build.zig.zon']
    files += ['original-product/' + name for name in verify.load(original / 'setup-1.json')['original_sha256']]
    for name in files:
        if name.startswith('original-product/'):
            dest, origin = target / name, original / name
        else:
            dest, origin = source / name, original / 'source-1' / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.symlink_to(origin)
    for name in verify.load(original / 'result.json')['tools']:
        dest = target / 'tool-snapshot' / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.symlink_to(original / 'tool-snapshot' / name)
    for name in verify.load(original / 'inputs.json'):
        dest = target / 'fixtures' / name
        dest.parent.mkdir(exist_ok=True)
        dest.symlink_to(original / 'fixtures' / name)
    for prefix in ('run', 'verify'):
        for path in original.glob(prefix + '-*.log'):
            (target / path.name).symlink_to(path)
    binaries = verify.load(original / 'binaries.json')
    binary = binaries['1']
    relative = Path(binary['binary']).relative_to(Path(binary['cwd']))
    binary.update(cwd=str(source), binary=str(source / relative))
    (target / 'binaries.json').write_text(json.dumps(binaries, indent=2) + '\n')


@contextmanager
def changed(path, raw):
    before = path.read_bytes()
    link = os.readlink(path) if path.is_symlink() else None
    path.unlink()
    if raw is not None:
        path.write_bytes(raw)
    try:
        yield
    finally:
        if path.exists() or path.is_symlink():
            path.unlink()
        if link is not None:
            path.symlink_to(link)
        else:
            path.write_bytes(before)


def altered_row(text, prefix, field, value):
    lines = text.splitlines(True)
    matches = [i for i, line in enumerate(lines) if line.startswith(prefix)]
    if len(matches) != 1:
        raise ValueError('Expected exactly one mutation target')
    index = matches[0]
    lines[index], count = re.subn(r'\b' + field + r'=(\d+)', lambda match: field + '=' + str(value), lines[index])
    if count != 1:
        raise ValueError('Expected exactly one counter field')
    return ''.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--diagnostic', type=Path, required=True)
    parser.add_argument('--expected-head', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() or output == verify.ROOT or verify.ROOT in output.parents:
        parser.error('Use a new directory outside the repository')
    baseline, diagnostic = args.baseline.resolve(), args.diagnostic.resolve()
    original = verify.verify_pair(baseline, diagnostic, args.expected_head)
    output.mkdir(parents=True)
    shutil.copy2(__file__, output / 'adversarial.py')
    checks, controls = [], []
    with tempfile.TemporaryDirectory(prefix='disposable-', dir=output) as temp:
        roots = {'baseline': Path(temp) / 'baseline', 'diagnostic': Path(temp) / 'diagnostic'}
        clone(baseline, roots['baseline'])
        clone(diagnostic, roots['diagnostic'])

        def current():
            return verify.verify_pair(roots['baseline'], roots['diagnostic'], args.expected_head)

        def positive(label):
            if current() != original:
                raise RuntimeError('Positive control differs: ' + label)
            controls.append(label)

        def reject(label, expected):
            try:
                current()
            except (ValueError, FileNotFoundError) as error:
                if expected not in str(error):
                    raise RuntimeError('Wrong rejection boundary: ' + label + ': ' + str(error)) from error
                checks.append(dict(label=label, expected=expected, actual=str(error)))
                return
            raise RuntimeError('Corruption accepted: ' + label)

        def metadata(label, kind, name, transform, expected):
            path = roots[kind] / name
            before = path.read_text()
            value = verify.load(path)
            transform(value)
            raw = json.dumps(value, indent=2) + '\n'
            (output / (label + '.patch')).write_text(''.join(difflib.unified_diff(before.splitlines(True), raw.splitlines(True), fromfile=kind + '/' + name, tofile=kind + '/' + name)))
            with changed(path, raw.encode()):
                reject(label, expected)

        def log_case(label, kind, filename, transform, expected):
            path = roots[kind] / filename
            before = path.read_text()
            after = transform(before)
            if before == after:
                raise RuntimeError('Mutation had no effect: ' + label)
            (output / (label + '.patch')).write_text(''.join(difflib.unified_diff(before.splitlines(True), after.splitlines(True), fromfile=filename, tofile=filename)))
            result_path = roots[kind] / 'result.json'
            result = verify.load(result_path)
            result['logs'][filename] = hashlib.sha256(after.encode()).hexdigest()
            # 로그 해시도 맞춰 의미 판정까지 도달시킨다. 원본 자료는 쓰지 않는다.
            with changed(path, after.encode()), changed(result_path, (json.dumps(result) + '\n').encode()):
                reject(label, expected)

        groups = []

        def begin(name):
            positive(name + '-before')
            groups.append(dict(name=name, first=len(checks)))

        def end():
            groups[-1]['cases'] = len(checks) - groups[-1].pop('first')
            positive(groups[-1]['name'] + '-after')
            print(groups[-1]['name'], groups[-1]['cases'], 'REJECTED_WITH_CONTROLS', flush=True)

        raw = 'verify-0-1-flat-3000.zig-typing.log'
        run = 'run-0-1-flat-3000.zig-typing.log'
        shared = 'run-0-1-flat-3000.zig-shared.log'
        begin('population-and-product')
        with changed(roots['diagnostic'] / raw, None):
            reject('missing-execution', 'Missing duplicate or extra raw executions')
        log_case('duplicate-native-key', 'diagnostic', raw, lambda text: text.replace('NATIVE_PROBE schema=1 key=7 ', 'NATIVE_PROBE schema=1 key=6 ', 1), 'Missing duplicate or reordered native keys')
        log_case('oracle-disabled', 'diagnostic', raw, lambda text: text.replace(' verified_each_edit=1 ', ' verified_each_edit=0 ', 1), 'Wrong product control')
        log_case('product-mismatch', 'baseline', run, lambda text: text.replace(' mismatch=0 ', ' mismatch=1 ', 1), 'Wrong product control')
        end()

        begin('schema-and-role')
        metadata('boolean-native-schema', 'diagnostic', 'setup-1.json', lambda value: value.update(native_probe_schema=True), 'Unsupported diagnostic execution schema')
        metadata('float-frame-schema', 'diagnostic', 'setup-1.json', lambda value: value.update(frame_schema=2.0), 'Wrong frame schema')
        metadata('boolean-baseline-schema', 'baseline', 'result.json', lambda value: value.update(baseline_schema=True), 'Wrong baseline schema')
        metadata('diagnostic-as-performance', 'diagnostic', 'result.json', lambda value: value.update(performance_samples=True), 'Diagnostic timings cannot become performance samples')
        metadata('wrong-kind', 'diagnostic', 'result.json', lambda value: value.update(kind='baseline'), 'Wrong source revision or dataset kind')
        end()

        begin('native-call-and-reader')
        prefix = 'NATIVE_PROBE schema=1 key=0 '
        for label, field, value, expected in [
            ('missing-native-call', 'calls', 0, 'Native call coverage'),
            ('extra-old-tree', 'old_tree_calls', 2, 'Native tree or outcome'),
            ('wrong-source-size', 'source_bytes', 1, 'Native source length'),
            ('missing-outcome', 'done', 0, 'Native tree or outcome'),
            ('extra-eof', 'eof_calls', 2, 'EOF calls exceed'),
            ('impossible-byte-offer', 'offered_bytes', 2**64 - 1, 'Offered byte total'),
            ('impossible-cancel', 'cancel_returns', 2**64 - 1, 'Cancellation returns exceed'),
            ('counter-overflow', 'budget_ns', 2**64, 'Native counter exceeds u64'),
        ]:
            log_case(label, 'diagnostic', raw, lambda text, f=field, v=value: altered_row(text, prefix, f, v), expected)
        end()

        begin('timing-and-range-correspondence')
        log_case('native-time-outside-parent', 'baseline', run, lambda text: altered_row(text, 'FRAME key=0 ', 'nativeParse', 10**15), 'Inclusive stage exceeds whole input')
        log_case('wrong-first-range-reuse', 'baseline', shared, lambda text: altered_row(text, 'PROVIDER key=0 ', 'range_reuses', 1), 'Missing calculated or reused ranges')
        log_case('missing-native-ranges', 'diagnostic', raw, lambda text: altered_row(text, prefix, 'range_calls', 0), 'Native changed range coverage')
        log_case('items-without-returned-range', 'diagnostic', raw, lambda text: altered_row(text, prefix, 'range_items', 1), 'Range items without a nonempty call')
        end()

        begin('artifact-and-command-identity')
        for label, kind, name in [('changed-input', 'baseline', 'fixtures/flat-3000.zig'),
                                  ('changed-source', 'diagnostic', 'source-1/src/syntax/tree_sitter.zig'),
                                  ('changed-producer', 'diagnostic', 'tool-snapshot/tools/editor-native-parse-measure/contract.py'),
                                  ('changed-binary', 'diagnostic', 'archived-test')]:
            path = roots[kind] / name
            before = path.read_bytes()
            after = bytes([before[0] ^ 1]) + before[1:]
            (output / (label + '.json')).write_text(json.dumps(dict(path=kind + '/' + name, offset=0, before_byte=before[0], after_byte=after[0], original_sha256=hashlib.sha256(before).hexdigest(), altered_sha256=hashlib.sha256(after).hexdigest()), indent=2) + '\n')
            with changed(path, after):
                reject(label, 'Changed artifact:')
        metadata('wrong-recorded-head', 'baseline', 'result.json', lambda value: value.update(head='0' * 40), 'Wrong source revision')
        result_path = roots['diagnostic'] / 'result.json'
        binary_path = roots['diagnostic'] / 'binaries.json'
        result, binaries = verify.load(result_path), verify.load(binary_path)
        shared_binary = (roots['baseline'] / 'archived-test').read_bytes()
        shared_hash = hashlib.sha256(shared_binary).hexdigest()
        result['binary_sha256'] = shared_hash
        binaries['1']['sha256'] = shared_hash
        # 세 해시를 함께 바꿔도 두 모집단의 실행 파일을 하나로 합칠 수 없어야 한다.
        with changed(roots['diagnostic'] / 'archived-test', shared_binary), changed(result_path, json.dumps(result).encode()), changed(binary_path, json.dumps(binaries).encode()):
            reject('shared-performance-diagnostic-binary', 'Performance and diagnostic binaries must differ')
        setup_path = roots['diagnostic'] / 'setup-1.json'
        with changed(setup_path, ('{"mode":1,' + setup_path.read_text().lstrip()[1:]).encode()):
            reject('duplicate-json-field', 'Duplicate JSON field')
        receipt = Path(temp) / 'existing.json'
        receipt.write_text('preserve')
        command = [sys.executable, str(Path(verify.__file__)), '--baseline', str(roots['baseline']), '--diagnostic', str(roots['diagnostic']), '--expected-head', args.expected_head, '--output', str(receipt)]
        attempt = subprocess.run(command, capture_output=True, text=True)
        if attempt.returncode == 0 or 'Use a new receipt path' not in attempt.stderr or receipt.read_text() != 'preserve':
            raise RuntimeError('Existing receipt was not protected')
        checks.append(dict(label='receipt-overwrite', expected='Use a new receipt path', actual=attempt.stderr.strip()))
        end()
        if len(groups) != 5 or len(controls) != 10:
            raise RuntimeError('Missing adversarial groups or positive controls')
    if verify.verify_pair(baseline, diagnostic, args.expected_head) != original:
        raise RuntimeError('Original data changed')
    result = dict(complete=True, groups=groups, rejected=checks, positive_controls=controls,
                  original_unchanged=True, baseline=str(baseline), diagnostic=str(diagnostic), head=args.expected_head,
                  script_sha256=sha(Path(__file__)), reader_sha256=original['reader_sha256'])
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('FIVE_HYPOTHESES_COMPLETE', len(checks), flush=True)


if __name__ == '__main__':
    main()
