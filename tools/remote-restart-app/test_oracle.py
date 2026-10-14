#!/usr/bin/env python3
"""Reject missing or foreign GUI evidence by mutating an actual local provider trace."""
import argparse, importlib.util, re
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument('--artifact', required=True)
args = ap.parse_args()
spec = importlib.util.spec_from_file_location('provider_probe', Path(__file__).with_name('run.py'))
probe = importlib.util.module_from_spec(spec); spec.loader.exec_module(probe)
text = (Path(args.artifact) / 'seed/app.stderr.txt').read_text()
for provider in ['claude', 'codex']:
    sessions = probe.verify_provider_gui(text, provider)
    # A startup fixture becoming live must neither count as provider proof nor make
    # genuine provider evidence ambiguous.
    startup = 'PROVIDER_APPLIED provider=' + provider + ' event=stop session=native-case replay=false state=idle\n'
    assert probe.verify_provider_gui(text + startup, provider) == sessions
    mutations = {
        'synthetic_identity': text.replace(next(iter(sessions)), 'native-case'),
        'missing_stop': re.sub(r'^PROVIDER_APPLIED provider=' + provider + r' event=stop .*\n', '', text, flags=re.M),
        'replay_only': text.replace('replay=false', 'replay=true'),
        'missing_product_badge': re.sub(r'^PROVIDER_BADGE provider=' + provider + r' .*\n', '', text, flags=re.M),
        'foreign_capture': re.sub(r'PROVIDER_CAPTURE session=\S+', 'PROVIDER_CAPTURE session=foreign', text),
        'no_shell_capture': text.replace('shell_calls=1', 'shell_calls=0'),
    }
    for name, mutated in mutations.items():
        try: probe.verify_provider_gui(mutated, provider)
        except RuntimeError: print(provider + ': rejected ' + name)
        else: raise AssertionError(provider + ': accepted ' + name)
