#!/usr/bin/env python3
"""추가 콜백 계수 없이 기존 Provider 실측을 재현하고 바이너리를 보존한다."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def inventory(root):
    return {str(p.relative_to(root)): sha(p) for p in (root / 'src').rglob('*') if p.is_file()} | {'build.zig': sha(root / 'build.zig')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--deps', type=Path, required=True)
    parser.add_argument('--fixtures', type=Path, required=True)
    args = parser.parse_args()
    output, deps = args.output.resolve(), args.deps.resolve()
    if output.exists() or output == ROOT or ROOT in output.parents or not deps.is_dir():
        parser.error('Use a new path outside the repository and existing dependencies')
    if subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=all', '--', 'src', 'build.zig', 'build.zig.zon'], cwd=ROOT, text=True).strip():
        parser.error('Product source must match the recorded Git commit')
    spec = importlib.util.spec_from_file_location('native_baseline_provider', ROOT / 'tools/editor-provider-measure/run.py')
    producer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(producer)
    spec = importlib.util.spec_from_file_location('native_baseline_summary', ROOT / 'tools/editor-provider-measure/summarize.py')
    reader = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(reader)
    if any(not (args.fixtures / name).is_file() for name in reader.FIXTURES):
        parser.error('All five pinned fixtures are required')
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    original = inventory(ROOT)
    original_setup, locks = producer.setup, []
    folders = ('editor-provider-measure', 'editor-frame-measure', 'editor-storage-measure', 'editor-fold-product', 'editor-fold-points')
    tools = {str(p.relative_to(ROOT)): sha(p) for name in folders for p in (ROOT / 'tools' / name).rglob('*')
             if p.is_file() and p.suffix in ('.py', '.inc')}
    tools[str(Path(__file__).relative_to(ROOT))] = sha(Path(__file__))

    def protected_setup(repo, out, dependencies, mode):
        source = original_setup(repo, out, dependencies, mode)
        assert inventory(ROOT) == original
        (out / 'all-source.json').write_text(json.dumps(dict(original=original, instrumented=inventory(source)), indent=2) + '\n')
        for name, digest in tools.items():
            target = out / 'tool-snapshot' / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)
            assert sha(target) == digest
        cache = source / '.zig-cache'
        cache.mkdir(exist_ok=True)
        locks.append((cache / 'measurement-active.lock').open('ab'))
        return source

    producer.setup = protected_setup
    common = ['--output', str(output), '--deps', str(deps), '--fixtures', str(args.fixtures.resolve())]
    saved_argv = sys.argv
    try:
        for tail in (['--repetitions', '3'], ['--resume', '--run-only', '--prefix', 'verify', '--verify-each-edit', '1', '--repetitions', '1']):
            sys.argv = [str(ROOT / 'tools/editor-provider-measure/run.py'), *common, *tail]
            producer.main()
        assert inventory(ROOT) == original
        manifest = json.loads((output / 'all-source.json').read_text())
        assert inventory(output / 'source-1') == manifest['instrumented']
        assert all(sha(ROOT / name) == digest for name, digest in tools.items())
        binary = json.loads((output / 'binaries.json').read_text())['1']
        assert sha(Path(binary['binary'])) == binary['sha256']
        shutil.copy2(binary['binary'], output / 'archived-test')
        assert sha(output / 'archived-test') == binary['sha256']
        groups = reader.summarize(output, 3)
        assert len(groups) == 10
        logs = {p.name: sha(p) for p in list(output.glob('run-*.log')) + list(output.glob('verify-*.log'))}
        assert len(logs) == 40
        (output / 'provider-groups.json').write_text(json.dumps(groups, indent=2) + '\n')
        result = dict(complete=True, baseline_schema=1, kind='baseline', head=head, processes=40,
                      performance_inputs=600, accuracy_inputs=200, source_unchanged=True,
                      binary_sha256=binary['sha256'], build_log_sha256=sha(output / 'build-1.log'),
                      logs=logs, tools=tools)
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print('BASELINE_COMPLETE_40_PROCESSES', flush=True)
    finally:
        sys.argv = saved_argv
        for lock in locks:
            lock.close()


if __name__ == '__main__':
    main()
