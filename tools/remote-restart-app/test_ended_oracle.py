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
result = json.loads((root / 'result.json').read_text())
runtime = result['runtime_id']
app_pid = result['app_pid']
probe.verify_runtime_ended_gui(text, runtime, expected_pid=app_pid)
ended = re.findall(r'^REMOTE_ENDED_JOB host=[0-9a-f]{32} state=candidate_ended$', text, re.M)[0]
mutations = {
    'foreign_runtime': text.replace('runtime=' + runtime, 'runtime=' + 'f' * 32),
    'foreign_host': re.sub(r'(REMOTE_ENDED_TERMINAL host=)[0-9a-f]{32}', r'\g<1>' + 'f' * 32, text),
    'no_ended_confirmation': text.replace('state=candidate_ended', 'state=candidate_staged'),
    'no_terminal': text.replace('REMOTE_ENDED_TERMINAL', 'UNRELATED_TERMINAL'),
    'input_open': text.replace('published_new=0', 'published_new=1'),
    'unexpected_retry': text.replace('retry_reserved=0', 'retry_reserved=1'),
    'not_ended': text.replace('ended=1', 'ended=0'),
    'old_retained': text.replace('state=candidate_ended', 'state=candidate_rejected').replace('frozen=0 ended=1 retry_reserved=0', 'frozen=1 ended=0 retry_reserved=1'),
    'no_initial_gui': text.replace('REMOTE_RESTART_GUI phase=seed visible=true', 'REMOTE_RESTART_GUI phase=seed visible=false'),
    'no_last_window_quit': text.replace('app: last window closed', 'payload app: last window closed'),
    'no_final_checkpoint': text.replace('final-quit finished', 'final-quit failed'),
    'foreign_exit_pid': text.replace('exit pid=' + str(app_pid), 'exit pid=' + str(app_pid + 1)),
    'exit_86': text + '\nfatal integrity: reason=incident_authority\n',
    'unhandled_fault': text + '\nREMOTE_ENDED_FAULT_ERROR result=-1\n',
    'embedded_marker': re.sub(r'^REMOTE_RESTART_GUI phase=seed visible=true ready=1$', 'payload REMOTE_RESTART_GUI phase=seed visible=true ready=1', text, flags=re.M),
    'ended_before_connect': ended + '\n' + text.replace(ended + '\n', ''),
}
for name, mutated in mutations.items():
    try: probe.verify_runtime_ended_gui(mutated, runtime, expected_pid=app_pid)
    except RuntimeError: print('rejected ' + name)
    else: raise AssertionError('accepted ' + name)
