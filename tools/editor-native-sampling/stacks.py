"""Time Profiler의 대상 identity와 스택 모집단을 검사한다. weight는 호출별 시간이 아니다."""
from collections import Counter
import re
import struct
import uuid
import xml.etree.ElementTree as ET

SCHEMA = 1
EDIT_CONTEXT = 'app_session.editor.syntax.onEditSpanFromReady'
EDIT_CONTEXTS = (EDIT_CONTEXT, 'tree_sitter.Provider.onEditBudgeted')
COLUMNS = (
    ('time', 'sample-time'), ('thread', 'thread'), ('process', 'process'),
    ('core', 'core'), ('thread-state', 'thread-state'), ('weight', 'weight'),
    ('stack', 'backtrace'),
)
NATIVE = {'ts_parser_parse_with_options', 'ts_tree_get_changed_ranges'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def one(parent, tag):
    found = parent.findall(tag)
    require(len(found) == 1, 'Expected one ' + tag)
    return found[0]


def integer(text, label, positive=False):
    require(isinstance(text, str) and re.fullmatch(r'0|[1-9][0-9]*', text) is not None,
            'Invalid integer: ' + label)
    value = int(text)
    require(not positive or value > 0, 'Expected positive ' + label)
    return value


def xml(text):
    # 내보내기 자료는 entity나 DTD를 쓰지 않는다. 참조는 아래의 명시적 ID/ref만 허용한다.
    require('<!DOCTYPE' not in text.upper() and '<!ENTITY' not in text.upper(), 'Unsupported XML declaration')
    try:
        return ET.fromstring(text)
    except ET.ParseError as error:
        raise ValueError('Invalid XML') from error


def macho_uuid(data):
    """별도 명령의 stdout 대신 실제 보관 실행 파일의 LC_UUID를 읽는다."""
    require(len(data) >= 32, 'Truncated Mach-O header')
    header = struct.unpack_from('<8I', data)
    require(header[0] == 0xfeedfacf, 'Expected thin little-endian 64-bit Mach-O')
    count, size = header[4:6]
    require(count > 0 and size >= count * 8 and 32 + size <= len(data), 'Invalid Mach-O command bounds')
    offset, values = 32, []
    for _ in range(count):
        require(offset + 8 <= 32 + size, 'Truncated Mach-O command')
        command, length = struct.unpack_from('<II', data, offset)
        require(length >= 8 and length % 8 == 0 and offset + length <= 32 + size, 'Invalid Mach-O command size')
        if command == 0x1b:
            require(length == 24, 'Invalid LC_UUID size')
            values.append(str(uuid.UUID(bytes=bytes(data[offset + 8:offset + 24]))).upper())
        offset += length
    require(offset == 32 + size and len(values) == 1, 'Expected exactly one LC_UUID')
    return values[0]


def target(toc_text, binary, expected_env):
    root = xml(toc_text)
    require(root.tag == 'trace-toc' and len(root.findall('run')) == 1, 'Expected one trace run')
    run = one(root, 'run')
    require(run.get('number') == '1', 'Unexpected trace run number')
    info = one(run, 'info')
    target_info = one(info, 'target')
    process = one(target_info, 'process')
    require(process.get('type') == 'launched' and process.get('name') == 'archived-test', 'Wrong launched target')
    require(process.get('arguments') == '--maru-expect-tests=5 --maru-expect-passed=5', 'Wrong target arguments')
    require(process.get('return-exit-status') == '0' and process.get('termination-reason') == 'exit(0)',
            'Target did not exit normally')
    summary = one(info, 'summary')
    require(one(summary, 'end-reason').text == 'Target app exited', 'Recording ended before target completion')
    require(one(summary, 'template-name').text == 'Time Profiler', 'Wrong recording template')
    environment = one(target_info, 'environment')
    items = environment.findall('item')
    require(len(items) == len(expected_env) and len({x.get('key') for x in items}) == len(items), 'Wrong target environment')
    require({x.get('key'): x.get('value') for x in items} == expected_env, 'Wrong target environment')
    pid = integer(process.get('pid'), 'target PID', True)
    matches = [x for x in one(run, 'processes') if x.tag == 'process' and x.get('pid') == str(pid)]
    require(len(matches) == 1 and matches[0].get('path') == binary and matches[0].get('name') == 'archived-test',
            'Wrong target executable path')
    tables = [x for x in one(run, 'data') if x.get('schema') == 'time-profile']
    require(len(tables) == 1 and tables[0].get('target-pid') == 'SINGLE'
            and tables[0].get('record-waiting-threads') == '0', 'Wrong profiling table configuration')
    return dict(pid=pid, instruments_version=one(summary, 'instruments-version').text)


class References:
    def __init__(self, root):
        self.ids = {}
        for node in root.iter():
            if 'id' in node.attrib:
                key = node.attrib['id']
                integer(key, 'ID', True)
                require(key not in self.ids and 'ref' not in node.attrib, 'Duplicate or ambiguous ID')
                self.ids[key] = node
            if 'ref' in node.attrib:
                integer(node.attrib['ref'], 'reference', True)
                require(set(node.attrib) == {'ref'} and len(node) == 0 and not (node.text or '').strip(),
                        'Ambiguous reference')
        # 사용되지 않은 잘못된 참조도 성공한 export 근거 안에 숨기지 않는다.
        for node in root.iter():
            if 'ref' in node.attrib:
                self.get(node)

    def get(self, node):
        require(node is not None, 'Missing referenced value')
        seen = set()
        while 'ref' in node.attrib:
            key = node.attrib['ref']
            require(key not in seen and key in self.ids, 'Missing or cyclic reference')
            seen.add(key)
            other = self.ids[key]
            require(other.tag == node.tag, 'Reference type mismatch')
            node = other
        return node


def exported_table(text):
    root = xml(text)
    require(root.tag == 'trace-query-result' and len(root) == 1 and root[0].tag == 'node', 'Wrong profile export root')
    table = root[0]
    schema = one(table, 'schema')
    require(schema.get('name') == 'time-profile', 'Wrong profile schema')
    require([(one(x, 'mnemonic').text, one(x, 'engineering-type').text) for x in schema] == list(COLUMNS),
            'Unknown profile column schema')
    require(all(x.tag in ('schema', 'row') for x in table), 'Unexpected profile table value')
    refs = References(root)
    return root, table, refs


def profile(text, pid, binary, binary_uuid, address_resolution):
    _, table, refs = exported_table(text)
    rows = table.findall('row')
    require(bool(rows), 'Empty profile population')
    counters = {name: Counter() for name in ('all', 'edit')}
    selfs = {name: Counter() for name in ('all', 'edit')}
    counts = Counter({key: 0 for key in (
        'rows', 'weight_ns', 'stack_rows', 'native_rows', 'edit_rows',
        'edit_weight_ns', 'missing_rows', 'missing_weight_ns', 'unresolved_rows', 'unresolved_frames',
        'recovered_image_rows', 'recovered_image_frames',
    )})
    states = Counter()
    entries = Counter({name: 0 for name in EDIT_CONTEXTS})
    seen, previous = set(), -1
    for row in rows:
        require(len(row) == 7 and [x.tag for x in row[:6]] == [x[1] for x in COLUMNS[:6]], 'Wrong profile row columns')
        process = refs.get(row[2])
        require(integer(refs.get(one(process, 'pid')).text, 'sample PID', True) == pid, 'Foreign sample PID')
        thread = refs.get(row[1])
        require(refs.get(one(thread, 'process')) is process, 'Thread process differs from sample process')
        tid = integer(refs.get(one(thread, 'tid')).text, 'thread ID', True)
        stamp = integer(refs.get(row[0]).text, 'sample time')
        require(stamp >= previous and (stamp, tid) not in seen, 'Duplicate or reordered sample')
        seen.add((stamp, tid))
        previous = stamp
        weight = integer(refs.get(row[5]).text, 'sample weight', True)
        integer(refs.get(row[3]).text, 'core')
        state = refs.get(row[4]).text
        require(state == 'Running', 'Unexpected sampled thread state')
        states[state] += 1
        counts['rows'] += 1
        counts['weight_ns'] += weight
        if row[-1].tag == 'sentinel':
            require(not row[-1].attrib and not list(row[-1]) and not (row[-1].text or '').strip(), 'Invalid missing-stack sentinel')
            counts['missing_rows'] += 1
            counts['missing_weight_ns'] += weight
            continue
        require(row[-1].tag == 'backtrace', 'Unknown stack value')
        stack = refs.get(row[-1])
        require(bool(len(stack)) and all(x.tag == 'frame' for x in stack), 'Empty or invalid stack')
        names, own, unresolved, recovered = [], [], 0, 0
        for item in stack:
            frame = refs.get(item)
            name = frame.get('name')
            require(bool(name) and re.fullmatch(r'0x[0-9a-fA-F]+', frame.get('addr', '')) is not None, 'Invalid stack frame')
            images = frame.findall('binary')
            require(len(images) <= 1, 'Ambiguous stack image')
            address_plan = address_resolution['plan']
            pc = int(frame.get('addr'), 16)
            if address_plan['lower'] <= pc < address_plan['upper']:
                require(hex(pc) in address_resolution['names'], 'Missing executable address resolution')
                if images:
                    image = refs.get(images[0])
                    require(image.get('path') == binary and image.get('name') == 'archived-test'
                            and image.get('UUID') == binary_uuid,
                            'Frame image conflicts with executable text')
                resolved_name = address_resolution['names'][hex(pc)]
                require(resolved_name is None or (type(resolved_name) is str and bool(resolved_name)), 'Invalid resolved symbol name')
                recovered += not images
                if resolved_name:
                    own.append(resolved_name)
                    names.append(resolved_name)
                else:
                    names.append('[unresolved-target-symbol]')
                    unresolved += 1
                continue
            if images:
                image = refs.get(images[0])
                is_target = image.get('path') == binary or image.get('name') == 'archived-test'
                if is_target:
                    require(image.get('path') == binary and image.get('UUID') == binary_uuid,
                            'Target image UUID or path differs')
                    names.append('[outside-target-text]')
                    unresolved += 1
                else:
                    names.append('[outside-target-text]')
            else:
                names.append('[outside-target-text]')
                unresolved += 1
            continue
        present_entries = set(EDIT_CONTEXTS).intersection(own)
        edit = bool(present_entries)
        entries.update(present_entries)
        counts['stack_rows'] += 1
        counts['unresolved_rows'] += bool(unresolved)
        counts['unresolved_frames'] += unresolved
        counts['recovered_image_rows'] += bool(recovered)
        counts['recovered_image_frames'] += recovered
        counts['native_rows'] += bool(NATIVE.intersection(own))
        counts['edit_rows'] += edit
        counts['edit_weight_ns'] += weight if edit else 0
        for bucket in ('all', 'edit') if edit else ('all',):
            # 재귀 호출의 중복 frame을 한 행의 포함 비용으로 여러 번 세지 않는다.
            counters[bucket].update({name: weight for name in set(names)})
            selfs[bucket][names[0]] += weight
    require(counts['stack_rows'] > 0, 'No usable thread stacks')
    require(counts['edit_rows'] > 0, 'No identifiable edit context')
    require(sum(selfs['all'].values()) + counts['missing_weight_ns'] == counts['weight_ns'], 'Unbalanced sample weight')
    require(sum(selfs['edit'].values()) == counts['edit_weight_ns'], 'Unbalanced edit weight')
    return dict(counts=dict(counts), states=dict(states), edit_entry_rows=dict(entries),
                inclusive_weight_ns={key: dict(value) for key, value in counters.items()},
                self_weight_ns={key: dict(value) for key, value in selfs.items()},
                interpretation='Sample weights; inclusive functions overlap. Only identified edit ancestry is classified; remaining rows are unclassified, not proven startup.')
