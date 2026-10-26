"""JSON의 타입 혼동으로 터미널 편집기의 잘못된 측정 형식이 채택되지 않게 한다."""
import unittest
import contract


class SchemaTypeTests(unittest.TestCase):
    def test_all_versions_require_integer_types(self):
        good = dict(native_probe_schema=1, native_probe_fields=list(contract.FIELDS),
                    provider_schema=3, frame_schema=2, provider_execution='revision-snapshots')
        for field, value in [('native_probe_schema', 1.0), ('provider_schema', 3.0),
                             ('frame_schema', 2.0), ('native_probe_schema', True)]:
            with self.subTest(field=field, value=value):
                setup = good | {field: value}
                with self.assertRaisesRegex(ValueError, 'Unsupported diagnostic execution schema'):
                    contract.validate('', 'typing', b'x', 'flat-3000.zig', setup)


if __name__ == '__main__':
    unittest.main()
