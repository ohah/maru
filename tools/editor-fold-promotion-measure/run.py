#!/usr/bin/env python3
"""제품 사본에서 구문 접힘의 조회·변환·설치·뷰 마무리 비용을 나눈다."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    'promotion_inner', ROOT / 'tools/editor-pane-syntax-measure/run.py'
)
inner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inner)
TARGET = 'fold-promotion-attribution'
SCOPE = 'Pane advance only; promote contains query/ranges/install; install contains visible/finish; preserve caller flags; no edit/LSP/user-fold calls'
STAGES = ('promote', 'query', 'ranges', 'install', 'visible', 'finish')
NAMES = ('flat-3000.zig', 'flat-15000.zig', 'flat-50000.zig', 'real-build.zig', 'real-host.swift')
HOST = inner.lower.pane.HOST


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory(root):
    result = {str(path.relative_to(root)): sha(path)
              for path in (root / 'src').rglob('*') if path.is_file()}
    result['build.zig'] = sha(root / 'build.zig')
    return result


def archive_inventory(head, repo=ROOT):
    if not isinstance(head, str) or re.fullmatch('[0-9a-f]{40}', head) is None:
        raise ValueError('Use an exact recorded source object')
    result = {}
    with tempfile.TemporaryFile() as stream:
        try:
            subprocess.run(['git', 'archive', '--format=tar', head, 'src', 'build.zig'],
                           cwd=repo, stdout=stream, stderr=subprocess.PIPE, check=True)
        except subprocess.CalledProcessError as error:
            raise ValueError('Recorded source object cannot be archived') from error
        stream.seek(0)
        with tarfile.open(fileobj=stream) as archive:
            for member in archive:
                if member.isfile():
                    digest = hashlib.sha256()
                    with archive.extractfile(member) as content:
                        for block in iter(lambda: content.read(1024 * 1024), b''):
                            digest.update(block)
                    result[member.name] = digest.hexdigest()
    return result


def load(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Duplicate JSON field: ' + key)
            result[key] = value
        return result
    return json.loads(path.read_text(), object_pairs_hook=unique)


def check_contract(info):
    inner.check_contract(info)
    if (type(info.get('mode')) is not int or info['mode'] != 1
            or info.get('comparison_target') != 'provider-edit-attribution'):
        raise ValueError('Wrong parent attribution target/mode')
    if (type(info.get('promotion_schema')) is not int or info['promotion_schema'] != 1
            or info.get('promotion_target') != TARGET
            or info.get('promotion_scope') != SCOPE
            or info.get('promotion_stages') != list(STAGES)):
        raise ValueError('Wrong fold promotion schema/target/stages/scope')
    for field, size in (('promotion_generator_sha256', 64), ('promotion_source_head', 40)):
        value = info.get(field)
        if not isinstance(value, str) or re.fullmatch('[0-9a-f]{' + str(size) + '}', value) is None:
            raise ValueError('Missing fold promotion proof: ' + field)
    if info.get('head') != info['promotion_source_head'] or info.get('promotion_original_unchanged') is not True:
        raise ValueError('Promotion source head disagrees with parent')
    original = info.get('promotion_original_sha256')
    instrumented = info.get('promotion_instrumented_sha256')
    if (not isinstance(original, dict) or not isinstance(instrumented, dict)
            or set(original) != set(instrumented) or 'build.zig' not in original
            or not any(name.startswith('src/') for name in original)):
        raise ValueError('Incomplete promotion source inventories')
    for values in (original, instrumented):
        for name, value in values.items():
            path = Path(name)
            if (path.is_absolute() or '..' in path.parts or path.as_posix() != name
                    or (name != 'build.zig' and not name.startswith('src/'))
                    or not isinstance(value, str) or re.fullmatch('[0-9a-f]{64}', value) is None):
                raise ValueError('Malformed promotion source inventory')
    for name, value in info.get('original_sha256', {}).items():
        if original.get(name) != value or instrumented.get(name) != info['instrumented_sha256'][name]:
            raise ValueError('Promotion source inventory disagrees with parent')
    facts = info.get('promotion_inputs')
    if not isinstance(facts, dict) or set(facts) != set(NAMES):
        raise ValueError('Wrong fold promotion input population')
    for fact in facts.values():
        if (not isinstance(fact, dict) or set(fact) != {'bytes', 'lf', 'sha256'}
                or type(fact['bytes']) is not int or fact['bytes'] <= 0
                or type(fact['lf']) is not int or fact['lf'] <= 0
                or not isinstance(fact['sha256'], str)
                or re.fullmatch('[0-9a-f]{64}', fact['sha256']) is None):
            raise ValueError('Malformed fold promotion input facts')


def once(text, old, new):
    return inner.once(text, old, new)


def check_inputs(output, info):
    inputs = load(output / 'inputs.json')
    if set(inputs) != set(NAMES):
        raise ValueError('Prepared input population changed')
    for name in NAMES:
        path = output / 'fixtures' / name
        data = path.read_bytes()
        fact = {'bytes': len(data), 'lf': data.count(b'\n'), 'sha256': sha(path)}
        record = inputs[name]
        if (not isinstance(record, dict) or set(record) != {'bytes', 'sha256'}
                or type(record['bytes']) is not int or not isinstance(record['sha256'], str)
                or fact != info['promotion_inputs'][name]
                or inputs[name] != {'bytes': fact['bytes'], 'sha256': fact['sha256']}):
            raise ValueError('Prepared input changed: ' + name)


def record_run_proof(output, prefix, execution):
    order_path = output / (prefix + '-order.json')
    if not order_path.exists():
        return
    order = load(order_path)
    files = ['setup-1.json', 'inputs.json', 'binaries.json', 'promotion-generator.py',
             prefix + '-order.json', prefix + '-order.stdout']
    for row in order:
        path = Path(row['log']).resolve()
        if path.parent != output.resolve() or path.name in files:
            raise ValueError('Invalid or duplicate execution log')
        files.append(path.name)
    proof = dict(schema=1, target=TARGET, prefix=prefix, execution=execution,
                 sha256={name: sha(output / name) for name in files})
    with (output / ('promotion-' + prefix + '-proof.json')).open('x') as stream:
        stream.write(json.dumps(proof, indent=2) + '\n')


def instrument_host(text):
    begin = text.index('fn promoteFoldRangesToSyntax(')
    end = text.index('\npub fn installFoldRanges(', begin)
    before, part, after = text[:begin], text[begin:end], text[end:]
    # 기존 INNER 타이머 안에 들어가 부모/자식의 포함 관계를 보존한다.
    anchor = '    defer syntax_color.innerProbeFinish(2, inner_start);\n'
    part = once(part, anchor, anchor + '''    const promotion_previous = fold_probe_active;
    fold_probe_active = syntax_color.inner_probe_advance;
    const promotion_start = foldProbeStart(fold_probe_active);
    defer {
        foldProbeFinish(0, promotion_start);
        fold_probe_active = promotion_previous;
    }
''')
    anchor = '    prov.foldSpansCached(self.allocator, &st.folds, doc.file.lines.lines, &spans) catch return;'
    part = once(part, anchor, '''    {
        const promotion_query_start = foldProbeStart(fold_probe_active);
        defer foldProbeFinish(1, promotion_query_start);
''' + anchor + '''
        if (fold_probe_active) fold_probe_spans += spans.items.len;
    }''')
    anchor = '    const ranges = self.allocator.alloc(editor_fold.Range, n) catch return;'
    if part.count(anchor) != 1 or part.count('    if (!installFoldRanges(self, term, ranges)) {') != 1:
        raise ValueError('Nonunique fold range conversion')
    start = part.index(anchor)
    limit = part.index('    if (!installFoldRanges(self, term, ranges)) {', start)
    end = part.rfind('    }\n', start, limit) + len('    }\n')
    if end <= start or end > limit:
        raise ValueError('Missing fold range loop end')
    block = part[start:end]
    block = once(block, 'const ranges =', 'const promotion_ranges =')
    block = once(block, '        ranges[i] = .{', '        promotion_ranges[i] = .{')
    part = part[:start] + '''    const ranges = promotion_build: {
        const promotion_ranges_start = foldProbeStart(fold_probe_active);
        defer foldProbeFinish(2, promotion_ranges_start);
''' + block + '''        break :promotion_build promotion_ranges;
    };
''' + part[end:]
    text = before + part + after
    for name, stage in (('installFoldRanges', 3), ('rebuildVisible', 4), ('finishFoldChange', 5)):
        matches = list(re.finditer(r'^(?:pub )?fn ' + name + r'\([^\n]*\) [^\n]+ \{\n', text, re.M))
        if len(matches) != 1:
            raise ValueError('Nonunique fold publication function: ' + name)
        anchor = matches[0].group()
        if stage == 3:
            prefix = '''    const promotion_install_previous = fold_probe_install_active;
    fold_probe_install_active = fold_probe_active;
    const promotion_call_start = foldProbeStart(fold_probe_install_active);
    defer {
        foldProbeFinish(3, promotion_call_start);
        fold_probe_install_active = promotion_install_previous;
    }
'''
        else:
            prefix = ('    const promotion_call_start = foldProbeStart(fold_probe_install_active);\n'
                      + f'    defer foldProbeFinish({stage}, promotion_call_start);\n')
        text = once(text, anchor, anchor + prefix)
    text += '''
var fold_probe_active: bool = false;
var fold_probe_install_active: bool = false;
var fold_probe_ns: [6]i128 = @splat(0);
var fold_probe_calls: [6]u64 = @splat(0);
var fold_probe_spans: u64 = 0;
fn foldProbeStart(active: bool) ?i128 {
    return if (active) std.Io.Clock.awake.now(std.testing.io).nanoseconds else null;
}
fn foldProbeFinish(index: usize, start: ?i128) void {
    if (start) |value| {
        fold_probe_ns[index] += std.Io.Clock.awake.now(std.testing.io).nanoseconds - value;
        fold_probe_calls[index] += 1;
    }
}
'''
    anchor = '        lowering_probe_calls = @splat(0);'
    text = once(text, anchor, anchor + '''
        try testing.expect(!fold_probe_active and !fold_probe_install_active);
        fold_probe_ns = @splat(0);
        fold_probe_calls = @splat(0);
        fold_probe_spans = 0;
''')
    fields = ' '.join(name + '={d} ' + name + '_calls={d}' for name in STAGES)
    values = ', '.join(f'fold_probe_ns[{i}], fold_probe_calls[{i}]' for i in range(len(STAGES)))
    anchor = '        const live_doc = term.rt.editorDocument().opened.?;'
    text = once(text, anchor,
                '        try testing.expect(!fold_probe_active and !fold_probe_install_active);\n'
                + '        std.debug.print("FOLD_PROMOTION key={d} ' + fields + ' spans={d}\\n", .{i, '
                + values + ', fold_probe_spans});\n' + anchor)
    return text


def setup(repo, output, deps, mode):
    original = inventory(repo)
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip()
    if original != archive_inventory(head, repo):
        raise ValueError('Commit runtime source changes before preparation')
    source = inner.setup(repo, output, deps, mode)
    path = source / HOST
    path.write_text(instrument_host(path.read_text()))
    info_path = output / 'setup-1.json'
    info = load(info_path)
    info['instrumented_sha256'][HOST] = sha(path)
    info.update(promotion_schema=1, promotion_target=TARGET, promotion_stages=list(STAGES),
                promotion_scope=SCOPE, promotion_generator_sha256=sha(Path(__file__)),
                promotion_source_head=head, promotion_original_unchanged=inventory(repo) == original,
                promotion_original_sha256=original, promotion_instrumented_sha256=inventory(source),
                promotion_inputs={name: {'bytes': (output / 'fixtures' / name).stat().st_size,
                                         'lf': (output / 'fixtures' / name).read_bytes().count(b'\n'),
                                         'sha256': sha(output / 'fixtures' / name)} for name in NAMES})
    check_contract(info)
    changed = {name for name in original if original[name] != info['promotion_instrumented_sha256'][name]}
    if not changed <= set(info['instrumented_sha256']):
        raise ValueError('Unexpected source changed outside instrumented owners')
    check_inputs(output, info)
    shutil.copyfile(__file__, output / 'promotion-generator.py')
    info_path.write_text(json.dumps(info, indent=2) + '\n')
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--deps', type=Path, required=True)
    parser.add_argument('--fixtures', type=Path)
    parser.add_argument('--run-only', action='store_true')
    parser.add_argument('--resume', action='store_true')
    parser.add_argument('--modes', choices=('1',), default='1')
    parser.add_argument('--workloads', default='typing,shared')
    parser.add_argument('--prefix', choices=('run', 'verify'), default='run')
    parser.add_argument('--verify-each-edit', type=int, choices=(0, 1), default=0)
    parser.add_argument('--repetitions', type=int, default=3)
    parser.add_argument('--baseline', action='store_true')
    parser.add_argument('--baseline-ref')
    parser.add_argument('--refresh', action='store_true')
    args = parser.parse_args()
    if args.baseline or args.baseline_ref is not None or args.refresh:
        parser.error('Attribution only; use a new output to prepare another source')
    workloads = args.workloads.split(',')
    if (not workloads or len(workloads) != len(set(workloads))
            or not set(workloads) <= {'typing', 'shared'}):
        parser.error('Use typing and/or shared once each')
    if args.repetitions < 0:
        parser.error('Use nonnegative repetitions')
    if (args.prefix == 'verify') != bool(args.verify_each_edit):
        parser.error('Use verify with the per-input oracle and run without it')
    output = args.output.expanduser().resolve()
    deps = args.deps.expanduser().resolve()
    if output.is_relative_to(ROOT) or not deps.is_dir():
        parser.error('Use an external output and existing dependencies')
    try:
        if args.run_only:
            if args.fixtures is not None:
                raise ValueError('Prepared inputs cannot be replaced during execution')
            info = load(output / 'setup-1.json')
            check_contract(info)
            if sha(output / 'promotion-generator.py') != info['promotion_generator_sha256']:
                raise ValueError('Promotion generator changed')
            if sha(Path(__file__)) != info['promotion_generator_sha256']:
                raise ValueError('Use the recorded promotion runner for this prepared source')
            check_inputs(output, info)
            if (inventory(output / 'source-1') != info['promotion_instrumented_sha256']
                    or archive_inventory(info['promotion_source_head']) != info['promotion_original_sha256']):
                raise ValueError('Prepared source provenance changed')
        else:
            if args.fixtures is None or output.exists():
                raise ValueError('Preparation needs fixed fixtures and a new external output')
            fixtures = args.fixtures.expanduser().resolve()
            if not all((fixtures / name).is_file() for name in NAMES):
                raise ValueError('Missing fixed fixture')
            if not all(0 < (fixtures / name).stat().st_size < 4 * 1024 * 1024 for name in NAMES):
                raise ValueError('Use nonempty fixtures inside the existing parsing budget')
    except (ValueError, FileNotFoundError) as error:
        parser.error(str(error))
    # 상위 측정기의 CLI를 유지하되, 사본 생성만 이 계측으로 바꾼다.
    import sys
    sys.argv = [sys.argv[0], '--output', str(output), '--deps', str(deps), '--modes', '1',
                '--workloads', args.workloads, '--prefix', args.prefix,
                '--verify-each-edit', str(args.verify_each_edit),
                '--repetitions', str(args.repetitions)]
    if args.resume or args.run_only:
        sys.argv.append('--resume')
    if args.fixtures is not None:
        sys.argv.extend(['--fixtures', str(fixtures)])
    if args.run_only:
        sys.argv.append('--run-only')
    inner.lower.setup = setup
    inner.lower.main()
    record_run_proof(output, args.prefix, dict(repetitions=args.repetitions, workloads=workloads,
                                             oracle=args.verify_each_edit))


if __name__ == '__main__':
    main()
