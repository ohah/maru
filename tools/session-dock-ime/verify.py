"""Independent semantic oracle for bounded fixture witnesses, not the driver's verdict alone."""
import hashlib


def text_hash(text):
    return str(int.from_bytes(hashlib.sha256(text.encode()).digest()[:8], 'little'))


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def validate_report(report, mode):
    require(report.get('schema') == 'maru.session-dock-ime.v1' and report.get('mode') == mode, 'schema/mode')
    require(report.get('passed') is True and report.get('failures') == [], 'producer failed')
    states = report.get('observations', [])
    names = [s.get('name') for s in states]
    expected = (['view_switch', 'search_focus', 'marked', 'committed', 'terminal_restored'] if mode == 'callbacks'
                else ['view_switch', 'search_focus'] + ['live_han_' + str(i) for i in range(5)] + ['live_committed', 'live_candidate_selected', 'live_terminal_restored'])
    require(names == expected, 'missing/duplicate/out-of-order observations')
    before, focused = states[:2]
    require(before['search_active'] == 0 and before['dock_focus'] == 0 and before['search_owner'] == 0, 'view switch acquired input')
    require(focused['terminal_bytes'] == before['terminal_bytes'] + 1, 'terminal positive control')
    require(focused['first_responder'] is True and focused['search_active'] == 1 and focused['search_owner'] == 1, 'first responder/search owner')
    require(focused['cards'] == 3, 'fixture card baseline')
    for state in states[1:-1]:
        require(state['first_responder'] is True and state['search_active'] == 1 and
                state['search_owner'] == 1 and state['dock_focus'] == 1, 'search lost input owner')
    for marked in (states[2:3] if mode == 'callbacks' else states[2:7]):
        require(marked['query_bytes'] == 0 and marked['query_hash'] == text_hash(''), 'preedit committed early')
        require(marked['preedit_bytes'] == 3 and marked['preedit_hash'] == text_hash('한'), 'marked syllable')
        require(marked['cards'] == focused['cards'] and marked['terminal_bytes'] == focused['terminal_bytes'], 'preedit filtered or leaked to PTY')
        require(marked['has_marked'] is True, 'AppKit lost marked state')
    committed, restored = (states[-2], states[-1]) if mode == 'callbacks' else (states[-3], states[-1])
    for state in (committed, restored):
        require(state['query_bytes'] == 3 and state['query_hash'] == text_hash('한') and state['preedit_bytes'] == 0, 'query/blur preservation')
        require(state['preedit_hash'] == text_hash('') and state['has_marked'] is False, 'stale marked state')
    require(committed['cards'] == 0 and committed['terminal_bytes'] == focused['terminal_bytes'], 'commit filter or PTY leak')
    require(restored['search_active'] == 0 and restored['dock_focus'] == 0 and restored['search_owner'] == 0, 'search retained after blur')
    require(restored['terminal_bytes'] == focused['terminal_bytes'] + 1, 'terminal input not restored')
    require(restored['cards'] == 0 and restored['first_responder'] is True, 'terminal return/filter state')
    if mode == 'live':
        selected = states[-2]
        require(selected['query_bytes'] == 3 and selected['query_hash'] == text_hash('韓') and
                selected['preedit_bytes'] == 0 and selected['preedit_hash'] == text_hash('') and selected['has_marked'] is False,
                'Hanja selection was not an exact replacement')
        require(selected['cards'] == 0 and selected['terminal_bytes'] == focused['terminal_bytes'], 'candidate selection leaked to PTY')
    geometry = report.get('geometry', [])
    require(len(geometry) >= 2, 'missing caret geometry')
    for rect in geometry:
        require(rect['w'] > 0 and rect['h'] > 0 and rect['field_w'] > 0 and rect['field_h'] > 0, 'empty caret')
        require(rect['x'] >= rect['field_x'] - 1 and rect['y'] >= rect['field_y'] - 1 and
                rect['x'] + rect['w'] <= rect['field_x'] + rect['field_w'] + 1 and
                rect['y'] + rect['h'] <= rect['field_y'] + rect['field_h'] + 1, 'caret outside published field')
    require(geometry[1]['x'] > geometry[0]['x'], 'preedit caret did not advance')
    require(report.get('candidate_count') == (0 if mode == 'callbacks' else 5), 'candidate evidence count')


def validate_candidate_transitions(artifact, report):
    """Search commits are allowed only when bound to the original typed syllable and owner.

    Images/WindowServer authority are checked by Zig and the separate Swift pixel oracle.
    This check independently binds their accepted manifest to the live input report.
    """
    require(set(artifact) == {'schema', 'source_id', 'rows', 'search_transitions'}, 'candidate artifact fields')
    require(artifact['schema'] == 'maru.session-dock-ime-candidate-observation.v1', 'search candidate schema')
    require(artifact['source_id'] == 'com.apple.inputmethod.Korean.2SetKorean', 'candidate source')
    rows, transitions = artifact['rows'], artifact['search_transitions']
    require(len(rows) == len(transitions) == 5, 'five candidate transitions required')
    ids = [r['window_id'] for r in rows]
    require(len(set(ids)) == 5 and all(i > 0 for i in ids), 'candidate window identity replay')
    expected = {'query_bytes': 3, 'query_hash': int(text_hash('한')),
                'preedit_bytes': 0, 'preedit_hash': int(text_hash(''))}
    preview = {'query_bytes': 3, 'query_hash': int(text_hash('한')),
               'preedit_bytes': 3, 'preedit_hash': int(text_hash('韓'))}
    for index, (row, transition) in enumerate(zip(rows, transitions)):
        witness = report['observations'][index + 2]
        states = [transition[k] for k in ('before', 'opened', 'closed')]
        counts = [transition[k + '_counters'] for k in ('before', 'opened', 'closed')]
        before = states[0]
        require(before['owner_generation'] > 0 and before['owner_generation'] == witness['owner_generation'], 'candidate owner/report binding')
        for key in ('query_bytes', 'query_hash', 'preedit_bytes', 'preedit_hash'):
            require(before[key] == int(witness[key]), 'candidate query/report binding')
        require(counts[0]['pty_input_bytes'] == witness['terminal_bytes'] and row['counters'] == counts[0], 'candidate counter/report binding')
        for state in states:
            require(state['owner_generation'] == before['owner_generation'] and
                    state['first_responder'] is True and state['search_owner'] is True, 'candidate lost search owner')
        for interval, (a, b, ca, cb) in enumerate(zip(states, states[1:], counts, counts[1:])):
            require(ca['pty_input_bytes'] == cb['pty_input_bytes'] and
                    ca['base_screen_generation'] == cb['base_screen_generation'], 'candidate changed terminal')
            delta = cb['committed_text_callbacks'] - ca['committed_text_callbacks']
            if interval == 1 and all(a[k] == value for k, value in preview.items()):
                require(delta == 1 and all(b[k] == value for k, value in expected.items()), 'candidate preview did not cancel to original')
            require((delta == 0 and a == b) or
                    (delta == 1 and (all(b[k] == value for k, value in expected.items()) or
                                     (interval == 0 and all(b[k] == value for k, value in preview.items())))), 'candidate commit transition')
