#!/usr/bin/env python3
"""완료한 실제 trace의 격리 사본에 의미 손상을 넣고 다섯 가설을 대조한다."""
import argparse
import json
from pathlib import Path
import shutil
import xml.etree.ElementTree as ET

import evidence
import stacks
import symbols
import replay
from run import write
from verify import verify


def replace(path, data):
    # 사본은 hardlink다. 원본 inode에 쓰지 않고 경로만 교체해야 한다.
    path.unlink()
    path.write_bytes(data)


def json_replace(path, value):
    replace(path, (json.dumps(value, indent=2) + '\n').encode())


def clone(source, destination, base):
    shutil.copytree(source, destination, copy_function=__import__('os').link)
    result = evidence.load(destination / 'result.json')
    symbol = symbols.symbol_file(destination, result['binary_uuid'])
    result['symbol_command'] = symbols.bundle_command(destination, base / 'archived-test')
    for name in result['runs_sha256']:
        path = destination / name / 'run.json'
        meta = evidence.load(path)
        # 별도 실험 사본의 위치만 정규화한다. 실제 대상/입력/스택은 원본과 같다.
        meta['commands'] = evidence.commands(path.parent, base, meta['fixture'], meta['workload'])
        resolution_path = path.parent / 'address-symbols.json'
        resolution = evidence.load(resolution_path)
        resolution['commands'] = symbols.commands(symbol, resolution['plan'])
        json_replace(resolution_path, resolution)
        meta['files_sha256']['address-symbols.json'] = evidence.sha(resolution_path)
        json_replace(path, meta)
        result['runs_sha256'][name] = evidence.sha(path)
    json_replace(destination / 'result.json', result)


def update_run(root, name, mutate=None, xml_file=None, change=None, summary=None, refresh=False, recalculate=False):
    folder = root / name
    meta = evidence.load(folder / 'run.json')
    if xml_file:
        path = folder / xml_file
        tree = ET.parse(path).getroot()
        change(tree)
        replace(path, ET.tostring(tree, encoding='utf-8', xml_declaration=True))
        meta['files_sha256'][xml_file] = evidence.sha(path)
    if refresh:
        refresh_resolution(root, folder, meta)
    if recalculate:
        base = Path(meta['cwd']).parent
        uid = evidence.load(root / 'result.json')['binary_uuid']
        xml = (folder / 'time-profile.xml').read_text()
        resolved = symbols.checked(folder, xml, base / 'archived-test', symbols.symbol_file(root, uid), uid,
                                   evidence.load(folder / 'address-symbols.json'))
        target = stacks.target((folder / 'toc.xml').read_text(), str(base / 'archived-test'),
                               evidence.environment(base, meta['fixture'], meta['workload']))
        meta['summary'] = stacks.profile(xml, target['pid'], str(base / 'archived-test'), uid, resolved)
    if mutate:
        mutate(meta)
    if summary:
        summary(meta['summary'])
    json_replace(folder / 'run.json', meta)
    result = evidence.load(root / 'result.json')
    result['runs_sha256'][name] = evidence.sha(folder / 'run.json')
    json_replace(root / 'result.json', result)


def refresh_resolution(root, folder, meta):
    """표본 주소의 일부를 바꾼 결함 사본도 그에 맞는 실제 SDK 주소 표를 갖게 한다."""
    saved = evidence.load(folder / 'address-symbols.json')
    lines = {}
    for index, command in enumerate(saved['commands']):
        output = (folder / f'atos-{index:03d}.stdout').read_text().splitlines()
        evidence.require(len(output) == len(command[6:]), 'Control address output differs')
        lines.update(zip(command[6:], output))
    base = Path(meta['cwd']).parent
    uid = evidence.load(root / 'result.json')['binary_uuid']
    plan = symbols.plan((folder / 'time-profile.xml').read_text(), base / 'archived-test', uid)
    evidence.require(set(plan['pcs']) <= set(saved['plan']['pcs']), 'Control introduced an unrecorded address')
    for suffix in ('stdout', 'stderr'):
        for path in folder.glob('atos-*.' + suffix):
            path.unlink()
    calls = symbols.commands(symbols.symbol_file(root, uid), plan)
    for index, command in enumerate(calls):
        (folder / f'atos-{index:03d}.stdout').write_text('\n'.join(lines[pc] for pc in command[6:]) + '\n')
        (folder / f'atos-{index:03d}.stderr').write_text('')
    saved.update(plan=plan, commands=calls, names={pc: saved['names'][pc] for pc in plan['pcs']})
    json_replace(folder / 'address-symbols.json', saved)
    meta['files_sha256'] = evidence.inventory(folder, ('run.json',))


