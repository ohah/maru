#!/usr/bin/env python3
"""Mutate a real GUI runtime-ended trace to check the evidence boundary."""
import argparse, importlib.util, json, re
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument('--artifact', required=True)
args = ap.parse_args()
root = Path(args.artifact)
spec = importlib.util.spec_from_file_location('ended_probe', Path(__file__).with_name('run.py'))
probe = importlib.util.module_from_spec(spec); spec.loader.exec_module(probe)
text = (root / 'seed/app.stderr.txt').read_text()
runtime = json.loads((root / 'result.json').read_text())['runtime_id']
probe.verify_runtime_ended_gui(text, runtime)
rejection = re.findall(r'^REMOTE_ENDED_JOB host=[0-9a-f]{32} state=candidate_rejected$', text, re.M)[0]
mutations = {
    'foreign_runtime': text.replace('runtime=' + runtime, 'runtime=' + 'f' * 32),
    'foreign_host': re.sub(r'(reconnect terminal: host=)[0-9a-f]{32}', r'\g<1>' + 'f' * 32, text),
    'no_rejection': text.replace('state=candidate_rejected', 'state=candidate_staged'),
    'no_terminal': text.replace('reconnect terminal:', 'unrelated terminal:'),
    'input_open': text.replace('published_new=0', 'published_new=1'),
    'no_retry': text.replace('retry_reserved=1', 'retry_reserved=0'),
    'no_gui_frame': text.replace('REMOTE_ENDED_GUI visible=true', 'REMOTE_ENDED_GUI visible=false'),
    'exit_86': text + '\nfatal integrity: reason=incident_authority\n',
    'unhandled_fault': text + '\nREMOTE_ENDED_FAULT_ERROR result=-1\n',
    'embedded_marker': re.sub(r'^REMOTE_ENDED_GUI visible=true$', 'payload REMOTE_ENDED_GUI visible=true', text, flags=re.M),
    'rejection_before_connect': rejection + '\n' + text.replace(rejection + '\n', ''),
}
for name, mutated in mutations.items():
    try: probe.verify_runtime_ended_gui(mutated, runtime)
    except RuntimeError: print('rejected ' + name)
    else: raise AssertionError('accepted ' + name)
