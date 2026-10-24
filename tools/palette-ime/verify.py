"""Independent read-only palette oracle; candidate pixels use the existing shared verifier."""
import hashlib
import importlib.util
from pathlib import Path


def require(value, reason):
    if not value:
        raise ValueError(reason)


def text_hash(text):
    return str(int.from_bytes(hashlib.sha256(text.encode()).digest()[:8], 'little'))


def text(state, query, marked):
    require(state['query_bytes'] == len(query.encode()) and state['query_hash'] == text_hash(query), 'canonical query')
    require(state['preedit_bytes'] == len(marked.encode()) and state['preedit_hash'] == text_hash(marked), 'preedit')


def delivery(state, syllable):
    marked = state['query_bytes'] == 0 and state['query_hash'] == text_hash('') and state['preedit_bytes'] == len(syllable.encode()) and state['preedit_hash'] == text_hash(syllable)
    committed = state['query_bytes'] == len(syllable.encode()) and state['query_hash'] == text_hash(syllable) and state['preedit_bytes'] == 0 and state['preedit_hash'] == text_hash('')
    require(marked or committed, 'composition text')
    require(state['has_marked'] is marked, 'composition marked flag')
    return 'marked' if marked else 'committed'


def validate_report(report):
    require(report.get('schema') == 'maru.palette-ime.v1' and report.get('passed') is True and report.get('failures') == [], 'producer')
    require(report.get('candidate_count') == 5, 'five candidates')
    states = report['observations']
    expected = sum(([f'han_{i}', f'cancel_{i}'] for i in range(5)), []) + ['han_5', 'selected', 'terminal_restored']
    require([s['name'] for s in states] == expected, 'ordered observations')
    base_bytes = states[0]['terminal_bytes']
    composition = report['composition']
    require([s['name'] for s in composition] == [f'{letter}_{index}' for index in range(6) for letter in ('ㅎ', '하', '한')], 'composition sequence')
    owners = []
    for index in range(6):
        state = states[index * 2] if index < 5 else states[10]
        mode = delivery(state, '한')
        require(state['open'] == state['palette_owner'] == 1 and state['first_responder'] is True, 'palette owner')
        owner = int(state['owner_generation'])
        require(owner > (1 << 63) and owner not in owners, 'activation identity')
        owners.append(owner)
        phases = composition[index * 3:index * 3 + 3]
        for phase, letter in zip(phases, ('ㅎ', '하', '한')):
            require(delivery(phase, letter) == mode, 'mixed delivery')
            require(phase['owner_generation'] == state['owner_generation'] and phase['first_responder'] is True and phase['open'] == phase['palette_owner'] == 1 and phase['terminal_bytes'] == base_bytes, 'composition owner or terminal')
        counters = [p['committed_callbacks'] for p in phases]
        require(counters == ([counters[0]] * 3 if mode == 'marked' else list(range(counters[0], counters[0] + 3))), 'composition callback budget')
        for key in ('query_bytes', 'query_hash', 'preedit_bytes', 'preedit_hash', 'committed_callbacks', 'has_marked'):
            require(state[key] == phases[-1][key], 'composition report binding')
        if index < 5:
            cancelled = states[index * 2 + 1]
            text(cancelled, '한', '')
            require(cancelled['owner_generation'] == state['owner_generation'] and cancelled['open'] == cancelled['palette_owner'] == 1 and cancelled['has_marked'] is False, 'cancel identity')
    for state in states[:-1]:
        require(state['terminal_bytes'] == base_bytes, 'palette input leaked to terminal')
        require(state['first_responder'] is True and state['open'] == state['palette_owner'] == 1, 'palette lost responder')
    selected, restored = states[-2:]
    text(selected, '韓', '')
    require(selected['open'] == selected['palette_owner'] == 1 and selected['has_marked'] is False, 'selection dispatched command')
    require(selected['owner_generation'] == states[-3]['owner_generation'], 'selection owner')
    text(restored, '한', '')
    require(restored['open'] == restored['palette_owner'] == 0 and restored['has_marked'] is False and restored['first_responder'] is True, 'terminal focus')
    require(restored['terminal_bytes'] == base_bytes + 1, 'terminal positive control')
    geometry = report['geometry']
    require(len(geometry) == 12, 'geometry samples')
    for rect in geometry:
        require(rect['w'] > 0 and rect['h'] > 0 and rect['field_w'] > 0 and rect['field_h'] > 0, 'empty geometry')
        require(rect['x'] >= rect['field_x'] - 1 and rect['y'] >= rect['field_y'] - 1 and
                rect['x'] + rect['w'] <= rect['field_x'] + rect['field_w'] + 1 and
                rect['y'] + rect['h'] <= rect['field_y'] + rect['field_h'] + 1, 'caret outside palette')
    for empty, marked in zip(geometry[::2], geometry[1::2]):
        require(marked['x'] > empty['x'], 'caret did not advance')
    return states, base_bytes


def validate_diagnostic(report):
    require(report.get('mode') == 'diagnostic', 'diagnostic mode')
    validate_report(report)


def validate(report, candidate):
    require(report.get('mode') == 'live', 'live mode required for pixel success')
    states, base_bytes = validate_report(report)
    # Reuse the accepted search carrier and semantic query/counter binding, while
    # separately establishing that the owner and activation were the palette's.
    require(candidate['schema'] == 'maru.session-dock-ime-candidate-observation.v1', 'candidate carrier')
    require(candidate['source_id'] == 'com.apple.inputmethod.Korean.2SetKorean', 'candidate source')
    require(len(candidate['rows']) == len(candidate['search_transitions']) == 5, 'candidate rows')
    ids = [row['window_id'] for row in candidate['rows']]
    require(len(set(ids)) == 5, 'window replay')
    for index, transition in enumerate(candidate['search_transitions']):
        before = transition['before']
        witness = states[2 * index]
        require(before['owner_generation'] == int(witness['owner_generation']), 'candidate owner binding')
        for key in ('query_bytes', 'query_hash', 'preedit_bytes', 'preedit_hash'):
            require(before[key] == int(witness[key]), 'candidate text binding')
        for stage in ('before', 'opened', 'closed'):
            row = transition[stage]
            require(row['owner_generation'] == before['owner_generation'] and row['first_responder'] is True and row['search_owner'] is True, 'candidate lifecycle owner')
        require(transition['before_counters']['pty_input_bytes'] == base_bytes and candidate['rows'][index]['counters'] == transition['before_counters'], 'candidate counter binding')
        require(transition['before_counters']['committed_text_callbacks'] == witness['committed_callbacks'], 'candidate callback binding')
        cancelled = states[index * 2 + 1]
        require(transition['closed_counters']['committed_text_callbacks'] == cancelled['committed_callbacks'], 'cancel callback binding')
        for key in ('query_bytes', 'query_hash', 'preedit_bytes', 'preedit_hash'):
            require(transition['closed'][key] == int(cancelled[key]), 'cancel report binding')
    # The carrier's existing checker owns its Han/韓 transition contract; use it
    # directly instead of growing a second version of that policy here.
    path = Path(__file__).resolve().parents[1] / 'session-dock-ime/verify.py'
    spec = importlib.util.spec_from_file_location('search_candidate_verify', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    witnesses = [dict(states[2 * index], owner_generation=int(states[2 * index]['owner_generation'])) for index in range(5)]
    module.validate_candidate_transitions(candidate, {'observations': [None, None] + witnesses})
