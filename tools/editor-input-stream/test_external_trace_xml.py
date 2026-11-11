"""포맷된 시간·다른 PID·틀린 참조로 프레임을 엮지 않는다."""
from pathlib import Path
import tempfile
import unittest
import external_trace_xml as xml


class ExternalTraceXML(unittest.TestCase):
    def table(self,text,name='test'):
        with tempfile.TemporaryDirectory() as root:
            path=Path(root)/'rows.xml';path.write_text(text);return xml.Table(path,name)

    def test_raw_integer_ignores_formatted_time_and_resolves_references(self):
        t=self.table('<root><schema name="test"><col><mnemonic>start</mnemonic></col></schema><row><start-time id="1" fmt="wrong">123</start-time></row><row><start-time ref="1"/></row></root>')
        self.assertEqual([t.integer(r['start']) for r in t.rows],[123,123])

    def test_bad_schema_duplicate_ids_width_and_noninteger_are_rejected(self):
        texts=['<root><schema name="wrong"/></root>',
            '<root><schema name="test"><col><mnemonic>x</mnemonic></col></schema><row/>',
            '<root><schema name="test"/><v id="1"/><v id="1"/></root>',
            '<root><schema name="test"><col><mnemonic>x</mnemonic></col><col><mnemonic>x</mnemonic></col></schema></root>']
        for text in texts:
            with self.assertRaises((ValueError,xml.ET.ParseError)):self.table(text)
        t=self.table('<root><schema name="test"><col><mnemonic>x</mnemonic></col></schema><row><v fmt="123">1.23</v></row></root>')
        with self.assertRaises(ValueError):t.integer(t.rows[0]['x'])

    def test_missing_and_cyclic_references_are_rejected(self):
        for body in ('<v ref="missing"/>','<v id="1" ref="2"/><v id="2" ref="1"/>'):
            text='<root><schema name="test"><col><mnemonic>x</mnemonic></col></schema><row><v ref="1"/></row>'+body+'</root>'
            t=self.table(text)
            with self.assertRaises(ValueError):t.integer(t.rows[0]['x'])

    def test_epoch_requires_one_stable_positive_rational_timebase(self):
        text='<root><schema name="test"><col><mnemonic>mabs-epoch</mnemonic></col><col><mnemonic>timebase-info</mnemonic></col></schema><row><v>7</v><base><v>125</v><v>3</v></base></row></root>'
        self.assertEqual(xml.epoch(self.table(text)),291)
        for changed in (text.replace('<v>3</v>','<v>0</v>'),text.replace('<v>7</v>','<v>-1</v>')):
            with self.assertRaises(ValueError):xml.epoch(self.table(changed))

    def test_exact_label_and_pid_are_required_and_duplicates_rejected(self):
        schema='<schema name="test">'+''.join('<col><mnemonic>'+n+'</mnemonic></col>' for n in ('process','cmdbuffer-id','start','duration','event-label'))+'</schema>'
        row='<row><process><pid>42</pid></process><id>99</id><start>100</start><duration>20</duration><narrative><metal-object-label>maru-submit:2:12345</metal-object-label></narrative></row>'
        t=self.table('<root>'+schema+row+'</root>')
        self.assertEqual(xml.submissions(t,42)['maru-submit:2:12345']['committed'],120)
        self.assertEqual(xml.submissions(t,43),{})
        with self.assertRaises(ValueError):xml.submissions(self.table('<root>'+schema+row+row+'</root>'),42)

    def test_submission_faults_do_not_fall_back_to_nearby_timestamps(self):
        schema='<schema name="test">'+''.join('<col><mnemonic>'+n+'</mnemonic></col>' for n in ('process','cmdbuffer-id','start','duration','event-label'))+'</schema>'
        row='<row><process><pid>42</pid></process><id>99</id><start>100</start><duration>20</duration><narrative><metal-object-label>maru-submit:2:12345</metal-object-label></narrative></row>'
        faults=[row.replace('<id>99</id>','<id>0</id>'),row.replace('<start>100</start>','<start>-1</start>'),
                row.replace('<duration>20</duration>','<duration>-1</duration>'),row.replace('<pid>42</pid>','<pid>42.0</pid>'),
                row.replace('<pid>42</pid>',''),row.replace('</narrative>','<metal-object-label>maru-submit:3:12346</metal-object-label></narrative>'),
                row+row.replace('maru-submit:2:12345','maru-submit:3:12346')]
        for fault in faults:
            with self.assertRaises(ValueError):xml.submissions(self.table('<root>'+schema+fault+'</root>'),42)
        t=self.table('<root>'+schema+row.replace('maru-submit:2:12345','other-submit:2:12345')+'</root>')
        self.assertEqual(xml.submissions(t,42),{})
        t=self.table('<root>'+schema+row.replace('<id>99</id>','<id ref="missing"/>')+'</root>')
        with self.assertRaises(ValueError):xml.submissions(t,42)

    def test_nested_label_reference_cycle_is_rejected(self):
        t=self.table('<root><schema name="test"><col><mnemonic>label</mnemonic></col></schema><row><narrative id="1"><narrative ref="1"/></narrative></row></root>')
        with self.assertRaises(ValueError):t.labels(t.rows[0]['label'])
