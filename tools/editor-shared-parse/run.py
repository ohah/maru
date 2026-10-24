#!/usr/bin/env python3
"""실제 선행 제품과 완료 트리 재사용의 같은 입력/도구 전후 사본을 준비한다."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('provider_measure', ROOT/'tools/editor-provider-measure/run.py')
provider = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provider)
raw_original = provider.point.frame.storage.original_setup
legacy = None
REPLACED = ('src/syntax/tree_sitter.zig', 'src/platform/macos/app_session/editor/syntax.zig', 'src/platform/macos/app_session/editor/mod.zig', 'src/session.zig', 'src/session/editor/document_registry.zig', 'build.zig')


def raw_setup(repo, output, deps, mode):
    source = raw_original(repo, output, deps, mode)
    if legacy is None:
        return source
    # 등록만 같은 계측 target을 유지한다. 선행 build의 나머지 설정은 원문 그대로 쓴다.
    built = (source/'build.zig').read_text()
    begin = built.index('    const production_measure =')
    end = built.index('    const edit_cost_tests =', begin)
    target = built[begin:end]
    hashes = {}
    for name in REPLACED:
        raw = subprocess.check_output(['git', 'show', legacy+':'+name], cwd=repo)
        hashes[name] = hashlib.sha256(raw).hexdigest()
        text = raw.decode()
        if name.endswith('/editor/mod.zig'):
            text += '\n'+(repo/'tools/editor-fold-product/host.zig.inc').read_text().replace('EW2_PRODUCT_MODE', str(mode))
        if name == 'build.zig':
            text = provider.base.once(text, '    const edit_cost_tests =', target+'    const edit_cost_tests =')
        (source/name).write_text(text)
    path = output/'setup-1.json'
    info = json.loads(path.read_text())
    info.update(legacy_commit=legacy, legacy_sha256=hashes)
    path.write_text(json.dumps(info,indent=2)+'\n')
    return source


provider.point.frame.storage.original_setup = raw_setup


def setup(repo, output, deps, mode):
    source = provider_setup(repo, output, deps, mode)
    path = output/'setup-1.json'
    info = json.loads(path.read_text())
    if legacy is not None:
        # 추가된 미참조 파일을 근거로 세지 않고 기록할 원본을 실제 선행 커밋에서 읽는다.
        for name in info['original_sha256']:
            raw = subprocess.check_output(['git','show',legacy+':'+name],cwd=repo)
            info['original_sha256'][name] = hashlib.sha256(raw).hexdigest()
            saved = output/'original-product'/name
            saved.parent.mkdir(parents=True,exist_ok=True)
            saved.write_bytes(raw)
    for name in info['instrumented_sha256']:
        info['instrumented_sha256'][name] = hashlib.sha256((source/name).read_bytes()).hexdigest()
    info['shared_parse_variant'] = 'predecessor' if legacy is not None else 'revision-snapshots'
    info['shared_parse_scope'] = 'same pinned inputs; independent parser per view; caller refresh ordering preserved; no GUI/HID/RSS claim'
    path.write_text(json.dumps(info,indent=2)+'\n')
    return source


def main():
    global legacy
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--baseline-ref')
    args, remaining = parser.parse_known_args()
    if args.baseline_ref:
        legacy = subprocess.check_output(['git','rev-parse','--verify','--end-of-options',args.baseline_ref+'^{commit}'],cwd=ROOT,text=True).strip()
    sys.argv = [sys.argv[0],*remaining]
    provider.base.setup = setup
    # 공통 옵션 검증은 같은 진입점을 쓰고, 사본 준비만 선행 버전 wrapper로 바꾼다.
    original = provider.setup
    try:
        provider.setup = setup
        # setup 안에서는 원래 계측 구현을 직접 부른다.
        globals()['provider_setup'] = original
        provider.main()
    finally:
        provider.setup = original


# wrapper의 재귀 호출을 피하도록 고정한다.
provider_setup = provider.setup
if __name__ == '__main__':
    main()
