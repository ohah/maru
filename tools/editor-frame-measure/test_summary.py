"""누락·키 대응·시간 중첩과 합법적인 포함 시간을 독립 대조한다."""
import unittest
import summarize as subject


class FrameEvidenceTests(unittest.TestCase):
    def setUp(self):
        values = (200, 100, 300, 200, 100, 100, 50, 100, 200, 50, 700, 100, 100, 50, 50, 5, 20, 5, 10, 10)
        self.good = 'FRAME_WARM bracket_ready=1 views=1\n'
        for i in range(20):
            self.good += f'STORAGE key={i} total_ns=1000 delta_ns=10 copy_ns=20 index_ns=30 view_lines_ns=5 bytes={9+i} lines=1\n'
            self.good += f'FRAME key={i} ' + ' '.join(f'{name}={value}' for name, value in zip(subject.FIELDS, values)) + '\n'
        self.good += 'All 5 tests passed.\n'
        try:
            rows = subject.validate(self.good, 'typing', 8, 1)
        except ValueError as error:
            self.fail('Valid nested control was rejected: ' + str(error))
        self.assertEqual(len(rows), 20)

    def test_incomplete_warmup_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Missing complete bracket warm-up'):
            subject.validate(self.good.replace('FRAME_WARM bracket_ready=1 views=1\n', ''), 'typing', 8, 1)

    def test_missing_frame_record_is_rejected(self):
        text = '\n'.join(line for line in self.good.split('\n') if not line.startswith('FRAME key=7 '))
        with self.assertRaisesRegex(ValueError, 'Missing or mismatched frame key'):
            subject.validate(text, 'typing', 8, 1)

    def test_duplicate_key_cannot_replace_another_key(self):
        with self.assertRaisesRegex(ValueError, 'Missing or mismatched frame key'):
            subject.validate(self.good.replace('FRAME key=7 ', 'FRAME key=6 '), 'typing', 8, 1)

    def test_disjoint_edit_and_frame_cannot_exceed_total(self):
        with self.assertRaisesRegex(ValueError, 'intervals overlap'):
            subject.validate(self.good.replace('edit_ns=200 ', 'edit_ns=500 ', 1), 'typing', 8, 1)

    def test_child_must_fit_in_frame(self):
        with self.assertRaisesRegex(ValueError, 'Frame child exceeds'):
            subject.validate(self.good.replace('syntaxColors=100 ', 'syntaxColors=701 ', 1), 'typing', 8, 1)

    def test_refresh_must_fit_in_edit(self):
        with self.assertRaisesRegex(ValueError, 'Refresh exceeds edit'):
            subject.validate(self.good.replace('refreshViewAfterEditImpl=100 ', 'refreshViewAfterEditImpl=201 ', 1), 'typing', 8, 1)

    def test_inclusive_nested_times_must_not_be_added(self):
        rows = subject.validate(self.good, 'typing', 8, 1)
        self.assertGreater(sum(rows[0][key] for key in subject.FIELDS), rows[0]['total_ns'])
        self.assertEqual(rows[0]['appendPaneFrame'], 700)

    def current(self):
        return self.good.replace('bracketRefresh=', 'bracketUpdate=') + ''.join(
            f'FRAME_CALLS key={i} providerEdit_calls=1 bracketUpdate_calls=1\n' for i in range(20))

    def test_current_copy_or_refresh_interval_has_its_own_field(self):
        current = self.current()
        rows = subject.validate(current, 'typing', 8, 1, schema=2)
        self.assertEqual(rows[0]['bracketUpdate'], 10)
        self.assertNotIn('bracketRefresh', rows[0])
        for text, schema in ((current, 1), (self.good, 2)):
            with self.subTest(schema=schema), self.assertRaises(ValueError):
                subject.validate(text, 'typing', 8, 1, schema=schema)
        with self.assertRaisesRegex(ValueError, 'Current frame call records'):
            subject.validate(current.replace('bracketUpdate=', 'bracketRefresh='), 'typing', 8, 1)

    def test_mixed_or_malformed_extra_records_are_rejected(self):
        current = self.current()
        legacy_line = next(line for line in self.good.splitlines() if line.startswith('FRAME key='))
        for extra in (legacy_line, 'FRAME key=99 broken=1'):
            with self.subTest(extra=extra), self.assertRaisesRegex(ValueError, 'Malformed or mixed'):
                subject.validate(current + extra + '\n', 'typing', 8, 1, schema=2)

    def test_unknown_frame_schemas_are_rejected(self):
        for schema in (True, False, 0, 3, None, '2'):
            with self.subTest(schema=schema), self.assertRaisesRegex(ValueError, 'Unknown frame schema'):
                subject.validate(self.good, 'typing', 8, 1, schema=schema)

    def test_manifest_binds_names_version_and_bracket_operation(self):
        legacy = dict(frame_stages=list(subject.STAGES + subject.SYNTAX_STAGES))
        self.assertEqual(subject.contract.manifest_schema(legacy), 1)
        current = dict(frame_schema=2, frame_bracket_operation='copy-or-refresh',
                       frame_call_stages=['providerEdit', 'bracketUpdate'],
                       frame_stages=list(subject.STAGES + subject.contract.syntax_stages(2)))
        self.assertEqual(subject.contract.manifest_schema(current), 2)
        for changed in (dict(frame_schema=True), dict(frame_schema=1),
                        dict(frame_bracket_operation='refresh'), dict(frame_stages=legacy['frame_stages']),
                        dict(frame_call_stages=[])):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                subject.contract.manifest_schema(dict(current, **changed))

    def test_copy_or_refresh_interval_must_fit_in_syntax_edit(self):
        current = self.current()
        with self.assertRaisesRegex(ValueError, 'Disjoint syntax components'):
            subject.validate(current.replace('bracketUpdate=10', 'bracketUpdate=40', 1), 'typing', 8, 1, schema=2)

    def test_call_coverage_detects_missing_copy_path_and_bad_rows(self):
        current = self.current()
        missing = current.replace('FRAME_CALLS key=0 providerEdit_calls=1 bracketUpdate_calls=1\n', '')
        for text in (missing, current.replace('providerEdit_calls=1', 'providerEdit_calls=0', 1),
                     current.replace('bracketUpdate_calls=1', 'bracketUpdate_calls=0', 1),
                     current + 'FRAME_CALLS key=20 broken=1\n'):
            with self.subTest(text=text[-80:]), self.assertRaises(ValueError):
                subject.validate(text, 'typing', 8, 1, schema=2)


if __name__ == '__main__':
    unittest.main()
