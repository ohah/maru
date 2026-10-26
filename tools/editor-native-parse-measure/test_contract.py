"""잘못된 계수가 터미널 편집기의 지연 개선 근거가 되지 않게 제품 대응·형식을 대조한다."""
import unittest
import contract


class NativeContractTests(unittest.TestCase):
    def setUp(self):
        self.providers = [dict(key=i, native_calls=1, changed_ranges_calls=1) for i in range(20)]
        self.frames = [dict(key=i, bytes=100 + i) for i in range(20)]
        self.rows = []
        for i in range(20):
            self.rows.append(dict(key=i, calls=1, old_tree_calls=1, source_bytes=100 + i,
                                  budget_ns=0, done=1, pending=0, read_calls=4, eof_calls=1,
                                  offered_bytes=2 * (100 + i), progress_calls=5, cancel_returns=0,
                                  range_calls=1, range_items=0, nonempty_ranges=0))

    def text(self):
        return ''.join('NATIVE_PROBE schema=1 key=' + str(row['key']) + ' '
                       + ' '.join(name + '=' + str(row[name]) for name in contract.FIELDS) + '\n'
                       for row in self.rows)

    def check(self, text=None):
        return contract.read_probe(self.text() if text is None else text, self.providers, self.frames)

    def test_valid_repeated_offers_may_exceed_source_size(self):
        rows = self.check()
        self.assertEqual(len(rows), 20)
        self.assertGreater(rows[0]['offered_bytes'], rows[0]['source_bytes'])

    def test_old_tree_absence_and_zero_callbacks_are_observations(self):
        self.rows[0].update(old_tree_calls=0, read_calls=0, eof_calls=0, offered_bytes=0, progress_calls=0)
        self.assertEqual(self.check()[0]['old_tree_calls'], 0)

    def test_missing_duplicate_and_reordered_keys_are_rejected(self):
        text = self.text().splitlines(True)
        for changed in [text[:3] + text[4:], text[:3] + [text[2]] + text[4:], list(reversed(text))]:
            with self.subTest(changed=changed[0]), self.assertRaises(ValueError):
                self.check(''.join(changed))

    def test_unknown_schema_fields_or_trailing_data_are_rejected(self):
        for text in [self.text().replace('schema=1', 'schema=2', 1),
                     self.text().replace('calls=1', 'calls=-1', 1),
                     self.text().replace('nonempty_ranges=0\n', 'nonempty_ranges=0 extra=1\n', 1)]:
            with self.subTest(text=text[:60]), self.assertRaises(ValueError):
                self.check(text)

    def test_product_source_and_call_correspondence_are_required(self):
        for field, value in [('source_bytes', 101), ('calls', 0), ('old_tree_calls', 2),
                             ('done', 0), ('range_calls', 0)]:
            with self.subTest(field=field):
                old = self.rows[0][field]
                self.rows[0][field] = value
                with self.assertRaises(ValueError):
                    self.check()
                self.rows[0][field] = old

    def test_impossible_callback_or_range_totals_are_rejected(self):
        for field, value in [('eof_calls', 5), ('offered_bytes', 301), ('offered_bytes', 2),
                             ('cancel_returns', 6), ('nonempty_ranges', 2), ('range_items', 1),
                             ('budget_ns', 2**64)]:
            with self.subTest(field=field, value=value):
                old = self.rows[0][field]
                self.rows[0][field] = value
                with self.assertRaises(ValueError):
                    self.check()
                self.rows[0][field] = old

    def test_boolean_schema_cannot_impersonate_integer_version(self):
        setup = dict(native_probe_schema=True, native_probe_fields=list(contract.FIELDS),
                     provider_schema=3, frame_schema=2, provider_execution='revision-snapshots')
        with self.assertRaisesRegex(ValueError, 'Unsupported diagnostic execution schema'):
            contract.validate('', 'typing', b'x', 'flat-3000.zig', setup)


if __name__ == '__main__':
    unittest.main()
