"""exit 0만으로 채택되지 않도록 유효 XML의 의미 손상과 정상 대조를 검사한다."""
import copy
import struct
import unittest
import uuid
import xml.etree.ElementTree as ET

import stacks

UUID = '8F0B2E84-3728-3DCD-9355-A1C6DC9B4805'
BINARY = '/tmp/archived-test'


def fixture():
    columns = ''.join('<col><mnemonic>' + name + '</mnemonic><name>display</name>'
                      '<engineering-type>' + kind + '</engineering-type></col>' for name, kind in stacks.COLUMNS)
    return ET.fromstring('''<trace-query-result><node><schema name="time-profile">''' + columns + '''</schema>
<row><sample-time id="1">100</sample-time><thread id="2"><tid id="3">7</tid>
<process id="4"><pid id="5">42</pid><device-session id="6">test</device-session></process></thread>
<process ref="4"/><core id="7">0</core><thread-state id="8">Running</thread-state><weight id="9">1000000</weight>
<backtrace id="10"><frame id="11" name="ts_parser_parse_with_options" addr="0x10">
<binary id="12" name="archived-test" path="/tmp/archived-test" UUID="''' + UUID + '''"/></frame>
<frame id="13" name="''' + stacks.EDIT_CONTEXT + '''" addr="0x20"><binary ref="12"/></frame></backtrace></row>
<row><sample-time id="14">200</sample-time><thread ref="2"/><process ref="4"/><core ref="7"/>
<thread-state ref="8"/><weight ref="9"/><sentinel/></row>
<row><sample-time id="15">300</sample-time><thread ref="2"/><process ref="4"/><core ref="7"/>
<thread-state ref="8"/><weight ref="9"/><backtrace ref="10"/></row></node></trace-query-result>''')


def resolution():
    return {'plan': {'lower': 0x10, 'upper': 0x30},
            'names': {'0x10': 'ts_parser_parse_with_options', '0x20': stacks.EDIT_CONTEXT}}


def parse(root, addresses=None):
    return stacks.profile(ET.tostring(root, encoding='unicode'), 42, BINARY, UUID,
                          resolution() if addresses is None else addresses)


