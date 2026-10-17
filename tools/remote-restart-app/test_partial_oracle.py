#!/usr/bin/env python3
"""Mutate an actual PartialFrame GUI artifact; synthetic contracts live in test_partial_order.py."""
import argparse
import copy
import json
import re
from pathlib import Path
from partial_order import adoption_order
from run_partial import validate_gui_evidence


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--artifact', required=True)
    root = Path(parser.parse_args().artifact)
    manifest = json.loads((root / 'partial-source.json').read_text())
    order = adoption_order(manifest)
    result = json.loads((root / 'result.json').read_text())
    if (result['validation_scope'] != 'actual_appkit_gui' or result['gui_gate_exit'] != 0 or
            not result['gui_continuity_verified'] or not result['canonical_order_verified'] or
            not result['partial_frame_verified'] or result['error'] is not None or result['adoption_order'] != order):
        raise RuntimeError('requires a completed actual GUI run with canonical order proof')
    identities = result['identities']
    evidence = json.loads((root / 'cr6e-c3c-appkit.json').read_text())
    text = (root / 'gate.log').read_text()
    validate_gui_evidence(evidence, identities, text, order)
    rows = re.findall(r'^PARTIAL_GUI_ROW .+$', text, re.M)
    gone = re.findall(r'^PARTIAL_GUI_GONE .+$', text, re.M)[0]
    job = re.search(r'job=([1-9][0-9]*)', rows[0]).group(1)
    changed_texts = {
        'wrong_close_site': text.replace('site=ended_purge_tracker', 'site=other'),
        'wrong_close_error': text.replace('err=PartialFrame', 'err=Other'),
        'missing_close_diagnosis': re.sub(r'^session host closed client connection:.*$', '', text, flags=re.M),
        'missing_first_row': text.replace(rows[0], 'payload ' + rows[0]),
        'duplicate_row': text + rows[0] + '\n',
        'duplicate_gone': text + gone + '\n',
        'foreign_job': text.replace(rows[0], rows[0].replace('job=' + job, 'job=' + str(int(job) + 1))),
        'foreign_runtime': text.replace('runtime=' + identities['healthy'], 'runtime=' + identities['target']),
        'not_previously_published': re.sub(r'prior=[a-z_]+', 'prior=frozen_unavailable', text),
        'embedded_gone': text.replace(gone, 'payload ' + gone),
    }
    for name, changed in changed_texts.items():
        try: validate_gui_evidence(evidence, identities, changed, order)
        except RuntimeError: print('rejected ' + name)
        else: raise AssertionError('accepted ' + name)
    mutations = {
        'empty_continuity': lambda e: e.update(continuity={}),
        'missing_copy': lambda e: e['continuity'].pop('copy_count'),
        'missing_input': lambda e: e['continuity'].update(input_count=0),
        'missing_resize': lambda e: e['continuity'].update(resize_count=0),
        'resident_leak': lambda e: e['cleanup'].update(resident_leases=1),
        'daemon_not_reaped': lambda e: e['cleanup'].update(daemon_reaped=False),
        'healthy_pid_changed': lambda e: e['identity'].update(child_pid_after=e['identity']['child_pid_before'] + 1),
        'input_after_frame': lambda e: e['input_frame'].update(dispatch_ns=e['input_frame']['submit_ns'] + 1),
        'target_still_live': lambda e: e['sibling'].update(live_after=True),
        'nonvisual_artifact': lambda e: e.update(schema='maru.session-host-partial-nonvisual-diagnostic.v1'),
    }
    for name, mutate in mutations.items():
        changed = copy.deepcopy(evidence)
        mutate(changed)
        try: validate_gui_evidence(changed, identities, text, order)
        except RuntimeError: print('rejected ' + name)
        else: raise AssertionError('accepted ' + name)


if __name__ == '__main__': main()
