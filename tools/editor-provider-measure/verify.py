#!/usr/bin/env python3
"""다섯 독립 실패 가설에서 실제 측정 기록을 손상하고 원본 전후를 함께 대조한다."""
import argparse
from contextlib import contextmanager
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location('provider_summary', Path(__file__).with_name('summarize.py'))
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)


@contextmanager
def changed(path, raw):
    before = path.read_bytes()
    link = os.readlink(path) if path.is_symlink() else None
    path.unlink()
    path.write_bytes(raw)
    try:
        yield
    finally:
        path.unlink()
        if link is not None:
            path.symlink_to(link)
        else:
            path.write_bytes(before)


def fixture(original, root):
    root.mkdir()
    for name in ('setup-1.json', 'inputs.json', 'binaries.json'):
        shutil.copyfile(original / name, root / name)
    for path in list(original.glob('run-*.log')) + list(original.glob('verify-*.log')):
        shutil.copyfile(path, root / path.name)
    # 큰 바이너리와 소스는 읽기 전용으로 빌리고, 손상시킬 때는 링크부터 끊는다.
    for folder in ('source-1', 'original-product'):
        for name in summary.SOURCES:
            target = root / folder / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.symlink_to(original / folder / name)
    (root / 'source-1' / '.zig-cache').symlink_to(original / 'source-1' / '.zig-cache', target_is_directory=True)
    for name in summary.FIXTURES:
        target = root / 'fixtures' / name
        target.parent.mkdir(exist_ok=True)
        target.symlink_to(original / 'fixtures' / name)
    binaries = summary.load(root / 'binaries.json')
    binaries['1']['cwd'] = str(root / 'source-1')
    (root / 'binaries.json').write_text(json.dumps(binaries))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--repetitions', type=int, default=3)
    parser.add_argument('--receipt', type=Path)
    args = parser.parse_args()
    original = args.root.resolve()
    before = summary.summarize(original, args.repetitions)
    results = []
    with tempfile.TemporaryDirectory(prefix='maru-provider-review-') as temp:
        root = Path(temp) / 'fixture'
        fixture(original, root)
        def positive():
            if summary.summarize(root, args.repetitions) != before:
                raise RuntimeError('Positive control differs')
        def reject(label, action):
            try:
                action()
            except (ValueError, FileNotFoundError):
                results.append(label)
                return
            raise RuntimeError('Corruption accepted: ' + label)
        def bad_text(label, path, text):
            with changed(path, text.encode()):
                reject(label, lambda: summary.summarize(root, args.repetitions))
        def bad_json(label, name, change):
            path = root / name
            value = summary.load(path)
            change(value)
            bad_text(label, path, json.dumps(value))
        log = root / 'run-0-1-flat-3000.zig-shared.log'
        raw = log.read_text()
        first = next(line for line in raw.splitlines() if line.startswith('PROVIDER key=0 '))
        second = next(line for line in raw.splitlines() if line.startswith('PROVIDER key=1 '))
        positive()
        # ① 누락·중복·순서·추가 실행을 빼고 유리한 분모만 남길 수 있는가.
        bad_text('missing-first-input', log, raw.replace(first + '\n', '', 1))
        bad_text('duplicate-input', log, raw.replace(first, first + '\n' + first, 1))
        lines = raw.splitlines()
        a, b = lines.index(first), lines.index(second)
        lines[a], lines[b] = lines[b], lines[a]
        bad_text('reordered-input', log, '\n'.join(lines) + '\n')
        saved = log.with_suffix('.held')
        log.rename(saved)
        try:
            reject('missing-run', lambda: summary.summarize(root, args.repetitions))
        finally:
            saved.rename(log)
        extra = root / 'run-extra.log'
        extra.write_text(raw)
        try:
            reject('extra-run', lambda: summary.summarize(root, args.repetitions))
        finally:
            extra.unlink()
        positive()
        # ② 중첩 시간을 합하거나 호출 일부를 빠뜨려도 그럴듯한 수치로 통과하는가.
        for label, old, new in (
            ('wrong-view-count', 'native_calls=2', 'native_calls=1'),
            ('missing-stage-call', 'reset_calls=2', 'reset_calls=0'),
            ('negative-interval', 'on_edit=', 'on_edit=-'),
        ):
            bad_text(label, log, raw.replace(old, new, 1))
        bad_text('nested-interval', log, raw.replace(first, re.sub(r'changed_ranges=\d+', 'changed_ranges=999999999999', first), 1))
        on_edit = re.search(r'on_edit=(\d+)', first).group(1)
        bad_text('overlapping-exclusive-stages', log, raw.replace(first, re.sub(r'sticky_edit=\d+', 'sticky_edit=' + on_edit, first), 1))
        positive()
        # ③ 성능 실행을 정확성 실행으로 오인하거나 다른 원문·샘플을 섞을 수 있는가.
        verify = root / 'verify-0-1-flat-3000.zig-shared.log'
        bad_text('missing-per-input-oracle', verify, verify.read_text().replace('verified_each_edit=1', 'verified_each_edit=0', 1))
        bad_text('wrong-fixture-control', log, raw.replace('file=flat-3000.zig', 'file=other.zig', 1))
        bad_text('wrong-workload-control', log, raw.replace('work=shared', 'work=typing', 1))
        bad_text('behavior-mismatch', log, raw.replace('mismatch=0', 'mismatch=1', 1))
        bad_text('incomplete-product-control', log, raw.replace('All 5 tests passed.', '', 1))
        bad_text('wrong-product-samples', log, re.sub(r'samples_ns=\d+', 'samples_ns=1', raw, count=1))
        positive()
        # ④ 원본·계측·실행 파일·입력의 증거가 바뀌어도 같은 보고서를 낼 수 있는가.
        for folder, name in [('original-product', 'src/syntax/tree_sitter.zig'), ('source-1', 'src/syntax/tree_sitter.zig'), ('fixtures', 'flat-3000.zig')]:
            path = root / folder / name
            with changed(path, path.read_bytes() + b'\n'):
                reject('changed-' + folder, lambda: summary.summarize(root, args.repetitions))
        bad_json('changed-binary-receipt', 'binaries.json', lambda value: value['1'].update(sha256='0' * 64))
        bad_json('wrong-attribution', 'setup-1.json', lambda value: value.update(comparison_target='fold-points'))
        bad_json('comparison-label-on-attribution', 'setup-1.json', lambda value: value.update(comparison_variant='cursor'))
        bad_json('incomplete-source-provenance', 'setup-1.json', lambda value: value['instrumented_sha256'].pop('src/syntax/tree_sitter.zig'))
        bad_json('boolean-mode', 'setup-1.json', lambda value: value.update(mode=True))
        path = root / 'inputs.json'
        bad_text('duplicate-json-field', path, path.read_text().replace('{', '{"flat-3000.zig":{},', 1))
        positive()
        # ⑤ 도구 합성 과정에서 다른 비교 모드가 몰래 켜지거나 CLI가 유효한 옵션을 무시하는가.
        runner = Path(__file__).with_name('run.py')
        # 필수 인자 누락 때문에 실패하는 빈 검증을 피한다. 실제 준비된 사본을 쓰되 실행은 0회다.
        prepared = ['--output', str(root), '--deps', str(original / 'source-1' / 'zig-pkg'), '--resume', '--run-only', '--repetitions', '0']
        for flags in (['--baseline'], ['--baseline-ref=HEAD'], ['--modes=0'], ['--workloads=paste'], ['--workloads=shared,shared'], ['--prefix=verify'], ['--repetitions=1']):
            result = subprocess.run([sys.executable, str(runner), *prepared, *flags], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode != 2 or 'error:' not in result.stderr:
                raise RuntimeError('Invalid CLI accepted or did not reach argument validation: ' + str(flags))
            results.append('cli-' + ','.join(flags))
        for flags in (['--modes=1', '--workloads=typing'], ['--modes', '1', '--workloads', 'typing,shared']):
            result = subprocess.run([sys.executable, str(runner), *prepared, *flags], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode:
                raise RuntimeError('Valid CLI rejected: ' + str(flags))
        positive()
    if summary.summarize(original, args.repetitions) != before:
        raise RuntimeError('Original artifacts changed')
    receipt = dict(independent_hypotheses=5, rejected=results, positive_controls='before/after every group and original artifacts unchanged', tool_sha256={name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest() for name in ('run.py', 'summarize.py', 'verify.py')})
    if args.receipt:
        args.receipt.write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