class StackTests(unittest.TestCase):
    def test_real_weights_include_missing_stacks(self):
        result = parse(fixture())
        self.assertEqual(result['counts'], dict(rows=3, weight_ns=3000000, stack_rows=2,
            native_rows=2, edit_rows=2, edit_weight_ns=2000000, missing_rows=1, missing_weight_ns=1000000,
            unresolved_rows=0, unresolved_frames=0, recovered_image_rows=0, recovered_image_frames=0))

    def test_recursive_frames_do_not_duplicate_inclusive_weight(self):
        root = fixture()
        trace = root.find('.//backtrace')
        trace.insert(1, ET.Element('frame', ref='11'))
        result = parse(root)
        self.assertEqual(result['inclusive_weight_ns']['edit']['ts_parser_parse_with_options'], 2000000)
        self.assertEqual(result['self_weight_ns']['edit']['ts_parser_parse_with_options'], 2000000)

    def test_no_thread_stacks_or_no_edit_ancestry_is_not_a_profile(self):
        root = fixture()
        table = root[0]
        for row in table.findall('row'):
            table.remove(row)
        with self.assertRaisesRegex(ValueError, 'Empty profile population'):
            parse(root)
        root = fixture()
        addresses = resolution()
        addresses['names']['0x20'] = 'startup-only'
        with self.assertRaisesRegex(ValueError, 'No identifiable edit context'):
            parse(root, addresses)

    def test_native_edit_entry_remains_identifiable_when_host_wrapper_is_inlined(self):
        root = fixture()
        addresses = resolution()
        addresses['names']['0x20'] = 'tree_sitter.Provider.onEditBudgeted'
        result = parse(root, addresses)
        self.assertEqual(result['counts']['edit_rows'], 2)

    def test_foreign_pid_and_target_uuid_are_rejected(self):
        root = fixture()
        root.find('.//pid').text = '43'
        with self.assertRaisesRegex(ValueError, 'Foreign sample PID'):
            parse(root)
        root = fixture()
        root.find('.//binary').set('UUID', '00000000-0000-0000-0000-000000000000')
        with self.assertRaisesRegex(ValueError, 'Frame image conflicts with executable text'):
            parse(root)

    def test_foreign_library_cannot_supply_an_edit_marker(self):
        root = fixture()
        image = root.find('.//binary')
        image.set('name', 'unrelated-library')
        image.set('path', '/tmp/unrelated-library')
        with self.assertRaisesRegex(ValueError, 'Frame image conflicts with executable text'):
            parse(root)

    def test_initial_unresolved_addresses_are_kept_without_native_identity(self):
        root = fixture()
        leaf = root.find('.//frame[@id="11"]')
        image = leaf.find('binary')
        leaf.remove(image)
        parent = root.find('.//frame[@id="13"]')
        parent.remove(parent.find('binary'))
        parent.append(image)
        addresses = resolution()
        addresses['names']['0x10'] = None
        for label in ('0x10', 'ts_parser_parse_with_options', stacks.EDIT_CONTEXT):
            leaf.set('name', label)
            result = parse(root, addresses)
            self.assertEqual(result['counts']['unresolved_rows'], 2)
            self.assertEqual(result['counts']['unresolved_frames'], 2)
            self.assertEqual(result['counts']['recovered_image_rows'], 2)
            self.assertEqual(result['counts']['native_rows'], 0)
            self.assertEqual(result['self_weight_ns']['all']['[unresolved-target-symbol]'], 2000000)
        addresses['names']['0x20'] = 'initial-only'
        with self.assertRaisesRegex(ValueError, 'No identifiable edit context'):
            parse(root, addresses)

    def test_valid_xml_with_bad_reference_semantics_is_rejected(self):
        cases = [('999', 'Missing or cyclic reference'), ('11', 'Reference type mismatch')]
        for ref, message in cases:
            with self.subTest(ref=ref):
                root = fixture()
                root.find('.//row/process').set('ref', ref)
                with self.assertRaisesRegex(ValueError, message):
                    parse(root)
        root = fixture()
        root.find('.//frame[@id="13"]').set('id', '11')
        with self.assertRaisesRegex(ValueError, 'Duplicate or ambiguous ID'):
            parse(root)

    def test_wrong_engineering_type_is_not_accepted_by_display_label(self):
        root = fixture()
        root.find('.//col/engineering-type').text = 'duration'
        with self.assertRaisesRegex(ValueError, 'Unknown profile column schema'):
            parse(root)

    def test_duplicate_samples_and_noninteger_weights_are_rejected(self):
        root = fixture()
        root.find('.//sample-time[@id="15"]').text = '200'
        with self.assertRaisesRegex(ValueError, 'Duplicate or reordered sample'):
            parse(root)
        for value in ('-1', '1.0', '01', 'true', '0'):
            with self.subTest(value=value):
                root = fixture()
                root.find('.//weight').text = value
                with self.assertRaises(ValueError):
                    parse(root)

    def test_unclassified_frames_are_not_declared_startup(self):
        root = fixture()
        table = root[0]
        row = copy.deepcopy(table.findall('row')[-1])
        row[0].set('id', '16')
        row[0].text = '400'
        row[-1].attrib.clear()
        row[-1].append(ET.Element('frame', ref='11'))
        table.append(row)
        result = parse(root)
        self.assertEqual(result['counts']['stack_rows'], 3)
        self.assertEqual(result['counts']['edit_rows'], 2)
        self.assertIn('unclassified', result['interpretation'])

    def test_executable_uuid_comes_from_bounded_macho_commands(self):
        command = struct.pack('<II', 0x1b, 24) + uuid.UUID(UUID).bytes
        header = lambda count, size: struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, count, size, 0, 0)
        data = header(1, len(command)) + command
        self.assertEqual(stacks.macho_uuid(data), UUID)
        for changed in (data[:-1], b'not-macho', header(2, 48) + command * 2):
            with self.subTest(size=len(changed)), self.assertRaises(ValueError):
                stacks.macho_uuid(changed)


if __name__ == '__main__':
    unittest.main()
