"""Pointer workflow adds actual relay receipts and observed selection/focus to the IME oracle."""
import verify as address


def pointer_semantics(report):
    address.require(report.get('workflow') == 'pointer', 'actual pointer workflow required')
    rows = report['pointer_observations']
    address.require(len(rows) == 13, 'pointer stage count')
    states, base = address.semantics(report, pointer_geometry=True)
    receipts = set()
    for index in range(6):
        clicked, selected = rows[2 * index:2 * index + 2]
        owner = states[4 * index]['owner_generation']
        for row, phase in ((clicked, 'click'), (selected, 'selection')):
            address.require(row['round'] == index and row['phase'] == phase and row['owner_generation'] == owner, 'pointer owner or phase')
            address.require(row['open'] == 1 and row['first_responder'] and row['navigate_pending'] == 0 and row['terminal_bytes'] == base, 'pointer input isolation')
            receipt = row['receipt']
            address.require(receipt['passed'] is True and receipt['pid'] == row['pid'] and receipt['id'] not in receipts, 'relay binding or replay')
            receipts.add(receipt['id'])
        address.require(clicked['caret'] == clicked['lo'] == clicked['hi'] == 18, 'actual click caret')
        address.require(clicked['receipt']['kind'] == 'pointer' and clicked['receipt']['action'] == 'click' and clicked['receipt']['target'] == 'address' and clicked['receipt']['events'] == 2 and clicked['receipt']['generation'] == '0', 'click receipt')
        address.require(selected['caret'] == selected['hi'] == 22 and selected['lo'] == 18, 'whole emoji selection')
        receipt = selected['receipt']
        address.require(receipt['generation'] == owner, 'selection generation')
        if index % 2 == 0:
            address.require(receipt['kind'] == 'pointer' and receipt['action'] == 'drag' and receipt['target'] == 'address' and receipt['events'] == 8, 'drag receipt')
        else:
            address.require(receipt['kind'] == 'selection_key' and receipt['keycode'] == 124 and receipt['flags'] == 131072 and receipt['events'] == 2, 'shift right receipt')
    pane = rows[-1]
    address.require(pane['phase'] == 'pane' and pane['open'] == 0 and pane['owner_generation'] == '0' and pane['first_responder'] and pane['terminal_bytes'] == base and pane['navigate_pending'] == 0 and pane['round'] == 5, 'actual pane focus')
    address.require(pane['active_surface'] == pane['terminal_surface'] and pane['active_surface'] != states[-2]['active_surface'] and pane['terminal_surface'] == rows[0]['terminal_surface'], 'other terminal surface')
    receipt = pane['receipt']
    address.require(receipt['passed'] is True and receipt['kind'] == 'pointer' and receipt['action'] == 'click' and receipt['target'] == 'terminal' and receipt['events'] == 2 and receipt['generation'] == states[-2]['owner_generation'] and receipt['id'] not in receipts and receipt['pid'] == pane['pid'], 'terminal click receipt')


def validate(report, candidate, artifact_root=None):
    pointer_semantics(report)
    address.require(all(row['pid'] == candidate['rows'][0]['owner_pid'] for row in report['pointer_observations']), 'pointer candidate PID binding')
    address.validate(report, candidate, artifact_root, pointer_geometry=True)


def validate_diagnostic(report):
    pointer_semantics(report)
    address.validate_diagnostic(report, pointer_geometry=True)
