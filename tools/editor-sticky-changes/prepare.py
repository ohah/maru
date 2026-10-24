#!/usr/bin/env python3
"""동일 pane 계측으로 실제 선행 커밋과 차용 후보의 외부 사본을 준비한다."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('pane_measure', ROOT/'tools/editor-pane-measure/run.py')
pane = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pane)
raw_original = pane.provider.point.frame.storage.original_setup
pane_original = pane.setup
legacy = None
REPLACED = ('src/syntax/tree_sitter.zig', 'src/syntax/folds.zig', 'src/syntax/symbols.zig', 'build.zig')


def git_bytes(repo, name):
    return subprocess.check_output(['git', 'show', legacy+':'+name], cwd=repo)


def raw_setup(repo, output, deps, mode):
    source = raw_original(repo, output, deps, mode)
    if legacy is None:
        return source
    # 계측 target만 같은 등록으로 넣고 나머지는 실제 선행 build 원문을 사용한다.
    built = (source/'build.zig').read_text()
    first = built.index('    const production_measure =')
    last = built.index('    const edit_cost_tests =', first)
    target = built[first:last]
    hashes = {}
    for name in REPLACED:
        raw = git_bytes(repo, name)
        hashes[name] = hashlib.sha256(raw).hexdigest()
        text = raw.decode()
        if name == 'build.zig':
            text = pane.provider.base.once(text, '    const edit_cost_tests =', target+'    const edit_cost_tests =')
        (source/name).write_text(text)
    path = output/'setup-1.json'
    info = json.loads(path.read_text())
    info.update(legacy_commit=legacy, legacy_sha256=hashes)
    path.write_text(json.dumps(info, indent=2)+'\n')
    return source


def setup(repo, output, deps, mode):
    source = pane_original(repo, output, deps, mode)
    path = output/'setup-1.json'
    info = json.loads(path.read_text())
    if legacy is not None:
        for name in info['original_sha256']:
            raw = git_bytes(repo, name)
            info['original_sha256'][name] = hashlib.sha256(raw).hexdigest()
            (output/'original-product'/name).write_bytes(raw)
    # 선행 build를 교체한 뒤의 실제 사본을 기록한다. 공통 준비 단계의 이전 해시를 남기지 않는다.
    for name in info['instrumented_sha256']:
        info['instrumented_sha256'][name] = hashlib.sha256((source/name).read_bytes()).hexdigest()
    info['sticky_changes_variant'] = 'predecessor' if legacy is not None else 'retained-ranges'
    path.write_text(json.dumps(info, indent=2)+'\n')
    return source


def main():
    global legacy
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--baseline-ref')
    args, remaining = parser.parse_known_args()
    if args.baseline_ref:
        legacy = subprocess.check_output(['git', 'rev-parse', '--verify', '--end-of-options', args.baseline_ref+'^{commit}'], cwd=ROOT, text=True).strip()
        pane.original_bytes = git_bytes
    sys.argv = [sys.argv[0], *remaining]
    pane.provider.point.frame.storage.original_setup = raw_setup
    pane.setup = setup
    pane.main()


if __name__ == '__main__':
    main()
