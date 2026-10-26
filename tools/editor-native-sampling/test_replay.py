"""표시 이름이 달라도 사실은 같고, weight/PC가 바뀌면 trace 사실이 달라짐을 검사한다."""
import unittest
import xml.etree.ElementTree as ET

import replay
from test_stacks import fixture


def canonical(root):
    return replay.canonical(ET.tostring(root, encoding='unicode'))


class ReplayTests(unittest.TestCase):
    def test_display_names_do_not_change_sample_facts(self):
        root = fixture()
        original = canonical(root)
        for frame in root.iter('frame'):
            if frame.get('name'):
                frame.set('name', 'display-only')
        self.assertEqual(canonical(root), original)

    def test_weight_and_program_counter_changes_are_visible(self):
        original = canonical(fixture())
        root = fixture()
        root.find('.//weight').text = '2000000'
        self.assertNotEqual(canonical(root), original)
        root = fixture()
        root.find('.//frame').set('addr', '0x11')
        self.assertNotEqual(canonical(root), original)

    def test_id_renumbering_does_not_change_actual_sample_values(self):
        root = fixture()
        original = canonical(root)
        for node in root.iter():
            for key in ('id', 'ref'):
                if key in node.attrib:
                    node.set(key, str(int(node.get(key)) + 100))
        self.assertEqual(canonical(root), original)

    def test_unknown_sdk_column_contract_is_rejected(self):
        root = fixture()
        root.find('.//col/engineering-type').text = 'different-unit'
        with self.assertRaisesRegex(ValueError, 'Unknown profile column schema'):
            canonical(root)


if __name__ == '__main__':
    unittest.main()
