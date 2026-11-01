"""표시 이름 대신 실행 이미지의 코드 주소와 보관 dSYM을 대조한다."""
import hashlib
from pathlib import Path
import re
import struct
import subprocess

import stacks

_CACHE = {}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def hexadecimal(text):
    stacks.require(isinstance(text, str) and re.fullmatch(r'0x[0-9a-fA-F]+', text) is not None, 'Invalid code address')
    value = int(text, 16)
    stacks.require(value < 1 << 64, 'Code address exceeds 64 bits')
    return value


def text_region(data):
    """공개 SDK loader.h의 segment_command_64/section_64만 읽는다. 함수 크기는 추측하지 않는다."""
    stacks.macho_uuid(data)
    count, size = struct.unpack_from('<II', data, 16)
    offset, regions = 32, []
    for _ in range(count):
        command, length = struct.unpack_from('<II', data, offset)
        if command == 0x19:
            stacks.require(length >= 72, 'Truncated segment command')
            name = data[offset + 8:offset + 24].rstrip(b'\0')
            vmaddr, vmsize, fileoff, filesize, _, protection, sections, _ = struct.unpack_from('<QQQQiiII', data, offset + 24)
            stacks.require(72 + sections * 80 <= length, 'Section table exceeds segment command')
            if name == b'__TEXT':
                stacks.require(protection & 4 and vmaddr + vmsize < 1 << 64 and fileoff + filesize <= len(data),
                               'Invalid executable segment bounds')
                for index in range(sections):
                    base = offset + 72 + index * 80
                    section = data[base:base + 16].rstrip(b'\0')
                    segment = data[base + 16:base + 32].rstrip(b'\0')
                    if section == b'__text':
                        address, length_bytes, file_offset = struct.unpack_from('<QQI', data, base + 32)
                        stacks.require(segment == b'__TEXT' and length_bytes > 0
                            and vmaddr <= address < address + length_bytes <= vmaddr + vmsize
                            and fileoff <= file_offset < file_offset + length_bytes <= fileoff + filesize,
                            'Invalid executable text bounds')
                        regions.append(dict(vmaddr=vmaddr, start=address, end=address + length_bytes))
        offset += length
    stacks.require(offset == 32 + size and len(regions) == 1, 'Expected one executable text section')
    return regions[0]


def bundle_command(root, binary):
    return ['xcrun', 'dsymutil', str(binary), '-o', str(root / 'symbols.dSYM')]


def symbol_file(root, expected_uuid, binary_name="archived-test"):
    path = root / 'symbols.dSYM/Contents/Resources/DWARF' / binary_name
    stacks.require(path.is_file() and stacks.macho_uuid(path.read_bytes()) == expected_uuid, 'Debug symbol UUID differs')
    return path


def plan(text, binary, binary_uuid, binary_name="archived-test"):
    root, _, refs = stacks.exported_table(text)
    region = text_region(binary.read_bytes())
    loads = set()
    for node in root.iter('binary'):
        image = refs.get(node)
        if image.get('path') == str(binary) or image.get('name') == binary_name:
            stacks.require(image.get('path') == str(binary) and image.get('name') == binary_name
                           and image.get('UUID') == binary_uuid, 'Target image UUID or path differs')
            loads.add(hexadecimal(image.get('load-addr')))
    stacks.require(len(loads) == 1, 'Missing or ambiguous executable load address')
    load = loads.pop()
    lower = load + region['start'] - region['vmaddr']
    upper = load + region['end'] - region['vmaddr']
    stacks.require(0 <= lower < upper < 1 << 64, 'Invalid loaded text bounds')
    pcs = set()
    for node in root.iter('frame'):
        frame = refs.get(node)
        pc = hexadecimal(frame.get('addr'))
        if lower <= pc < upper:
            images = frame.findall('binary')
            stacks.require(len(images) <= 1, 'Ambiguous stack image')
            if images:
                image = refs.get(images[0])
                stacks.require(image.get('path') == str(binary) and image.get('UUID') == binary_uuid,
                               'Frame image conflicts with executable text')
            pcs.add(pc)
    stacks.require(bool(pcs), 'No executable code addresses')
    return dict(load_address=load, lower=lower, upper=upper, pcs=[hex(x) for x in sorted(pcs)])


def commands(symbol, address_plan):
    pcs = address_plan['pcs']
    # 전체 주소를 처리하되 argv 크기만 나눈다. 표본이나 첫 입력을 줄이지 않는다.
    return [['xcrun', 'atos', '-o', str(symbol), '-l', hex(address_plan['load_address']), *pcs[i:i + 256]]
            for i in range(0, len(pcs), 256)]


def names_from_output(text, pcs, binary_name="archived-test"):
    lines = text.splitlines()
    stacks.require(len(lines) == len(pcs), 'Atos output population differs')
    names = {}
    for pc, line in zip(pcs, lines):
        if re.fullmatch(r'0x[0-9a-fA-F]+', line.strip()) or line.strip() == '???':
            names[pc] = None
            continue
        match = re.fullmatch(r'(.+) \(in '+re.escape(binary_name)+r'\)(?: \(.*\)| \+ [0-9]+)?', line.strip())
        stacks.require(match is not None, 'Atos output image differs')
        name = match[1]
        names[pc] = None if re.fullmatch(r'0x[0-9a-fA-F]+', name) else name
    return names


def collect(folder, text, binary, symbol, binary_uuid, binary_name="archived-test"):
    address_plan = plan(text, binary, binary_uuid, binary_name)
    calls = commands(symbol, address_plan)
    names = {}
    for index, command in enumerate(calls):
        result = subprocess.run(command, capture_output=True, text=True)
        for suffix, value in (('stdout', result.stdout), ('stderr', result.stderr)):
            with (folder / f'atos-{index:03d}.{suffix}').open('x') as stream:
                stream.write(value)
        stacks.require(result.returncode == 0, 'Atos resolution failed; raw output preserved')
        names.update(names_from_output(result.stdout, command[6:], binary_name))
    return dict(schema=1, plan=address_plan, commands=calls, names=names)


def checked(folder, text, binary, symbol, binary_uuid, saved, binary_name="archived-test"):
    address_plan = plan(text, binary, binary_uuid, binary_name)
    calls = commands(symbol, address_plan)
    stacks.require(type(saved.get('schema')) is int and saved['schema'] == 1, 'Wrong address resolution schema')
    stacks.require(saved.get('plan') == address_plan and saved.get('commands') == calls, 'Atos address coverage or command differs')
    recorded = {}
    for index, command in enumerate(calls):
        recorded.update(names_from_output((folder / f'atos-{index:03d}.stdout').read_text(), command[6:], binary_name))
    stacks.require(saved.get('names') == recorded, 'Recorded address names differ from raw output')
    # 새 사본에서도 dSYM 바이트를 확인한다. 같은 불변 자료의 재검사는 SDK 실행 결과만 재사용한다.
    key = (sha(symbol), binary_uuid, address_plan['load_address'], tuple(address_plan['pcs']))
    if key not in _CACHE:
        replay = {}
        for command in calls:
            result = subprocess.run(command, capture_output=True, text=True)
            stacks.require(result.returncode == 0, 'Atos SDK replay failed')
            replay.update(names_from_output(result.stdout, command[6:], binary_name))
        _CACHE[key] = replay
    stacks.require(recorded == _CACHE[key], 'Address names differ from SDK replay')
    return dict(plan=address_plan, names=recorded)