def update_result(root, key, value):
    result = evidence.load(root / 'result.json')
    result[key] = value
    json_replace(root / 'result.json', result)


def no_rows(tree):
    for row in list(tree[0].findall('row')):
        tree[0].remove(row)


def remove_edit_addresses(root, name):
    saved = evidence.load(root / name / 'address-symbols.json')
    replacement = next(pc for pc, value in saved['names'].items() if value and value not in stacks.EDIT_CONTEXTS)
    def change(tree):
        for frame in tree.iter('frame'):
            if frame.get('addr') and saved['names'].get(hex(int(frame.get('addr'), 16))) in stacks.EDIT_CONTEXTS:
                frame.set('addr', replacement)
    update_run(root, name, xml_file='time-profile.xml', change=change, refresh=True)


def wrong_pid(tree):
    pid = tree.find('.//pid')
    pid.text = str(int(pid.text) + 1000000)


def wrong_uuid(tree):
    image = next(x for x in tree.iter('binary') if x.get('name') == 'archived-test')
    image.set('UUID', '00000000-0000-0000-0000-000000000000')


def reference_type(tree):
    frame = next(x for x in tree.iter('frame') if x.get('id'))
    node = tree.find('.//row/process')
    node.attrib.clear()
    node.set('ref', frame.get('id'))


def dangling_reference(tree):
    node = next(x for x in tree.iter('binary') if x.get('ref'))
    node.set('ref', '999999999')


def wrong_column(tree):
    tree.find('.//col/engineering-type').text = 'duration'


def malformed_sentinel(tree):
    node = tree.find('.//sentinel')
    evidence.require(node is not None, 'Control needs an observed missing-stack sentinel')
    node.set('unexpected', '1')


def recursive_equivalent(tree, resolution):
    ids = {x.get('id'): x for x in tree.iter() if x.get('id')}
    def get(node):
        return ids[node.get('ref')] if node.get('ref') else node
    for trace in tree.iter('backtrace'):
        if 'ref' in trace.attrib:
            continue
        own = [get(x) for x in trace]
        if any(resolution['names'].get(hex(int(x.get('addr'), 16))) in stacks.EDIT_CONTEXTS for x in own):
            frame = next(x for x in own if x.find('binary') is not None
                         and get(x.find('binary')).get('name') == 'archived-test'
                         and resolution['names'].get(hex(int(x.get('addr'), 16))))
            trace.insert(1, ET.Element('frame', ref=frame.get('id')))
            return
    raise ValueError('Control needs an identified edit stack')


def remove_dependency(root):
    name = 'tools/editor-frame-measure/contract.py'
    result = evidence.load(root / 'result.json')
    del result['producer_sha256'][name]
    (root / 'tool-snapshot' / name).unlink()
    producer = evidence.load(root / 'producer.json')
    del producer['tools_sha256'][name]
    json_replace(root / 'producer.json', producer)
    result['producer_receipt_sha256'] = evidence.sha(root / 'producer.json')
    json_replace(root / 'result.json', result)


def damage_trace(root, name):
    folder = root / name
    path = next(x for x in (folder / 'profile.trace').rglob('*') if x.is_file())
    replace(path, path.read_bytes() + b'changed')


