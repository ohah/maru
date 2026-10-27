"""Reject mixed GUI scenes before copying sources, building, or launching any app."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class SaveAsCliTests(unittest.TestCase):
    def test_unrelated_scenes_rejected_before_side_effects(self):
        runner = Path(__file__).with_name('run.py')
        scenes = [
            ['--matrix'], ['--physical-ime'], ['--native-close-save'],
            ['--untitled-save-benchmark'], ['--unicode-field'], ['--disk-files', '2'],
            ['--narrow-hidden'], ['--replace-preview'], ['--replace-apply'],
            ['--replace-disk-apply'], ['--replace-ime-refuse'], ['--replace-batch'],
            ['--replace-batch-save-retry'],
        ]
        for scene in scenes:
            with self.subTest(scene=scene), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / 'must-not-be-created'
                result = subprocess.run(
                    [sys.executable, str(runner), '--save-as-command', '--save-as-only',
                     '--output', str(output)] + scene, capture_output=True, text=True,
                    timeout=10,
                )
                self.assertEqual(result.returncode, 2)
                self.assertIn('Save As-only must run independently', result.stderr)
                self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
