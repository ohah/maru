#!/usr/bin/env python3
"""실제 pane 자료에 다섯 독립 실패 가설을 적용하고 앞뒤 원본을 대조한다."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location('pane_summary', Path(__file__).with_name('summarize.py'))
pane = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pane)
spec = importlib.util.spec_from_file_location('provider_review', pane.ROOT/'tools/editor-provider-measure/verify.py')
parent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parent)
parent.summary = pane.provider


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--repetitions', type=int, default=3)
    parser.add_argument('--receipt', type=Path, required=True)
    args = parser.parse_args()
    original = args.root.resolve()
    before = pane.summarize(original, args.repetitions)
    results = []
    with tempfile.TemporaryDirectory(prefix='maru-pane-review-') as tmp:
        root = (Path(tmp)/'fixture').resolve()
        parent.fixture(original, root)
        for prefix in ('run', 'verify'):
            (root/f'{prefix}-order.stdout').write_bytes((original/f'{prefix}-order.stdout').read_bytes())
            order = pane.provider.load(original/f'{prefix}-order.json')
            for row in order:
                row['log'] = str(root/Path(row['log']).name)
            (root/f'{prefix}-order.json').write_text(json.dumps(order))
        def positive():
            if pane.summarize(root, args.repetitions) != before:
                raise RuntimeError('Positive control differs')
        def bad(label, path, text):
            with parent.changed(path, text.encode()):
                try:
                    pane.summarize(root, args.repetitions)
                except (ValueError, FileNotFoundError):
                    results.append(label)
                else:
                    raise RuntimeError('Corruption accepted: '+label)
        log = root/'run-0-1-flat-3000.zig-shared.log'
        raw = log.read_text()
        lines = [line for line in raw.splitlines() if line.startswith('PANE ')]
        first, second = lines[:2]
        positive()
        # 표본을 빼거나 바꿔 유리한 분모만 남기는 경우.
        bad('missing-first', log, raw.replace(first+'\n', '', 1))
        bad('duplicate-input', log, raw.replace(first, first+'\n'+first, 1))
        reordered = raw.splitlines()
        left, right = reordered.index(first), reordered.index(second)
        reordered[left], reordered[right] = reordered[right], reordered[left]
        bad('reordered-input', log, '\n'.join(reordered)+'\n')
        bad('unknown-pane-field', log, raw.replace(first, first+' unknown=1', 1))
        order_path = root/'run-order.json'
        order = pane.provider.load(order_path)
        bad('missing-execution-order', order_path, json.dumps(order[1:]))
        bad('reversed-execution-order', order_path, json.dumps(order[::-1]))
        wrong = pane.provider.load(order_path)
        wrong[0]['mode'] = True
        bad('boolean-execution-mode', order_path, json.dumps(wrong))
        stdout = root/'run-order.stdout'
        bad('changed-execution-stdout', stdout, stdout.read_text().replace('typing 0', 'typing 1', 1))
        positive()
        # 시간을 중복 합산하거나 frame 밖 호출을 함께 세는 경우.
        for label, field, value in (('wrong-call-count', 'paneDecorations_calls', '99'), ('child-exceeds-frame', 'sticky', '999999999999'), ('nested-child-overflow', 'guides', '999999999999'), ('negative-time', 'clampScrollToGeometry', '-1')):
            bad(label, log, raw.replace(first, re.sub(r'\b'+field+r'=\d+', field+'='+value, first), 1))
        if pane.provider.load(root/'setup-1.json')['pane_schema'] >= 2:
            bad('sticky-ranges-exceed-summary', log, raw.replace(first, re.sub(r'\bstickyChangedRanges=\d+', 'stickyChangedRanges=999999999999', first), 1))
            bad('sticky-summary-exceeds-parent', log, raw.replace(first, re.sub(r'\bstickySummary=\d+', 'stickySummary=999999999999', first), 1))
        if pane.provider.load(root/'setup-1.json')['pane_schema'] == 3:
            bad('wrong-retained-updates', log, raw.replace(first, re.sub(r'\bstickyReusedChanges=\d+', 'stickyReusedChanges=99', first), 1))
            bad('missing-retained-updates', log, raw.replace(first, re.sub(r' stickyReusedChanges=\d+', '', first), 1))
            bad('wrong-actual-C-calls', log, raw.replace(first, re.sub(r'\bstickyChangedRanges_calls=\d+', 'stickyChangedRanges_calls=99', first), 1))
            if pane.provider.load(root/'setup-1.json')['pane_summary_execution'] == 'retained-ranges':
                bad('C-time-without-C-call', log, raw.replace(first, re.sub(r'\bstickyChangedRanges=\d+', 'stickyChangedRanges=1', first), 1))
        positive()
        # 정확성 실행·상위 제품 표본과 다른 자료를 섞는 경우.
        verification = root/'verify-0-1-flat-3000.zig-shared.log'
        bad('missing-oracle', verification, verification.read_text().replace('verified_each_edit=1', 'verified_each_edit=0', 1))
        if pane.provider.load(root/'setup-1.json')['pane_schema'] == 3:
            oracle_text = verification.read_text()
            marker = 'PANE_ORACLE key=0 views=2 full=1'
            bad('missing-full-sticky-oracle', verification, oracle_text.replace(marker+'\n', '', 1))
            bad('wrong-sticky-oracle-view-count', verification, oracle_text.replace(marker, marker.replace('views=2', 'views=1'), 1))
            bad('extra-oracle-in-performance', log, raw+'\n'+marker+'\n')
        bad('product-mismatch', log, raw.replace('mismatch=0', 'mismatch=1', 1))
        bad('parent-sample-mismatch', log, re.sub(r'samples_ns=\d+', 'samples_ns=1', raw, count=1))
        positive()
        # 원본·계측·schema·실행 파일 근거가 바뀌는 경우.
        info = pane.provider.load(root/'setup-1.json')
        for relative in sorted(pane.source_names(info)-pane.original_names(info)):
            for folder in ('source-1', 'original-product'):
                path = root/folder/relative
                bad('changed-'+folder+'-'+Path(relative).name, path, path.read_text()+'\n')
        setup = root/'setup-1.json'
        for label, change in (('unknown-schema', lambda v: v.update(pane_schema=4)), ('boolean-schema', lambda v: v.update(pane_schema=True)), ('missing-stage', lambda v: v['pane_stages'].pop())):
            value = pane.provider.load(setup)
            change(value)
            bad(label, setup, json.dumps(value))
        if info['pane_schema'] == 3:
            value = pane.provider.load(setup)
            value['pane_summary_execution'] = 'unknown'
            bad('unknown-summary-execution', setup, json.dumps(value))
        binary = root/'binaries.json'
        value = pane.provider.load(binary)
        value['1']['sha256'] = '0'*64
        bad('changed-binary', binary, json.dumps(value))
        positive()
        # CLI 합성에서 다른 비교 모드나 잘못된 실행을 받아들이는 경우.
        prepared = ['--output', str(root), '--deps', str(original/'source-1/zig-pkg'), '--resume', '--run-only', '--repetitions', '0']
        runner = Path(__file__).with_name('run.py')
        for flags in (['--baseline'], ['--baseline-ref=HEAD'], ['--modes=0'], ['--workloads=paste'], ['--workloads=shared,shared'], ['--prefix=verify'], ['--repetitions=1'], ['--refresh']):
            result = subprocess.run([sys.executable, str(runner), *prepared, *flags], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode != 2 or 'error:' not in result.stderr:
                raise RuntimeError('Invalid CLI accepted or no argument validation: '+str(flags))
            results.append('cli-'+','.join(flags))
        no_run_only = [flag for flag in prepared if flag != '--run-only']
        result = subprocess.run([sys.executable, str(runner), *no_run_only], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode != 2 or 'Existing measurements require' not in result.stderr:
            raise RuntimeError('Existing measurement rebuild was not rejected')
        results.append('cli-rebuild-existing-measurement')
        result = subprocess.run([sys.executable, str(runner), *prepared, '--workloads=typing,shared'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode:
            raise RuntimeError('Valid CLI rejected')
        positive()
    if pane.summarize(original, args.repetitions) != before:
        raise RuntimeError('Original evidence changed')
    receipt = dict(independent_hypotheses=5, rejected=results, positive_controls='before/after each group and unchanged original', tool_sha256={name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest() for name in ('run.py', 'summarize.py', 'verify.py')})
    args.receipt.write_text(json.dumps(receipt, indent=2)+'\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
