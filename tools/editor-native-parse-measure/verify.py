#!/usr/bin/env python3
"""Git 원본·계측 소스·보관 바이너리·원시 기록을 대조하고 두 모집단을 구분한다."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile

import contract

ROOT = Path(__file__).resolve().parents[2]
load = contract.provider.load
digest = contract.provider.digest


def git_sources(head):
    if re.fullmatch('[0-9a-f]{40}', head) is None:
        raise ValueError('Expected a complete Git commit ID')
    result = {}
    process = subprocess.Popen(['git', 'archive', head, 'src', 'build.zig', 'build.zig.zon'],
                               cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        with tarfile.open(fileobj=process.stdout, mode='r|') as archive:
            for entry in archive:
                if entry.issym() or entry.islnk():
                    raise ValueError('Source symlinks need explicit provenance support')
                if entry.isfile():
                    value = hashlib.sha256()
                    with archive.extractfile(entry) as stream:
                        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                            value.update(chunk)
                    result[entry.name] = value.hexdigest()
    except tarfile.TarError as error:
        raise ValueError('Git source archive could not be read') from error
    finally:
        process.stdout.close()
        error = process.stderr.read().decode()
        code = process.wait()
        process.stderr.close()
    if code != 0:
        raise ValueError('Git source archive failed: ' + error)
    if 'build.zig.zon' not in result:
        raise ValueError('Incomplete Git source archive')
    return result


def strict_int(value, expected, label):
    if type(value) is not int or value != expected:
        raise ValueError('Wrong ' + label)


def checked_dataset(root, kind, head, originals):
    root = root.resolve()
    result, setup = load(root / 'result.json'), load(root / 'setup-1.json')
    if result.get('complete') is not True or result.get('source_unchanged') is not True:
        raise ValueError('Incomplete product evidence')
    if result.get('head') != head or setup.get('head') != head or result.get('kind') != kind:
        raise ValueError('Wrong source revision or dataset kind')
    strict_int(setup.get('mode'), 1, 'production mode')
    strict_int(setup.get('provider_schema'), 3, 'provider schema')
    strict_int(setup.get('frame_schema'), 2, 'frame schema')
    if setup.get('provider_execution') != 'revision-snapshots':
        raise ValueError('Wrong provider execution model')
    if kind == 'baseline':
        strict_int(result.get('baseline_schema'), 1, 'baseline schema')
        strict_int(result.get('processes'), 40, 'baseline population')
        strict_int(result.get('performance_inputs'), 600, 'performance input count')
        strict_int(result.get('accuracy_inputs'), 200, 'baseline accuracy count')
        if 'native_probe_schema' in setup:
            raise ValueError('Diagnostic instrumentation in baseline')
    else:
        strict_int(result.get('processes'), 10, 'diagnostic population')
        strict_int(result.get('inputs'), 200, 'diagnostic input count')
        if result.get('performance_samples') is not False:
            raise ValueError('Diagnostic timings cannot become performance samples')
    sources = originals.copy()
    zon = sources.pop('build.zig.zon')
    manifest = load(root / 'all-source.json')
    if manifest.get('original') != sources or set(manifest.get('instrumented', {})) != set(sources):
        raise ValueError('All-source provenance differs from the Git revision')
    actual = {str(p.relative_to(root / 'source-1')) for p in (root / 'source-1/src').rglob('*') if p.is_file()} | {'build.zig'}
    if actual != set(sources):
        raise ValueError('Missing or extra captured source')
    for name, value in manifest['instrumented'].items():
        digest(root / 'source-1' / name, value)
    digest(root / 'source-1/build.zig.zon', zon)
    names = contract.provider.source_names(setup)
    if any(set(setup.get(key, {})) != names for key in ('original_sha256', 'instrumented_sha256')):
        raise ValueError('Incomplete provider source contract')
    for name in names:
        if setup['original_sha256'][name] != sources[name] or setup['instrumented_sha256'][name] != manifest['instrumented'][name]:
            raise ValueError('Provider and full-source receipts disagree')
        digest(root / 'original-product' / name, sources[name])
    tools = result.get('tools', {})
    required = {'tools/editor-provider-measure/run.py', 'tools/editor-frame-measure/run.py',
                'tools/editor-storage-measure/run.py', 'tools/editor-fold-product/run.py',
                'tools/editor-fold-product/host.zig.inc', 'tools/editor-fold-points/run.py'}
    required |= ({'tools/editor-native-parse-measure/baseline.py'} if kind == 'baseline' else
                 {'tools/editor-native-parse-measure/run.py', 'tools/editor-native-parse-measure/prepare.py',
                  'tools/editor-native-parse-measure/contract.py', 'tools/editor-native-parse-measure/probe.zig.inc'})
    captured = {str(p.relative_to(root / 'tool-snapshot')) for p in (root / 'tool-snapshot').rglob('*')
                if p.is_file() and p.suffix in ('.py', '.inc')}
    if not required <= set(tools) or captured != set(tools):
        raise ValueError('Incomplete captured producer tools')
    for name, value in tools.items():
        path = PurePosixPath(name)
        if not name.startswith('tools/') or '..' in path.parts or path.is_absolute():
            raise ValueError('Invalid producer tool path')
        digest(root / 'tool-snapshot' / name, value)
    binaries = load(root / 'binaries.json')
    if set(binaries) != {'1'}:
        raise ValueError('Wrong binary modes')
    binary = binaries['1']
    if Path(binary['cwd']).resolve() != (root / 'source-1').resolve():
        raise ValueError('Binary working directory differs')
    if not Path(binary['binary']).resolve().is_relative_to((root / 'source-1/.zig-cache').resolve()):
        raise ValueError('Unexpected recorded build binary location')
    if binary['sha256'] != result.get('binary_sha256'):
        raise ValueError('Binary receipts disagree')
    # 캐시 경로는 역사적 실행 위치다. 재검증은 같은 해시의 보관 파일로 가능해야 한다.
    digest(root / 'archived-test', binary['sha256'])
    digest(root / 'build-1.log', result['build_log_sha256'])
    inputs = load(root / 'inputs.json')
    if set(inputs) != contract.provider.FIXTURES:
        raise ValueError('Incomplete pinned fixtures')
    data = {}
    for name, meta in inputs.items():
        data[name] = (root / 'fixtures' / name).read_bytes()
        if set(meta) != {'bytes', 'sha256'} or type(meta['bytes']) is not int or meta['bytes'] != len(data[name]):
            raise ValueError('Wrong fixture byte count')
        digest(root / 'fixtures' / name, meta['sha256'])
    build_text = (root / 'build-1.log').read_text()
    if kind == 'baseline':
        contract.provider.validate(build_text, 'typing', data['flat-3000.zig'], 'flat-3000.zig', 1, 3, 'revision-snapshots', 2)
    else:
        contract.validate(build_text, 'typing', data['flat-3000.zig'], 'flat-3000.zig', setup)
    wanted = {}
    for prefix, repetitions, oracle in ([('run', 3, 0), ('verify', 1, 1)] if kind == 'baseline' else [('verify', 1, 1)]):
        for repeat in range(repetitions):
            for name in sorted(inputs):
                for workload in ('typing', 'shared'):
                    wanted[f'{prefix}-{repeat}-1-{name}-{workload}.log'] = (name, workload, oracle)
    actual = {p.name for prefix in ('run', 'verify') for p in root.glob(prefix + '-*.log')}
    if set(result.get('logs', {})) != set(wanted) or actual != set(wanted):
        raise ValueError('Missing duplicate or extra raw executions')
    groups, first, native = {}, {}, {}
    for filename, (name, workload, oracle) in wanted.items():
        path = root / filename
        digest(path, result['logs'][filename])
        text = path.read_text()
        parsed = contract.provider.validate(text, workload, data[name], name, oracle, 3, 'revision-snapshots', 2)
        frames = contract.provider.frame.validate(text, workload, len(data[name]), data[name].count(b'\n') + 1, 2)
        key = name + '/' + workload
        if kind == 'diagnostic-only':
            native.setdefault(key, []).extend(contract.read_probe(text, parsed, frames))
        elif any(line.startswith('NATIVE_PROBE') for line in text.splitlines()):
            raise ValueError('Native diagnostic record mixed into baseline')
        if not oracle:
            groups.setdefault(key, []).extend(dict(frame, **{k: row[k] for k in contract.provider.STAGES}) for frame, row in zip(frames, parsed))
            first.setdefault(key, []).append(frames[0]['total_ns'])
    return dict(head=head, inputs=inputs, groups=groups, first=first, native=native,
                source_files=len(sources), binary_sha256=binary['sha256'])


def stats(values):
    ordered = sorted(values)
    count = len(ordered)
    mid = count // 2
    median = ordered[mid] if count % 2 else (ordered[mid - 1] + ordered[mid]) / 2
    return dict(n=count, p50=median / 1e6, p95=ordered[(95 * count + 99) // 100 - 1] / 1e6, max=ordered[-1] / 1e6)


def verify_pair(baseline, diagnostic, expected_head):
    if baseline.resolve() == diagnostic.resolve():
        raise ValueError('Performance and diagnostic roots must differ')
    originals = git_sources(expected_head)
    base = checked_dataset(baseline, 'baseline', expected_head, originals)
    probe = checked_dataset(diagnostic, 'diagnostic-only', expected_head, originals)
    if base['inputs'] != probe['inputs']:
        raise ValueError('Performance and diagnostic inputs differ')
    if base['binary_sha256'] == probe['binary_sha256']:
        raise ValueError('Performance and diagnostic binaries must differ')
    clocks = ('total_ns', 'edit_ns', 'appendPaneFrame', 'providerEdit', 'nativeParse', 'syntaxColors',
              'buildPaneOps', 'delta_ns', 'copy_ns', 'index_ns', 'view_lines_ns') + contract.provider.STAGES
    timing = {key: dict(ms={field: stats([row[field] for row in rows]) for field in clocks},
                        first_input_ms=stats(base['first'][key])) for key, rows in base['groups'].items()}
    counters = {key: {field: dict(min=min(row[field] for row in rows), max=max(row[field] for row in rows),
                                 sum=sum(row[field] for row in rows)) for field in contract.FIELDS}
                for key, rows in probe['native'].items()}
    if len(timing) != 10 or len(counters) != 10 or any(len(rows) != 60 for rows in base['groups'].values()):
        raise ValueError('Wrong final sample groups')
    reader_files = [Path(__file__), Path(__file__).with_name('contract.py')]
    return dict(complete=True, head=expected_head, baseline=dict(processes=40, performance_inputs=600, accuracy_inputs=200, groups=timing),
                diagnostic=dict(processes=10, accuracy_inputs=200, timing_samples_used=False, groups=counters),
                source_files=base['source_files'], binary_sha256=dict(baseline=base['binary_sha256'], diagnostic=probe['binary_sha256']),
                reader_sha256={p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in reader_files})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--diagnostic', type=Path, required=True)
    parser.add_argument('--expected-head', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Use a new receipt path')
    if args.output.resolve() == ROOT or ROOT in args.output.resolve().parents:
        parser.error('Receipt must be outside the repository')
    result = verify_pair(args.baseline, args.diagnostic, args.expected_head)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')
    print('NATIVE_ATTRIBUTION_VERIFIED_50_PROCESSES')


if __name__ == '__main__':
    main()
