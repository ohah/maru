#!/usr/bin/env python3
"""Reject missing or foreign GUI evidence by mutating an actual local provider trace."""
import argparse, importlib.util, re
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument('--artifact', required=True)
ap.add_argument('--provider', action='append', choices=['claude', 'codex'])
args = ap.parse_args()
spec = importlib.util.spec_from_file_location('provider_probe', Path(__file__).with_name('run.py'))
probe = importlib.util.module_from_spec(spec); spec.loader.exec_module(probe)
text = (Path(args.artifact) / 'seed/app.stderr.txt').read_text()
providers = list(dict.fromkeys(args.provider or ['claude', 'codex']))
for provider in providers:
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

restored = (Path(args.artifact) / 'restore/app.stderr.txt').read_text()
probe.verify_provider_restore(text, restored, providers)
for provider in providers:
    sid = next(iter(probe.verify_provider_gui(text, provider)))
    rows = [line for line in restored.splitlines(True)
            if line.startswith('PROVIDER_APPLIED provider=' + provider + ' ') and 'session=' + sid + ' ' in line]
    assert rows
    mutations = {
        'restore_missing_event': restored.replace(rows[0], '', 1),
        'restore_duplicate_event': restored + rows[0],
        'restore_foreign_session': restored.replace(sid, 'foreign'),
        'restore_live_replay': restored.replace(rows[0], rows[0].replace('replay=true', 'replay=false'), 1),
        'restore_changed_state': restored.replace(rows[0], rows[0].replace('state=idle', 'state=running')
                                               if 'state=idle' in rows[0] else rows[0].replace('state=running', 'state=idle'), 1),
    }
    for name, mutated in mutations.items():
        try: probe.verify_provider_restore(text, mutated, providers)
        except RuntimeError: print(provider + ': rejected ' + name)
        else: raise AssertionError(provider + ': accepted ' + name)
