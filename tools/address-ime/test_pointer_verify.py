"""Reject fixture substitutes and wrong selection/focus/relay evidence."""
import copy
import unittest

from test_verify import fixture
from pathlib import Path
import json
import tempfile
import pointer_verify


def pointer_fixture():
    report, candidate, raw = fixture()
    report['workflow'] = 'pointer'
    for before, after in zip(report['geometry'][::2], report['geometry'][1::2]):
        before['x'] = after['x']
    for state in report['observations']:
        state['active_surface'] = 2
    report['observations'][-1]['active_surface'] = 1
    rows = []
    for index in range(6):
        owner = report['observations'][4 * index]['owner_generation']
        clicked = dict(phase='click', round=index, pid=77, owner_generation=owner, caret=18, lo=18, hi=18,
                       open=1, first_responder=True, active_surface=2, terminal_surface=1, terminal_bytes=0, navigate_pending=0,
                       receipt=dict(id=2 * index + 1, passed=True, pid=77, generation='0', kind='pointer', action='click', target='address', events=2))
        selected = copy.deepcopy(clicked)
        selected.update(phase='selection', caret=22, hi=22)
        selected['receipt'].update(id=2 * index + 2, generation=owner)
        if index % 2 == 0:
            selected['receipt'].update(action='drag', events=8)
        else:
            selected['receipt'].update(kind='selection_key', keycode=124, flags=131072, events=2)
        rows.extend([clicked, selected])
    pane = copy.deepcopy(rows[-1])
    pane.update(phase='pane', open=0, owner_generation='0', active_surface=1)
    pane['receipt'].update(id=13, kind='pointer', action='click', target='terminal', events=2)
    rows.append(pane)
    report['pointer_observations'] = rows
    return report, candidate, raw


class PointerVerifierTests(unittest.TestCase):
    def test_normal_pointer_and_shift_control(self):
        r, c, raw = pointer_fixture()
        pointer_verify.pointer_semantics(r)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "window-transcript.json").write_text(json.dumps(raw))
            pointer_verify.validate(r, c, root)

    def test_reject_five_false_evidence_shapes(self):
        for attack in ('fixture', 'selection', 'receipt_replay', 'stale_owner', 'wrong_pane', 'failed_terminal_receipt', 'different_terminal', 'wrong_caret_geometry'):
            report, _, _ = pointer_fixture()
            rows = report['pointer_observations']
            if attack == 'fixture':
                report['workflow'] = 'fixture'
            elif attack == 'selection':
                rows[1]['hi'] = 21
            elif attack == 'receipt_replay':
                rows[1]['receipt']['id'] = rows[0]['receipt']['id']
            elif attack == 'stale_owner':
                rows[1]['owner_generation'] = '0'
            elif attack == 'wrong_pane':
                rows[-1]['active_surface'] = 2
            elif attack == 'failed_terminal_receipt':
                rows[-1]['receipt']['passed'] = False
            elif attack == 'different_terminal':
                rows[-1].update(active_surface=99, terminal_surface=99)
            else:
                report['geometry'][1]['x'] += 8
            with self.subTest(attack=attack), self.assertRaises(ValueError):
                pointer_verify.pointer_semantics(report)


if __name__ == '__main__':
    unittest.main()
