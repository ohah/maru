"""Independent address document/counter binding; shared reducers own window authority."""
import hashlib
import json
from pathlib import Path

def h(s):
    return str(int.from_bytes(hashlib.sha256(s.encode()).digest()[:8], 'little'))

def require(v, m):
    if not v:
        raise ValueError(m)

def semantics(report, *, pointer_geometry=False, scene='address'):
    require(scene in ('address', 'rename'), 'scene')
    rename = scene == 'rename'
    prefix = 'a/' if rename else 'https://a.invalid/'
    require(report['schema'] == f'maru.{scene}-ime.v1' and report['passed'] and (not report['failures']), 'producer')
    require(report['candidate_count'] == 5, 'five windows')
    states = report['observations']
    expected = sum(([f'selected_fixture_{i}', f'han_{i}', f'opened_{i}', f'cancel_{i}'] for i in range(5)), []) + ['selected_fixture_5', 'han_5', 'opened_5', 'selected'] + (['target_committed'] if rename else []) + ['terminal_restored']
    require([s['name'] for s in states] == expected, 'states')
    require([s['name'] for s in report['composition']] == ['ㅎ', '하', '한'] * 6, 'composition')
    base = states[0]['terminal_bytes']
    owners = []

    def doc(s, text):
        require(s['document_hash'] == h(text) and s['document_bytes'] == len(text.encode()), 'document')
    for i in range(6):
        fixture = states[i * 4] if i < 5 else states[20]
        owner = int(fixture['owner_generation'])
        require((1 << (61 if rename else 62)) < owner < (1 << (62 if rename else 63)) and owner not in owners, 'activation')
        owners.append(owner)
        doc(fixture, prefix + ('' if rename else '😀') + '/z')
        phases = report['composition'][3 * i:3 * i + 3]
        marked = phases[-1]['has_marked']
        baseline = fixture['committed_callbacks']
        require([r['committed_callbacks'] for r in phases] == ([baseline] * 3 if marked else [baseline + 1, baseline + 2, baseline + 3]), 'composition callbacks')
        for (phase, letter) in zip(phases, ('ㅎ', '하', '한')):
            if rename:
                require(phase['target_hash'] == h(prefix + '/z'), 'composition changed target')
            doc(phase, prefix + letter + '/z')
            require(int(phase['owner_generation']) == owner and phase['first_responder'] and (phase['terminal_bytes'] == base) and (phase['navigate_pending'] == 0), 'composition binding')
        group = states[i * 4:i * 4 + 4] if i < 5 else states[20:24]
        for row in group:
            if rename:
                require(row['target_hash'] == h(prefix + '/z'), 'target changed before explicit commit')
            require(int(row['owner_generation']) == owner and row['first_responder'] and (row['open'] == row['palette_owner'] == 1), 'owner')
            require(row['terminal_bytes'] == base and row['navigate_pending'] == 0, 'leak or navigation')
        doc(group[1], prefix + '한/z')
        doc(group[2], prefix + '韓/z')
        doc(group[3], prefix + ('한' if i < 5 else '韓') + '/z')
        require(not group[3]['has_marked'], 'cancel or selection marked')
        require(group[3]['committed_callbacks'] == group[2]['committed_callbacks'] + 1, 'cancel or selection callbacks')
    if rename:
        committed = states[-2]
        require(committed['target_hash'] == h(prefix + '韓/z') and committed['open'] == 0 and committed['terminal_bytes'] == base, 'explicit target commit')
    end = states[-1]
    if rename:
        require(end['target_hash'] == h(prefix + '韓/z'), 'target changed after commit')
    require(end['open'] == end['palette_owner'] == 0 and int(end['owner_generation']) == 0 and (end['terminal_bytes'] == base + 1) and (not end['has_marked']) and end['first_responder'], 'terminal')
    require(len(report['geometry']) == 12, 'geometry')
    for g in report['geometry']:
        require(g['w'] > 0 and g['h'] > 0 and (g['x'] >= g['field_x'] - 1) and (g['x'] + g['w'] <= g['field_x'] + g['field_w'] + 1) and (g['y'] >= g['field_y'] - 1) and (g['y'] + g['h'] <= g['field_y'] + g['field_h'] + 1), 'anchor')
    for (empty, composed) in zip(report['geometry'][::2], report['geometry'][1::2]):
        if pointer_geometry:
            require(report.get('workflow') == 'pointer' and abs(composed['x'] - empty['x']) <= 1, 'equal-width selection caret')
        else:
            require(composed['x'] > empty['x'], 'caret advance')
    return (states, base)

