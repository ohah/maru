#!/usr/bin/env python3
"""실제 전후 자료의 순서·종료 상태·선행 소스 증거를 독립 변조한다."""
import argparse
import importlib.util
import json
from pathlib import Path
import tempfile

spec = importlib.util.spec_from_file_location('pair_summary', Path(__file__).with_name('summarize.py'))
pair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pair)
spec = importlib.util.spec_from_file_location('pane_review', pair.ROOT/'tools/editor-pane-measure/verify.py')
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)
review.parent.summary = pair.pane.provider


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--receipt', type=Path, required=True)
    args = parser.parse_args()
    original = args.root.resolve()
    before = pair.summarize(original)
    rejected = []
    with tempfile.TemporaryDirectory(prefix='maru-sticky-pair-review-') as tmp:
        root = Path(tmp).resolve()
        for variant in ('baseline', 'cursor'):
            folder = root/variant
            review.parent.fixture(original/variant, folder)
            for prefix in ('run', 'verify'):
                (folder/f'{prefix}-order.stdout').write_bytes((original/variant/f'{prefix}-order.stdout').read_bytes())
                rows = pair.pane.provider.load(original/variant/f'{prefix}-order.json')
                for row in rows:
                    row['log'] = str(folder/Path(row['log']).name)
                (folder/f'{prefix}-order.json').write_text(json.dumps(rows))
        for prefix in ('run', 'verify'):
            rows = pair.pane.provider.load(original/f'{prefix}-order.json')
            for row in rows:
                row['log'] = str(root/row['variant']/Path(row['log']).name)
            (root/f'{prefix}-order.json').write_text(json.dumps(rows))
        def positive():
            if pair.summarize(root) != before:
                raise RuntimeError('Positive control differs')
        def reject(label, path, mutate):
            value = pair.pane.provider.load(path)
            mutate(value)
            with review.parent.changed(path, json.dumps(value).encode()):
                try:
                    pair.summarize(root)
                except ValueError:
                    rejected.append(label)
                else:
                    raise RuntimeError('Corruption accepted: '+label)
            positive()
        positive()
        order = root/'run-order.json'
        reject('missing-first-execution', order, lambda v: v.pop(0))
        reject('reversed-actual-order', order, lambda v: v.reverse())
        reject('boolean-completion-code', order, lambda v: v[0].update(returncode=False))
        reject('wrong-completion-log', order, lambda v: v[0].update(log='/tmp/not-executed.log'))
        reject('boolean-oracle-mode', order, lambda v: v[0].update(verify_each_edit=False))
        setup = root/'baseline/setup-1.json'
        reject('changed-legacy-source', setup, lambda v: v['legacy_sha256'].update({'src/syntax/tree_sitter.zig': '0'*64}))
        reject('boolean-legacy-commit', setup, lambda v: v.update(legacy_commit=True))
    if pair.summarize(original) != before:
        raise RuntimeError('Original artifacts changed')
    args.receipt.write_text(json.dumps(dict(rejected=rejected, positive_before_after=True), indent=2)+'\n')
    print(rejected)


if __name__ == '__main__':
    main()
