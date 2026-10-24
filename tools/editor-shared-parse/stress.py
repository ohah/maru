#!/usr/bin/env python3
"""독립 검증 사본에 다수 뷰 스트레스 판정자를 잠시 붙여 실행한다."""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    source, output = args.source.resolve(), args.output.resolve()
    if source == repo or repo in source.parents or (source/'.git').exists() or output.exists():
        parser.error('Use a private source copy and new external output')
    if output == repo or repo in output.parents:
        parser.error('Keep evidence outside the repository')
    # 같은 사본을 동시에 바꾸는 계측 실행을 허용하지 않는다.
    with (source/'.shared-parse-stress.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        output.mkdir(parents=True)
        paths = [source/'src/platform/macos/app_session/editor/mod.zig', source/'build.zig']
        originals = [p.read_bytes() for p in paths]
        if originals != [(repo/p.relative_to(source)).read_bytes() for p in paths]:
            raise ValueError('Private source differs from current candidate')
        try:
            paths[0].write_bytes(originals[0]+b'\n'+Path(__file__).with_name('stress.zig.inc').read_bytes())
            text = originals[1].decode()
            for field in ('tests', 'passed'):
                old = f'run_parse_reuse_product.addArg("--maru-expect-{field}=7")'
                if text.count(old) != 1:
                    raise ValueError('Changed counted test anchor')
                text = text.replace(old, old.replace('=7', '=8'))
            paths[1].write_text(text)
            for path in paths:
                (output/path.name).write_bytes(path.read_bytes())
            with (output/'run.log').open('w') as stream:
                code = subprocess.run(['mise', 'exec', '--', 'zig', 'build', 'test-editor-shared-parse-product', '-j2'], cwd=source, stdout=stream, stderr=subprocess.STDOUT, timeout=600).returncode
            receipt = dict(returncode=code, scope='Debug coordinator; three views; unrelated=0/128; not GUI/HID', source_sha256={str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths})
            (output/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
            text = (output/'run.log').read_text()
            if code or 'All 8 tests passed.' not in text or any(f'SHARED_PARSE_STRESS views=3 unrelated={n} ' not in text for n in (0, 128)):
                raise RuntimeError('Stress execution failed; see preserved log')
        finally:
            for path, raw in zip(paths, originals):
                path.write_bytes(raw)


if __name__ == '__main__':
    main()
