#!/usr/bin/env python3
"""별도 진단 바이너리로 native 호출·콜백을 센다. 성능 시간 표본은 만들지 않는다."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

import contract
import prepare

ROOT = Path(__file__).resolve().parents[2]


def sha(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def inventory(root):
    return {str(p.relative_to(root)): sha(p) for p in (root / 'src').rglob('*') if p.is_file()} | {'build.zig': sha(root / 'build.zig')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--deps', type=Path, required=True)
    parser.add_argument('--fixtures', type=Path, required=True)
    args = parser.parse_args()
    output, deps = args.output.resolve(), args.deps.resolve()
    if output == ROOT or ROOT in output.parents or output.exists() or not deps.is_dir():
        parser.error('Use a new path outside the repository and existing dependencies')
    subprocess.run(['git', 'diff', '--exit-code', '--', 'src', 'build.zig', 'build.zig.zon'], cwd=ROOT, check=True)
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    original = inventory(ROOT)
    output.mkdir(parents=True)
    tools = {}
    folders = ('editor-native-parse-measure', 'editor-provider-measure', 'editor-frame-measure',
               'editor-storage-measure', 'editor-fold-product', 'editor-fold-points')
    for folder in folders:
        for path in (ROOT / 'tools' / folder).rglob('*'):
            if not path.is_file() or path.suffix not in ('.py', '.inc'):
                continue
            name = str(path.relative_to(ROOT))
            tools[name] = sha(path)
            target = output / 'tool-snapshot' / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
    fixtures = output / 'fixtures'
    fixtures.mkdir()
    inputs = {}
    for name in sorted(contract.provider.FIXTURES):
        target = fixtures / name
        shutil.copy2(args.fixtures / name, target)
        inputs[name] = dict(bytes=target.stat().st_size, sha256=sha(target))
    (output / 'inputs.json').write_text(json.dumps(inputs, indent=2) + '\n')
    source = prepare.setup(ROOT, output, deps)
    instrumented = inventory(source)
    (output / 'all-source.json').write_text(json.dumps(dict(original=original, instrumented=instrumented), indent=2) + '\n')
    (output / 'tools.json').write_text(json.dumps(tools, indent=2) + '\n')
    setup = json.loads((output / 'setup-1.json').read_text())
    assert setup['head'] == head
    cache = source / '.zig-cache'
    cache.mkdir(exist_ok=True)
    # 빌드 사이에도 이 캐시를 사용 중임을 lsof에서 확인할 수 있게 한다.
    with (cache / 'measurement-active.lock').open('ab'):
        env = {key: value for key, value in os.environ.items() if not key.startswith('MARU_')}
        env.update(MARU_EW2_FILE=str(fixtures / 'flat-3000.zig'), MARU_EW2_WORKLOAD='typing', MARU_EW2_VERIFY_EACH_EDIT='1')
        build_log = output / 'build-1.log'
        print('DIAGNOSTIC_BUILD', flush=True)
        with build_log.open('xb') as stream:
            subprocess.run(['mise', 'exec', '--', 'zig', 'build', 'test-editor-fold-measure', '-Doptimize=ReleaseFast', '-j2', '--verbose'],
                           cwd=source, env=env, stdout=stream, stderr=subprocess.STDOUT, check=True)
        text = build_log.read_text()
        contract.validate(text, 'typing', (fixtures / 'flat-3000.zig').read_bytes(), 'flat-3000.zig', setup)
        paths = re.findall(r'(\./\.zig-cache/o/[0-9a-f]+/test) --maru-expect-tests=5', text)
        if not paths:
            raise ValueError('Missing executed diagnostic binary')
        binary = source / paths[-1]
        digest = sha(binary)
        shutil.copy2(binary, output / 'archived-test')
        assert sha(output / 'archived-test') == digest
        (output / 'binaries.json').write_text(json.dumps({'1': dict(cwd=str(source), binary=str(binary), sha256=digest)}, indent=2) + '\n')
        groups, logs = {}, {}
        for name in sorted(inputs):
            data = (fixtures / name).read_bytes()
            for workload in ('typing', 'shared'):
                assert sha(binary) == digest
                env.update(MARU_EW2_FILE=str(fixtures / name), MARU_EW2_WORKLOAD=workload)
                path = output / f'verify-0-1-{name}-{workload}.log'
                with path.open('xb') as stream:
                    subprocess.run([str(binary), '--maru-expect-tests=5', '--maru-expect-passed=5'],
                                   cwd=source, env=env, stdout=stream, stderr=subprocess.STDOUT, check=True)
                groups[name + '/' + workload] = contract.validate(path.read_text(), workload, data, name, setup)
                logs[path.name] = sha(path)
                print('DIAGNOSTIC_PASS', name, workload, flush=True)
        assert inventory(ROOT) == original and inventory(source) == instrumented
        assert all(sha(ROOT / name) == digest for name, digest in tools.items())
        assert all(sha(fixtures / name) == value['sha256'] for name, value in inputs.items())
        assert sum(map(len, groups.values())) == 200
        (output / 'native-groups.json').write_text(json.dumps(groups, indent=2) + '\n')
        result = dict(complete=True, head=head, kind='diagnostic-only', processes=10, inputs=200,
                      performance_samples=False, source_unchanged=True, binary_sha256=digest,
                      build_log_sha256=sha(build_log), logs=logs, tools=tools)
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print('DIAGNOSTIC_COMPLETE_10_PROCESSES', flush=True)


if __name__ == '__main__':
    main()
