"""Mach-O 코드 경계와 주소 해석의 출처가 raw 표시 이름보다 우선함을 검사한다."""
from pathlib import Path
import struct
import tempfile
import unittest
import uuid
import xml.etree.ElementTree as ET

import stacks
import symbols
from test_stacks import fixture, UUID


def executable():
    segment = struct.pack('<II16sQQQQiiII', 0x19, 152, b'__TEXT', 0x100000000, 4096, 0, 1024, 7, 5, 1, 0)
    section = struct.pack('<16s16sQQIIIIIIII', b'__text', b'__TEXT', 0x100000200, 64, 512, 2, 0, 0, 0x80000400, 0, 0, 0)
    identity = struct.pack('<II', 0x1b, 24) + uuid.UUID(UUID).bytes
    header = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 2, 176, 0, 0)
    return bytearray((header + segment + section + identity).ljust(1024, b'\0'))


def address_fixture(binary):
    root = fixture()
    image = root.find('.//binary')
    image.set('path', str(binary))
    image.set('load-addr', '0x20000000')
    leaf = root.find('.//frame[@id="11"]')
    leaf.set('addr', '0x20000224')
    leaf.set('name', 'not-a-trusted-label')
    parent = root.find('.//frame[@id="13"]')
    parent.set('addr', '0x20000214')
    parent.set('name', '0x20000213')
    parent.remove(parent.find('binary'))
    return root


class SymbolTests(unittest.TestCase):
    def test_text_region_is_bounded_by_segment_and_file(self):
        self.assertEqual(symbols.text_region(executable()), dict(vmaddr=0x100000000, start=0x100000200, end=0x100000240))
        for offset, value in ((32 + 64, 999), (32 + 60, 1), (32 + 72 + 40, 99999)):
            with self.subTest(offset=offset):
                data = executable()
                struct.pack_into('<I', data, offset, value)
                with self.assertRaises(ValueError):
                    symbols.text_region(data)

    def test_missing_frame_image_can_be_recovered_only_inside_actual_text(self):
        with tempfile.TemporaryDirectory() as raw:
            binary = Path(raw) / 'archived-test'
            binary.write_bytes(executable())
            root = address_fixture(binary)
            text = ET.tostring(root, encoding='unicode')
            plan = symbols.plan(text, binary, UUID)
            self.assertEqual(plan['pcs'], ['0x20000214', '0x20000224'])
            resolution = dict(plan=plan, names={'0x20000214': stacks.EDIT_CONTEXT,
                                               '0x20000224': 'ts_parser_parse_with_options'})
            result = stacks.profile(text, 42, str(binary), UUID, resolution)
            self.assertEqual(result['counts']['edit_rows'], 2)
            self.assertEqual(result['counts']['recovered_image_frames'], 2)
            parent = root.find('.//frame[@id="13"]')
            parent.set('addr', '0x30000000')
            parent.set('name', stacks.EDIT_CONTEXT)
            text = ET.tostring(root, encoding='unicode')
            resolution['plan'] = symbols.plan(text, binary, UUID)
            resolution['names'] = {'0x20000224': 'ts_parser_parse_with_options'}
            with self.assertRaisesRegex(ValueError, 'No identifiable edit context'):
                stacks.profile(text, 42, str(binary), UUID, resolution)

    def test_image_address_conflict_is_not_an_unresolved_symbol(self):
        with tempfile.TemporaryDirectory() as raw:
            binary = Path(raw) / 'archived-test'
            binary.write_bytes(executable())
            root = address_fixture(binary)
            leaf = root.find('.//frame[@id="11"]')
            image = leaf.find('binary')
            leaf.remove(image)
            root.find('.//frame[@id="13"]').append(image)
            leaf.append(ET.Element('binary', id='20', name='other', path='/tmp/other', UUID=UUID))
            with self.assertRaisesRegex(ValueError, 'Frame image conflicts with executable text'):
                symbols.plan(ET.tostring(root, encoding='unicode'), binary, UUID)

    def test_atos_source_lines_and_offsets_have_exact_address_coverage(self):
        text = 'function (in archived-test) (source.zig:2)\nother (in archived-test) + 20\n0x1234\n'
        self.assertEqual(symbols.names_from_output(text, ['0x1', '0x2', '0x3']),
                         {'0x1': 'function', '0x2': 'other', '0x3': None})
        with self.assertRaisesRegex(ValueError, 'Atos output population differs'):
            symbols.names_from_output(text, ['0x1'])
        with self.assertRaisesRegex(ValueError, 'Atos output image differs'):
            symbols.names_from_output('function (in another) + 20\n', ['0x1'])

    def test_all_addresses_are_retained_when_command_arguments_are_chunked(self):
        plan = dict(load_address=0x20000000, pcs=[hex(0x20000200 + n) for n in range(600)])
        calls = symbols.commands(Path('/tmp/symbol'), plan)
        self.assertEqual([p for call in calls for p in call[6:]], plan['pcs'])
        self.assertEqual(len(calls), 3)


if __name__ == '__main__':
    unittest.main()
