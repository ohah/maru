#!/usr/bin/env python3
"""원시 자료의 격리 사본에 독립 오류를 주입하고 원본 불변을 확인한다."""
import argparse
from contextlib import contextmanager, ExitStack
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import tempfile

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('promotion_review_summary', HERE / 'summarize.py')
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)
runner = summary.runner


@contextmanager
def changed(path, data):
    previous = path.read_bytes()
    link = os.readlink(path) if path.is_symlink() else None
    # 원본을 빌린 링크부터 끊는다. 큰 바이너리의 hard link도 제자리에서 쓰지 않는다.
    path.unlink()
    path.write_bytes(data)
    try:
        yield
    finally:
        path.unlink()
        if link is not None:
            path.symlink_to(link)
        else:
            path.write_bytes(previous)


def fixture(original, root):
    root.mkdir()
    info = runner.load(original / 'setup-1.json')
    for name in ('setup-1.json', 'inputs.json', 'binaries.json', 'promotion-generator.py', 'inner-generator.py'):
        shutil.copyfile(original / name, root / name)
    for prefix in ('run', 'verify'):
        for path in original.glob(prefix + '-*.log'):
            shutil.copyfile(path, root / path.name)
        shutil.copyfile(original / (prefix + '-order.stdout'), root / (prefix + '-order.stdout'))
        order = runner.load(original / (prefix + '-order.json'))
        for row in order:
            row['log'] = str(root / Path(row['log']).name)
        (root / (prefix + '-order.json')).write_text(json.dumps(order))
    for folder, names in (('source-1', info['promotion_instrumented_sha256']),
                          ('original-product', info['original_sha256'])):
        for name in names:
            target = root / folder / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.symlink_to(original / folder / name)
    for name in runner.NAMES:
        target = root / 'fixtures' / name
        target.parent.mkdir(exist_ok=True)
        target.symlink_to(original / 'fixtures' / name)
    binaries = runner.load(root / 'binaries.json')
    old_binary = Path(binaries['1']['binary']).resolve()
    relative = old_binary.relative_to(original / 'source-1')
    binary = root / 'source-1' / relative
    binary.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.link(old_binary, binary)
    except OSError:
        shutil.copyfile(old_binary, binary)
    binaries['1'].update(cwd=str(root / 'source-1'), binary=str(binary))
    (root / 'binaries.json').write_text(json.dumps(binaries))
    for prefix in ('run', 'verify'):
        proof = runner.load(original / ('promotion-' + prefix + '-proof.json'))
        # 운반 경로 두 곳만 재결합한다. 원시 로그·생성기·소스의 증거는 그대로 둔다.
        for name in ('binaries.json', prefix + '-order.json'):
            proof['sha256'][name] = runner.sha(root / name)
        (root / ('promotion-' + prefix + '-proof.json')).write_text(json.dumps(proof))
    return binary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--receipt', type=Path, required=True)
    parser.add_argument('--repetitions', type=int, default=3)
    args = parser.parse_args()
    original, receipt = args.root.resolve(), args.receipt.resolve()
    if receipt.exists() or receipt.is_relative_to(original) or receipt.is_relative_to(runner.ROOT):
        parser.error('Use a new receipt outside the dataset and repository')
    before = summary.summarize(original, args.repetitions)
    groups, rejected = [], []
    with tempfile.TemporaryDirectory(prefix='maru-fold-promotion-review-') as temporary:
        root = (Path(temporary) / 'fixture').resolve()
        binary = fixture(original, root)

        def positive():
            if summary.summarize(root, args.repetitions) != before:
                raise RuntimeError('Transported normal control changed')

        def bad(label, path, data, reason, reseal=True):
            with ExitStack() as stack:
                stack.enter_context(changed(path, data))
                if reseal and path.parent == root:
                    for prefix in ('run', 'verify'):
                        proof_path = root / ('promotion-' + prefix + '-proof.json')
                        proof = runner.load(proof_path)
                        if path.name in proof['sha256']:
                            # 의미 조건은 해시가 맞아도 거절하는지 검사한다.
                            proof['sha256'][path.name] = runner.sha(path)
                            stack.enter_context(changed(proof_path, json.dumps(proof).encode()))
                try:
                    summary.summarize(root, args.repetitions)
                except (ValueError, FileNotFoundError) as error:
                    if reason not in str(error):
                        raise RuntimeError('Rejected for unrelated reason: ' + label + ': ' + str(error)) from error
                    rejected.append(dict(label=label, reason=str(error), digest_resealed=reseal))
                else:
                    raise RuntimeError('Corruption accepted: ' + label)

        def field(text, name, value):
            return re.sub(r'\b' + re.escape(name) + r'=\d+', name + '=' + str(value), text, count=1)

        def group(name, action):
            positive()
            start = len(rejected)
            action()
            positive()
            groups.append(dict(hypothesis=name, rejected=len(rejected) - start,
                               normal_before=True, normal_after=True))

        log = root / 'run-0-1-flat-3000.zig-shared.log'
        raw = log.read_text()
        first, second = [line for line in raw.splitlines() if line.startswith('FOLD_PROMOTION ')][:2]

        def samples():
            bad('missing-input', log, raw.replace(first + '\n', '', 1).encode(), 'promotion inputs')
            bad('duplicate-input', log, raw.replace(first, first + '\n' + first, 1).encode(), 'promotion inputs')
            lines = raw.splitlines()
            a, b = lines.index(first), lines.index(second)
            lines[a], lines[b] = lines[b], lines[a]
            bad('reordered-input', log, ('\n'.join(lines) + '\n').encode(), 'promotion inputs')
        group('sample population and ordering', samples)

        def scope():
            for name in runner.STAGES:
                bad('wrong-calls-' + name, log, raw.replace(first, field(first, name + '_calls', 0), 1).encode(), 'scope/work count')
            bad('missing-work', log, raw.replace(first, field(first, 'spans', 0), 1).encode(), 'scope/work count')
        group('pane scope and nonempty work', scope)

        def times():
            values = dict((key, int(value)) for key, value in re.findall(r'(\w+)=(\d+)', first))
            for label, item, reason in (
                ('parent-overflow', field(first, 'promote', 10**18), 'original INNER parent'),
                ('promotion-overlap', field(field(first, 'query', values['promote'] // 2 + 1), 'ranges', values['promote'] // 2 + 1), 'Promotion children overlap'),
                ('install-overlap', field(field(first, 'visible', values['install'] // 2 + 1), 'finish', values['install'] // 2 + 1), 'Installation children overlap'),
                ('negative-time', field(first, 'query', -1), 'Malformed promotion row'),
            ):
                bad(label, log, raw.replace(first, item, 1).encode(), reason)
        group('inclusive times and disjoint children', times)

        setup = root / 'setup-1.json'
        def models():
            for key, value in (('promotion_schema', True), ('promotion_target', 'other'),
                               ('promotion_stages', list(reversed(runner.STAGES)))):
                info = runner.load(setup)
                info[key] = value
                bad('model-' + key, setup, json.dumps(info).encode(), 'schema/target/stages/scope')
            info = runner.load(setup)
            info['head'] = info['promotion_source_head'] = 'f' * 40
            bad('unknown-source-object', setup, json.dumps(info).encode(), 'source object cannot be archived')
        group('schema and source model', models)

        def provenance():
            bad('unsealed-log', log, (raw + '\n').encode(), 'Changed promotion execution artifact', False)
            generator = root / 'promotion-generator.py'
            bad('generator-bytes', generator, generator.read_bytes() + b'\n', 'generator proof changed', False)
            info = runner.load(setup)
            extra = next(name for name in info['promotion_instrumented_sha256'] if name not in info['instrumented_sha256'])
            source = root / 'source-1' / extra
            bad('source-outside-parent-subset', source, source.read_bytes() + b'\n', 'Prepared source inventory changed')
            info['promotion_original_sha256'][extra] = '0' * 64
            bad('source-object-digest', setup, json.dumps(info).encode(), 'Original source inventory disagrees')
            bad('binary-bytes', binary, binary.read_bytes() + b'x', 'Changed artifact:')
        group('source generator binary and raw evidence', provenance)
    if summary.summarize(original, args.repetitions) != before:
        raise RuntimeError('Original dataset changed')
    proof = dict(target=runner.TARGET, source_head=before['source_head'], groups=groups,
                 rejected=rejected, original_unchanged=True,
                 transport_rebindings=['binary cwd/path', 'execution log paths'],
                 reader_sha256={name: runner.sha(HERE / name) for name in ('run.py', 'summarize.py', 'verify.py')})
    with receipt.open('x') as stream:
        stream.write(json.dumps(proof, indent=2) + '\n')
    print('PASS', len(groups), 'independent hypotheses;', len(rejected), 'corruptions rejected')


if __name__ == '__main__':
    main()
