"""Independent field semantics, search invalidation and shared window/pixel binding."""
import json
import math
from pathlib import Path
from prepare import load
common = load('project_search_shared_windows', Path(__file__).resolve().parents[1] / 'address-ime/verify.py')
h, require = common.h, common.require
CONTENT = '한 한 韓 韓'


def fixture_files(root):
    for name in ('한', '韓'):
        path = Path(root) / 'ime-search-root' / name
        require(not path.is_symlink() and path.is_file() and path.stat().st_size == len(CONTENT.encode()), 'fixture file identity')
        require(path.read_bytes() == CONTENT.encode(), 'fixture document changed')


def semantics(report):
    require(report['schema'] == 'maru.project-search-ime.v1' and report['passed'] and not report['failures'], 'producer')
    index = report['target_field']
    require(type(index) is int and 0 <= index < 4 and report['candidate_count'] == 5, 'scene')
    states = report['observations']
    expected = sum(([f'selected_fixture_{i}', f'han_{i}', f'opened_{i}', f'cancel_{i}'] for i in range(5)), []) + ['selected_fixture_5', 'han_5', 'opened_5', 'selected', 'terminal_restored']
    require([r['name'] for r in states] == expected, 'states')
    require([r['name'] for r in report['composition']] == ['ㅎ', '하', '한'] * 6, 'composition')
    base = states[0]['terminal_bytes']
    def text(row, key, value):
        require(row[key+'_hash'] == h(value) and row[key+'_bytes'] == len(value.encode()), key)
    for row in states + report['composition']:
        require(row['file_hash'] == h(CONTENT*2) and row['file_bytes'] == len((CONTENT*2).encode()), 'file contents')
        require(row['navigate_pending'] == 0, 'replacement started')
        if index != 0:
            text(row, 'query_input', '한')
        if row['open']:
            require(row['field_index'] == index, 'wrong input field')
    owners = set()
    count = 2 if index in (1,2) else 4
    for i in range(6):
        group = states[4*i:4*i+4]
        owner = int(group[0]['owner_generation'])
        require(1 << 58 < owner < 1 << 59 and owner not in owners, 'activation')
        owners.add(owner)
        for row in group + report['composition'][3*i:3*i+3]:
            require(int(row['owner_generation']) == owner and row['first_responder'] and row['open'] == row['palette_owner'] == 1 and row['terminal_bytes'] == base, 'owner or terminal leak')
        text(group[0], 'document', ''); text(group[0], 'query', '')
        for row, letter in zip(report['composition'][3*i:3*i+3], ('ㅎ','하','한')):
            text(row, 'document', letter)
            committed = row['query_hash'] == h(letter) and row['query_bytes'] == len(letter.encode()) and row['preedit_bytes'] == 0
            marked = row['query_hash'] == h('') and row['query_bytes'] == 0 and row['preedit_hash'] == h(letter) and row['preedit_bytes'] == len(letter.encode())
            require(committed or marked, 'composition publication')
        text(group[1], 'document', '한'); text(group[1], 'query', '한')
        require(group[1]['complete'] == 1 and group[1]['filter_count'] == count, 'committed search')
        text(group[2], 'document', '韓'); text(group[2], 'query', ''); text(group[2], 'preedit', '韓')
        require(group[2]['has_marked'] and int(group[2]['result_generation']) > int(group[1]['result_generation']), 'preview invalidation')
        if index == 3:
            require(group[2]['complete'] == 1 and group[2]['filter_count'] == 4 and group[2]['request_active'] == 1, 'replacement researched')
        else:
            require(group[2]['composing'] == 1 and group[2]['filter_count'] == 0 and group[2]['request_active'] == 0, 'preview kept old results')
        word = '한' if i < 5 else '韓'
        text(group[3], 'document', word); text(group[3], 'query', word)
        require(not group[3]['has_marked'] and group[3]['preedit_bytes'] == 0 and group[3]['committed_callbacks'] == group[2]['committed_callbacks']+1, 'cancel or commit')
        if index == 3:
            require(group[3]['complete'] == 1 and group[3]['filter_count'] == 4, 'replacement lost search')
    require(states[23]['complete'] == 1 and states[23]['filter_count'] == count, 'final search')
    route = [] if index == 0 else [(0,3)] if index == 3 else [(0,3),(3,1)] if index == 1 else [(0,3),(3,1),(1,2)]
    require([(r['cycle'], r['from'], r['to']) for r in report['tabs']] == [(i,a,b) for i in range(6) for a,b in route], 'actual Tab route')
    previous = 0
    for row in report['tabs']:
        require(row['ack_id'] > previous and 1 << 58 < int(row['generation']) < 1 << 59, 'Tab acknowledgement')
        previous = row['ack_id']
    end = states[-1]
    require(end['open'] == end['palette_owner'] == 0 and int(end['owner_generation']) == 0 and end['terminal_bytes'] == base+1 and not end['has_marked'] and end['first_responder'], 'terminal return')
    require(len(report['geometry']) == 12, 'geometry')
    advances = report['glyph_advances']
    require(all(isinstance(advances[k], (float,int)) and math.isfinite(advances[k]) and advances[k] > 0 for k in ('한','韓')), 'glyph advances')
    for empty, composed in zip(report['geometry'][::2], report['geometry'][1::2]):
        require(abs(composed['x'] - empty['x'] - advances['한']) <= 0.01, 'caret advance')
        for g in (empty,composed):
            require(g['w'] > 0 and g['h'] > 0 and g['x'] >= g['field_x']-1 and g['x']+g['w'] <= g['field_x']+g['field_w']+1 and g['y'] >= g['field_y']-1 and g['y']+g['h'] <= g['field_y']+g['field_h']+1, 'anchor')
    return states,base


def validate_anchors(report, raw):
    require(len(raw) == 5, 'anchor rows')
    first = None
    for i, row in enumerate(raw):
        b, o, c = (row[k]['anchor_appkit'] for k in ('before','opened','closed'))
        g = report['geometry'][2*i+1]
        require(all(math.isfinite(r[k]) for r in (b,o,c) for k in ('x','y','w','h')), 'finite anchors')
        require(b == c and (first is None or first == b), 'restored anchor')
        first = b
        require(all(abs(b[k]-g[k]) <= 0.01 for k in ('x','y','w','h')), 'raw geometry binding')
        require(all(b[k] == o[k] for k in ('y','w','h')), 'preview geometry')
        require(abs(o['x']-b['x']-(report['glyph_advances']['韓']-report['glyph_advances']['한'])) <= 0.01, 'preview advance')
        require(o['x'] >= g['field_x']-1 and o['x']+o['w'] <= g['field_x']+g['field_w']+1, 'preview bounds')


def validate(report, candidate, artifact_root=None):
    states,base = semantics(report)
    if artifact_root is None:
        roots = []
        for path in Path('/private/tmp').glob('maru-palette-live-*/run'):
            try:
                if json.loads((path/'candidate.json').read_text()) == candidate and json.loads((path/'result.json').read_text()) == report:
                    roots.append(path)
            except (OSError, ValueError):
                pass
        require(len(roots) == 1, 'unique run identity')
        artifact_root = roots[0]
    validate_anchors(report, json.loads((Path(artifact_root)/'window-transcript.json').read_text()))
    fixture_files(artifact_root)
    return common.validate_window_evidence(report,candidate,states,base,artifact_root,scene='project-search')


def validate_diagnostic(report):
    require(report['mode'] == 'diagnostic' and report['window_inventory_validated'] is False, 'diagnostic separation')
    semantics(report)
