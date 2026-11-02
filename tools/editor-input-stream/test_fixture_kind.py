"""후보가 없는 한 줄 함수와 접힘 후보가 있는 여러 줄 함수를 구분한다."""
import unittest
import protocol

class FixtureKind(unittest.TestCase):
    def test_flat_default_is_unchanged(self):
        self.assertEqual(protocol.fixture(3000),protocol.fixture(3000,'flat'))
        self.assertEqual(protocol.fixture(3000).count(b'\n'),3001)
    def test_multiline_has_one_body_per_function(self):
        for size in (3000,50000):
            value=protocol.fixture(size,'multiline')
            self.assertTrue(value.startswith(b'// \n'))
            self.assertEqual(value.count(b'}\n'),size)
            self.assertEqual(value.count(b'\n'),size*4+1)
            self.assertIn(b'void {\n    const value:',value)
            self.assertNotEqual(value,protocol.fixture(size))
    def test_unknown_or_invalid_size_is_rejected(self):
        for size,kind in ((3000,'other'),(True,'flat'),(1,'multiline')):
            with self.subTest(size=size,kind=kind),self.assertRaises(ValueError):protocol.fixture(size,kind)
