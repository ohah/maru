"""Sidebar canonical-filter invariants plus the shared raw/window/pixel binding."""
from pathlib import Path
from prepare import load
common = load('settings_shared_window_verifier', Path(__file__).resolve().parents[1] / 'address-ime/verify.py')
anchors = load('sidebar_shared_anchors', Path(__file__).resolve().parents[1] / 'project-search-ime/verify.py')
h = common.h
require = common.require


def semantics(report):
    require(report['schema'] == 'maru.sidebar-search-ime.v1' and report['passed'] and not report['failures'], 'producer')
    require(report['candidate_count'] == 5, 'five windows')
    states = report['observations']
    expected = sum(([f'selected_fixture_{i}', f'han_{i}', f'opened_{i}', f'cancel_{i}'] for i in range(5)), []) + ['selected_fixture_5', 'han_5', 'opened_5', 'selected', 'terminal_restored']
    require([r['name'] for r in states] == expected, 'states')
    require([r['name'] for r in report['composition']] == ['ㅎ', '하', '한'] * 6, 'composition')
    base = states[0]['terminal_bytes']
    surface = states[0]['active_surface']
    for row in states + report['composition']:
        require(row['label_hash'] == h('한韓') and row['tabs_count'] == 2 and row['active_workspace'] == 0 and row['active_surface'] == surface, 'fixture identity')
        expected_mask = {h(''):3,h('ㅎ'):0,h('하'):0,h('한'):1,h('韓'):2}.get(row['query_hash'])
        require(expected_mask is not None and int(row['visible_mask']) == expected_mask and row['filter_count'] == bin(expected_mask).count('1'), 'canonical filter identity')
    owners = set()
    def doc(row, text):
        require(row['document_hash'] == h(text) and row['document_bytes'] == len(text.encode()), 'document')
    def query(row, text):
        require(row['query_hash'] == h(text) and row['query_bytes'] == len(text.encode()), 'canonical query')
    for i in range(6):
        group = states[4*i:4*i+4] if i < 5 else states[20:24]
        owner = int(group[0]['owner_generation'])
        require(1 << 57 < owner < 1 << 58 and owner not in owners, 'activation')
        owners.add(owner)
        doc(group[0], '')
        query(group[0], '')
        phases = report['composition'][3*i:3*i+3]
        baseline = group[0]['committed_callbacks']
        require([r['committed_callbacks'] for r in phases] == ([baseline]*3 if phases[-1]['has_marked'] else [baseline+1,baseline+2,baseline+3]), 'composition callbacks')
        for row, letter in zip(phases, ('ㅎ','하','한')):
            doc(row, letter)
            require(int(row['owner_generation']) == owner and row['first_responder'] and row['terminal_bytes'] == base, 'composition owner')
        for row in group:
            require(int(row['owner_generation']) == owner and row['first_responder'] and row['open'] == row['palette_owner'] == 1, 'owner')
            require(row['terminal_bytes'] == base and row['navigate_pending'] == 0, 'leak or setting action')
        doc(group[1], '한'); query(group[1], '한')
        doc(group[2], '韓'); query(group[2], '한')
        text = '한' if i < 5 else '韓'
        doc(group[3], text); query(group[3], text)
        require(group[2]['filter_count'] == group[1]['filter_count'] and group[1]['filter_count'] > 0, 'preview changed filter')
        if i < 5:
            require(group[3]['filter_count'] == group[1]['filter_count'], 'cancel changed filter')
        require(not group[3]['has_marked'] and group[3]['committed_callbacks'] == group[2]['committed_callbacks']+1, 'cancel or selection')
    require(states[23]['filter_count'] == 1 and int(states[23]['visible_mask']) == 2, 'selected filter')
    end = states[-1]
    query(end, '')
    require(int(end['visible_mask']) == 3 and end['filter_count'] == 2, 'closed filter restored')
    require(end['open'] == end['palette_owner'] == 0 and int(end['owner_generation']) == 0 and end['terminal_bytes'] == base+1 and not end['has_marked'] and end['first_responder'], 'terminal')
    require(len(report['geometry']) == 12, 'geometry')
    for empty, composed in zip(report['geometry'][::2], report['geometry'][1::2]):
        require(composed['x'] > empty['x'], 'caret advance')
        for g in (empty,composed):
            require(g['w'] > 0 and g['h'] > 0 and g['x'] >= g['field_x']-1 and g['x']+g['w'] <= g['field_x']+g['field_w']+1 and g['y'] >= g['field_y']-1 and g['y']+g['h'] <= g['field_y']+g['field_h']+1, 'anchor')
    return states,base


def validate(report, candidate, artifact_root=None):
    states,base = semantics(report)
    if artifact_root is not None:
        anchors.validate_anchors(report, __import__('json').loads((Path(artifact_root)/'window-transcript.json').read_text()))
    return common.validate_window_evidence(report,candidate,states,base,artifact_root,scene='sidebar-search')

def validate_diagnostic(report):
    require(report['mode'] == 'diagnostic' and report['window_inventory_validated'] is False, 'diagnostic separation')
    semantics(report)

validate_anchors = anchors.validate_anchors