def missing_product_control(root, name):
    path = root / name / 'target.stdout'
    text = path.read_text()
    evidence.require('All 5 tests passed.' in text, 'Control needs a successful target run')
    replace(path, text.replace('All 5 tests passed.', 'All 0 tests passed.').encode())
    update_run(root, name, mutate=lambda m: m['files_sha256'].update({'target.stdout': evidence.sha(path)}))


def corrupt_self(summary):
    key = next(iter(summary['self_weight_ns']['all']))
    summary['self_weight_ns']['all'][key] += 1


def boolean_count(summary):
    for key, value in summary['counts'].items():
        if type(value) is int and value in (0, 1):
            summary['counts'][key] = bool(value)
            return
    raise ValueError('Control needs a zero or one numeric count')


def forged_weight(root, name):
    def change(tree):
        weight = tree.find('.//weight')
        weight.text = str(int(weight.text) * 2)
    update_run(root, name, xml_file='time-profile.xml', change=change, recalculate=True)


def rename_target_display(tree, resolution):
    for frame in tree.iter('frame'):
        if frame.get('addr') and hex(int(frame.get('addr'), 16)) in resolution['names']:
            frame.set('name', 'display-only')


def renumber_ids(tree):
    for node in tree.iter():
        for field in ('id', 'ref'):
            if field in node.attrib:
                node.set(field, str(int(node.get(field)) + 1000000))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--profiles', type=Path, required=True)
    parser.add_argument('--expected-head', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    base, source, output = args.baseline.resolve(), args.profiles.resolve(), args.output.resolve()
    if output.exists() or output == evidence.ROOT or evidence.ROOT in output.parents or source in output.parents:
        parser.error('Use a new independent path outside the repository')
    original = evidence.inventory(source)
    output.mkdir(parents=True)
    replay.configure(output / 'sdk-replays')
    verify(base, source, args.expected_head)
    first = 'profile-0-flat-15000.zig-typing'
    raw = lambda file, change: lambda root: update_run(root, first, xml_file=file, change=change)
    groups = [
        ('usable-population', [
            ('incomplete', lambda r: update_result(r, 'complete', False), 'Incomplete or wrong profile dataset'),
            ('empty-stacks', raw('time-profile.xml', no_rows), 'Missing or ambiguous executable load address'),
            ('no-edit-context', lambda r: remove_edit_addresses(r, first), 'No identifiable edit context'),
            ('observation-ended', raw('toc.xml', lambda x: setattr(x.find('.//end-reason'), 'text', 'Time limit reached')),
             'Recording ended before target completion'),
        ]),
        ('target-identity', [
            ('foreign-pid', raw('time-profile.xml', wrong_pid), 'Foreign sample PID'),
            ('foreign-uuid', raw('time-profile.xml', wrong_uuid), 'Target image UUID or path differs'),
            ('foreign-path', raw('toc.xml', lambda x: x.find('.//processes/process[@name="archived-test"]').set('path', '/tmp/other/archived-test')),
             'Wrong target executable path'),
            ('wrong-command', lambda r: update_run(r, first, mutate=lambda m: m['commands'][0].__setitem__(-1, '--maru-expect-passed=0')),
             'Wrong executed command or working directory'),
        ]),
        ('xml-reference-contract', [
            ('wrong-ref-type', raw('time-profile.xml', reference_type), 'Reference type mismatch'),
            ('dangling-ref', raw('time-profile.xml', dangling_reference), 'Missing or cyclic reference'),
            ('wrong-column', raw('time-profile.xml', wrong_column), 'Unknown profile column schema'),
            ('bad-sentinel', raw('time-profile.xml', malformed_sentinel), 'Invalid missing-stack sentinel'),
        ]),
        ('weight-and-classification', [
            ('wrong-self', lambda r: update_run(r, first, summary=corrupt_self), 'Stored profile summary differs'),
            ('wrong-edit-weight', lambda r: update_run(r, first, summary=lambda s: s['counts'].__setitem__('edit_weight_ns', s['counts']['edit_weight_ns']+1)),
             'Stored profile summary differs'),
            ('negative-weight', raw('time-profile.xml', lambda x: setattr(x.find('.//weight'), 'text', '-1')), 'Invalid integer: sample weight'),
        ]),
        ('source-product-provenance', [
            ('bool-schema', lambda r: update_result(r, 'schema', True), 'Wrong profile dataset schema'),
            ('missing-process', lambda r: update_result(r, 'processes', 29), 'Wrong profile population'),
            ('wrong-baseline', lambda r: update_result(r, 'baseline_result_sha256', '0'*64), 'Wrong linked baseline'),
            ('coherent-missing-contract', remove_dependency, 'Missing captured sampling producer'),
            ('trace-byte', lambda r: damage_trace(r, first), 'Changed artifact:'),
            ('product-not-finished', lambda r: missing_product_control(r, first), 'Product control did not finish'),
            ('coherent-forged-weight', lambda r: forged_weight(r, first), 'Trace sample replay differs'),
            ('bool-summary-count', lambda r: update_run(r, first, summary=boolean_count), 'Stored profile summary differs'),
        ]),
    ]
    records, controls = [], []
    for group, cases in groups:
        for phase in ('before', 'after'):
            if phase == 'before':
                verify(base, source, args.expected_head)
                controls.append(group + ':before')
                continue
            for name, mutate, message in cases:
                folder = output / group / name
                clone(source, folder, base)
                mutate(folder)
                try:
                    verify(base, folder, args.expected_head)
                except ValueError as error:
                    evidence.require(message in str(error), 'Wrong rejection for ' + name + ': ' + str(error))
                    records.append(dict(group=group, case=name, rejected_by=str(error), clone=str(folder)))
                else:
                    raise AssertionError('Fault accepted: ' + group + '/' + name)
            verify(base, source, args.expected_head)
            controls.append(group + ':after')
    for label, transform in [('display-name-equivalent', rename_target_display),
                              ('id-equivalent', lambda tree, _: renumber_ids(tree))]:
        equivalent = output / label
        clone(source, equivalent, base)
        saved = evidence.load(equivalent / first / 'address-symbols.json')
        update_run(equivalent, first, xml_file='time-profile.xml', change=lambda tree: transform(tree, saved))
        verify(base, equivalent, args.expected_head)
        controls.append(label)
    recursive = output / 'recursive-component-control'
    clone(source, recursive, base)
    saved = evidence.load(recursive / first / 'address-symbols.json')
    update_run(recursive, first, xml_file='time-profile.xml', change=lambda tree: recursive_equivalent(tree, saved))
    result = evidence.load(recursive / 'result.json')
    evidence.read_run(recursive / first, base, 0, 'flat-15000.zig', 'typing', result['binary_sha256'], result['binary_uuid'])
    try:
        verify(base, recursive, args.expected_head)
    except ValueError as error:
        evidence.require('Trace sample replay differs' in str(error), 'Wrong recursive control rejection')
    else:
        raise AssertionError('SDK replay accepted a manufactured stack')
    evidence.require(evidence.inventory(source) == original, 'Original profiles changed during mutation controls')
    write(output / 'result.json', dict(complete=True, head=args.expected_head, hypotheses=5, rejected=records,
        normal_controls=controls, recursive_aggregation_control='Component weight unchanged; full SDK replay correctly rejects the manufactured stack', original_sha256=original,
        reader_sha256={n: evidence.sha(Path(__file__).with_name(n)) for n in ('verify.py', 'evidence.py', 'stacks.py', 'symbols.py', 'replay.py')},
        source_sha256=evidence.sha(Path(__file__)),
        scope='Hardlink clones use unlink-before-write; only cloned output command paths normalized; semantic XML faults update hashes to reach intended guard; no compiler/parser-selection failures counted'))
    print('NATIVE_SAMPLING_ADVERSARIAL_PASS', len(records), len(controls), flush=True)


if __name__ == '__main__':
    main()
