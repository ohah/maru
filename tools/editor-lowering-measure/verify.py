#!/usr/bin/env python3
"""실제 변환 계측 자료에 다섯 독립 실패 가설을 적용하고 원본을 보존한다."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location('lowering_summary', Path(__file__).with_name('summarize.py'))
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)
spec = importlib.util.spec_from_file_location('pane_review', summary.ROOT/'tools/editor-pane-measure/verify.py')
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)
review.parent.summary = summary.pane.provider


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--repetitions', type=int, default=3)
    parser.add_argument('--receipt', type=Path, required=True)
    args = parser.parse_args()
    original = args.root.resolve()
    before = summary.summarize(original, args.repetitions)
    rejected = []
    with tempfile.TemporaryDirectory(prefix='maru-lowering-review-') as tmp:
        root = (Path(tmp)/'fixture').resolve()
        review.parent.fixture(original, root)
        for prefix in ('run', 'verify'):
            (root/f'{prefix}-order.stdout').write_bytes((original/f'{prefix}-order.stdout').read_bytes())
            rows = summary.pane.provider.load(original/f'{prefix}-order.json')
            for row in rows:
                row['log'] = str(root/Path(row['log']).name)
            (root/f'{prefix}-order.json').write_text(json.dumps(rows))
        def positive():
            if summary.summarize(root, args.repetitions) != before:
                raise RuntimeError('Positive control differs')
        def bad(label, path, text):
            with review.parent.changed(path, text.encode()):
                try:
                    summary.summarize(root, args.repetitions)
                except (ValueError, FileNotFoundError):
                    rejected.append(label)
                else:
                    raise RuntimeError('Corruption accepted: '+label)
        log = root/'run-0-1-flat-3000.zig-shared.log'
        raw = log.read_text()
        first, second = [line for line in raw.splitlines() if line.startswith('LOWERING ')][:2]
        def field(text, name, value):
            return re.sub(r'\b'+name+r'=\d+', name+'='+str(value), text, count=1)
        # 표본·실제 실행 순서를 바꾸어 유리한 분모를 만드는 경우.
        positive()
        bad('missing-first', log, raw.replace(first+'\n', '', 1))
        bad('duplicate-input', log, raw.replace(first, first+'\n'+first, 1))
        lines = raw.splitlines()
        left, right = lines.index(first), lines.index(second)
        lines[left], lines[right] = lines[right], lines[left]
        bad('reordered-input', log, '\n'.join(lines)+'\n')
        bad('unknown-lowering-field', log, raw.replace(first, first+' unknown=1', 1))
        order_path = root/'run-order.json'
        order = summary.pane.provider.load(order_path)
        bad('missing-execution', order_path, json.dumps(order[1:]))
        bad('reversed-executions', order_path, json.dumps(order[::-1]))
        order[0]['returncode'] = False
        bad('boolean-execution-status', order_path, json.dumps(order))
        positive()
        # frame 밖 호출을 세거나 중첩 시간을 두 번 더하는 경우.
        for label, name, value in (('negative-time', 'tokens', -1), ('child-exceeds-pane', 'textDrawList', 999999999999)):
            bad(label, log, raw.replace(first, field(first, name, value), 1))
        stages = summary.runner.stage_names(summary.pane.provider.load(root/'setup-1.json'))
        for name in stages:
            bad('wrong-call-count-'+name, log, raw.replace(first, field(first, name+'_calls', 0), 1))
        frame_ns = int(re.search(r'^FRAME key=0 .*?\bappendPaneFrame=(\d+)', raw, re.M).group(1))
        overlap = field(field(first, 'background', frame_ns//2+1), 'textDrawList', frame_ns//2+1)
        bad('root-interval-overlap', log, raw.replace(first, overlap, 1))
        positive()
        # 다른 제품·정확성 실행의 증거를 함께 쓰는 경우.
        verification = root/'verify-0-1-flat-3000.zig-shared.log'
        bad('missing-product-oracle', verification, verification.read_text().replace('verified_each_edit=1', 'verified_each_edit=0', 1))
        marker = 'PANE_ORACLE key=0 views=2 full=1'
        bad('missing-full-sticky-oracle', verification, verification.read_text().replace(marker+'\n', '', 1))
        bad('extra-oracle-in-performance', log, raw+'\n'+marker+'\n')
        bad('product-mismatch', log, raw.replace('mismatch=0', 'mismatch=1', 1))
        bad('parent-sample-mismatch', log, re.sub(r'samples_ns=\d+', 'samples_ns=1', raw, count=1))
        positive()
        # 원본·계측·schema·실행 파일 근거가 달라지는 경우.
        for relative in sorted(summary.runner.EXTRA):
            for folder in ('source-1', 'original-product'):
                path = root/folder/relative
                bad('changed-'+folder+'-'+Path(relative).name, path, path.read_text()+'\n')
        setup = root/'setup-1.json'
        for label, change in (('unknown-schema', lambda v: v.update(lowering_schema=3)), ('boolean-schema', lambda v: v.update(lowering_schema=True)), ('mismatched-schema-stages', lambda v: v.update(lowering_schema=3-v['lowering_schema'])), ('missing-stage', lambda v: v['lowering_stages'].pop()), ('wrong-target', lambda v: v.update(lowering_target='other')), ('wrong-pane-model', lambda v: v.update(pane_summary_execution='own-comparison'))):
            info = summary.pane.provider.load(setup)
            change(info)
            bad(label, setup, json.dumps(info))
        binaries = root/'binaries.json'
        info = summary.pane.provider.load(binaries)
        info['1']['sha256'] = '0'*64
        bad('changed-binary', binaries, json.dumps(info))
        positive()
        # 다른 실행 모델이나 기존 기록의 재준비를 CLI로 우회하는 경우.
        runner = Path(__file__).with_name('run.py')
        prepared = ['--output', str(root), '--deps', str(original/'source-1/zig-pkg'), '--resume', '--run-only', '--repetitions', '0']
        for flags in (['--baseline'], ['--baseline-ref=HEAD'], ['--modes=0'], ['--workloads=paste'], ['--workloads=shared,shared'], ['--prefix=verify'], ['--repetitions=1'], ['--refresh']):
            result = subprocess.run([sys.executable, str(runner), *prepared, *flags], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode != 2 or 'error:' not in result.stderr:
                raise RuntimeError('Invalid CLI accepted: '+str(flags))
            rejected.append('cli-'+','.join(flags))
        result = subprocess.run([sys.executable, str(runner), *[x for x in prepared if x != '--run-only']], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode != 2 or 'Existing measurements require' not in result.stderr:
            raise RuntimeError('Existing source rebuild accepted')
        rejected.append('cli-rebuild-existing-measurement')
        result = subprocess.run([sys.executable, str(runner), *prepared, '--workloads=typing,shared'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode:
            raise RuntimeError('Valid zero-run CLI rejected')
        info = summary.pane.provider.load(setup)
        info['lowering_schema'] = None
        with review.parent.changed(setup, json.dumps(info).encode()):
            result = subprocess.run([sys.executable, str(runner), *prepared], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode != 2 or 'Unknown lowering schema/target' not in result.stderr:
                raise RuntimeError('CLI accepted another measurement schema')
        rejected.append('cli-wrong-measurement-schema')
        positive()
    if summary.summarize(original, args.repetitions) != before:
        raise RuntimeError('Original evidence changed')
    receipt = dict(independent_hypotheses=5, rejected=rejected, positive_controls='before/after every group and unchanged actual artifacts', tool_sha256={name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest() for name in ('run.py', 'summarize.py', 'verify.py')})
    args.receipt.write_text(json.dumps(receipt, indent=2)+'\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