def validate(report, candidate, artifact_root=None, *, pointer_geometry=False, scene='address'):
    """Bind semantic witnesses to exactly one private run; image pixels are checked separately."""
    (states, base) = semantics(report, pointer_geometry=pointer_geometry, scene=scene)
    return validate_window_evidence(report, candidate, states, base, artifact_root, scene=scene)

def validate_window_evidence(report, candidate, states, base, artifact_root=None, *, scene='address'):
    require(report['mode'] == 'live' and report['window_inventory_validated'] is True, 'full live window validation')
    require(candidate['schema'] == f'maru.{scene}-ime-candidate.v1' and candidate['source_id'] == 'com.apple.inputmethod.Korean.2SetKorean', 'candidate schema')
    require(len(candidate['rows']) == 5 and len({r['window_id'] for r in candidate['rows']}) == 5, 'replay')
    root = Path(artifact_root) if artifact_root is not None else None
    if root is None:
        candidates = []
        for path in Path('/private/tmp').glob('maru-palette-live-*/run'):
            try:
                if json.loads((path / 'candidate.json').read_text()) == candidate and json.loads((path / 'result.json').read_text()) == report:
                    candidates.append(path)
            except (OSError, ValueError):
                pass
        require(len(candidates) == 1, 'unique private run identity')
        root = candidates[0]
    rows = json.loads((root / 'window-transcript.json').read_text())
    require(len(rows) == 5, 'raw rows')
    for (i, (raw, proof)) in enumerate(zip(rows, candidate['rows'])):
        bound = [states[1 + 4 * i], states[2 + 4 * i], states[3 + 4 * i]]
        owner = int(bound[0]['owner_generation'])
        for (phase, state) in zip(('before', 'opened', 'closed'), bound):
            snap = raw[phase]
            search = snap['search']
            c = snap['counters']
            require(int(search['owner_generation']) == owner and search['first_responder'] and search['search_owner'], 'raw owner')
            for key in ('query_bytes', 'query_hash', 'preedit_bytes', 'preedit_hash'):
                require(int(search[key]) == int(state[key]), 'raw text')
            require(c['pty_input_bytes'] == base and c['committed_text_callbacks'] == state['committed_callbacks'], 'raw counter')
        require(raw['opened']['counters']['committed_text_callbacks'] - raw['before']['counters']['committed_text_callbacks'] in (0, 1), 'opening callback')
        require(raw['closed']['counters']['committed_text_callbacks'] == raw['opened']['counters']['committed_text_callbacks'] + 1, 'cancel callback')
        require(len({raw[p]['counters']['base_screen_generation'] for p in ('before', 'opened', 'closed')}) == 1, 'screen change')
        require(raw['opened']['app_captures'] == [proof['app_capture']], 'pixel binding')
        window_id = proof['window_id']
        require(window_id not in {w['id'] for w in raw['before']['windows']} and window_id not in {w['id'] for w in raw['closed']['windows']}, 'lifecycle')
        fresh = [w for w in raw['opened']['windows'] if w['id'] not in {old['id'] for old in raw['before']['windows']} and w['on_screen']]
        require(len(fresh) == 1 and fresh[0]['id'] == window_id and (fresh[0]['owner']['pid'] == proof['owner_pid']) and (fresh[0]['layer'] == proof['layer'] == 20), 'inventory')
        require(fresh[0]['owner']['bundle_id'] == proof['bundle_id'] == 'dev.maru.apphost' and fresh[0]['owner']['signing_id'] == proof['signing_id'] == 'dev.maru.apphost', 'identity')

def validate_diagnostic(report, *, pointer_geometry=False, scene='address'):
    require(report['mode'] == 'diagnostic' and report['window_inventory_validated'] is False, 'diagnostic separation')
    semantics(report, pointer_geometry=pointer_geometry, scene=scene)
