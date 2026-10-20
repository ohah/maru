"""Synthetic negative controls for the artifact gate, separate from native evidence."""
import json
from pathlib import Path
import tempfile
import unittest

from verify import verify


class ArtifactGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='maru-tree-verifier-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        rounds = []
        for number in range(1, 21):
            placement = (number - 1) % 5
            paused = 11 <= number <= 15
            result = dict(round=number, placement=placement, paused=paused, cli_samples=1)
            rounds.append(result)
            directory = self.root / f'round-{number:02d}'
            directory.mkdir()
            report = ['inspector-cursor label=row actual=hand']
            for phase in ('ready', 'selected', 'collapsed', 'searched', 'cleared', 'expanded', 'picked'):
                flags = 4 if paused and phase in ('collapsed', 'searched', 'cleared', 'expanded') else 0
                report.append(f'inspector label={phase} placement={placement+1} flags={flags}')
            (directory / 'report.txt').write_text('\n'.join(report))
            (directory / 'pixels.json').write_text(json.dumps(dict(outline_edge_changed_pixels=1)))
            (directory / 'observations.json').write_text('[{}]')
            for name in ('baseline', 'selected', 'collapsed', 'searched', 'picked') + (('detached',) if placement == 4 else ()):
                # Only the signature is needed to exercise this summary gate;
                # actual image pixels are checked by the native E2E producer.
                (directory / f'{name}.png').write_bytes(b'\x89PNG\r\n\x1a\n')
        (self.root / 'manifest.json').write_text(json.dumps(dict(passed=True, rounds=rounds)))

    def test_normal_and_equivalent_report(self):
        self.assertEqual(dict(rounds=20, cli_samples=20, pngs=104, outline_changed_pixels=20), verify(self.root))
        report = self.root / 'round-01/report.txt'
        report.write_text(report.read_text() + '\nindependent unrelated diagnostic\n')
        self.assertEqual(20, verify(self.root)['rounds'])

    def test_negative_controls_and_restoration(self):
        report = self.root / 'round-01/report.txt'
        text = report.read_text()
        paused = self.root / 'round-11/report.txt'
        manifest = self.root / 'manifest.json'
        fewer = json.loads(manifest.read_text())
        fewer['rounds'].pop()
        incomplete = json.loads(manifest.read_text())
        incomplete['passed'] = False
        cases = [
            ('cursor', report, text.replace('actual=hand', 'actual=arrow').encode()),
            ('placement', report, text.replace('placement=1', 'placement=2', 1).encode()),
            ('phase', report, text.replace('label=selected', 'label=missing').encode()),
            ('unexpected-pause', report, text.replace('flags=0', 'flags=4', 1).encode()),
            ('lost-pause', paused, paused.read_text().replace('label=collapsed placement=1 flags=4', 'label=collapsed placement=1 flags=0').encode()),
            ('zero-outline', self.root / 'round-01/pixels.json', b'{"outline_edge_changed_pixels":0}'),
            ('missing-image', self.root / 'round-01/selected.png', None),
            ('sample-count', self.root / 'round-01/observations.json', b'[]'),
            ('incomplete-rounds', manifest, json.dumps(fewer).encode()),
            ('failed-rounds', manifest, json.dumps(incomplete).encode()),
        ]
        for name, path, replacement in cases:
            with self.subTest(name=name):
                original = path.read_bytes()
                try:
                    if replacement is None:
                        path.unlink()
                    else:
                        path.write_bytes(replacement)
                    with self.assertRaises((AssertionError, FileNotFoundError)):
                        verify(self.root)
                finally:
                    path.write_bytes(original)
                self.assertEqual(20, verify(self.root)['rounds'])


if __name__ == '__main__':
    unittest.main()
