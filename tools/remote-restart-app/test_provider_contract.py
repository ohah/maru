"""Provider failure must terminate waiting without publishing GUI success."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock

spec = importlib.util.spec_from_file_location('provider_probe', Path(__file__).with_name('run.py'))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class ProviderCompletionTests(unittest.TestCase):
    def test_failure_and_gui_exit_override_done(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            child = Mock()
            child.poll.return_value = None
            self.assertFalse(probe.providers_completed(root, child))
            (root / 'provider-done').touch()
            self.assertTrue(probe.providers_completed(root, child))
            for provider in ['claude', 'codex']:
                (root / 'provider-failure.json').write_text(json.dumps({'provider': provider, 'exit_code': 1}))
                with self.assertRaisesRegex(RuntimeError, provider + ' exit=1'):
                    probe.providers_completed(root, child)
            (root / 'provider-failure.json').unlink()
            for code in [0, 1, -6]:
                child.poll.return_value = code
                with self.assertRaisesRegex(RuntimeError, 'GUI exited'):
                    probe.providers_completed(root, child)


if __name__ == '__main__':
    unittest.main()
