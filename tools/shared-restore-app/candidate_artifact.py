"""Validate handoff window evidence independently of the GUI driver's booleans."""
import re


def require(condition, message):
    if not condition:
        raise ValueError(message)


def positive_int(value):
    return type(value) is int and value > 0


def windows(snapshot):
    require(isinstance(snapshot, dict), 'snapshot object')
    inventory = snapshot.get('windows')
    require(isinstance(inventory, list) and len(inventory) <= 256, 'bounded window inventory')
    ids = []
    for window in inventory:
        require(isinstance(window, dict) and positive_int(window.get('id')), 'window id')
        ids.append(window['id'])
    require(len(set(ids)) == len(ids), 'duplicate window id')
    return {w['id']: w for w in inventory}


def validate(artifact, close):
    require(isinstance(artifact, dict) and set(artifact) == {'schema', 'source_id', 'app_pid', 'rows'}, 'artifact fields')
    require(artifact['schema'] == 'maru.editor-ime-candidate-handoff.v1', 'schema')
    require(artifact['source_id'] == 'com.apple.inputmethod.Korean.2SetKorean', 'input source')
    require(positive_int(artifact['app_pid']), 'app pid')
    rows = artifact['rows']
    require(isinstance(rows, list) and len(rows) == 2, 'two candidate handoffs')
    captures = []
    for index, row in enumerate(rows):
        require(isinstance(row, dict), 'row object')
        require(row.get('name') == ('source' if index == 0 else 'peer'), 'handoff order')
        require(row.get('key_code') == (124 if index == 0 else 13 if close else 123), 'handoff key')
        require(positive_int(row.get('source_owner')) and positive_int(row.get('target_owner')) and
                row['source_owner'] != row['target_owner'], 'owner change')
        before, opened, closed = (windows(row.get(k)) for k in ('before', 'opened', 'closed'))
        proof = row.get('app_capture')
        require(isinstance(proof, dict), 'capture proof')
        wid = row.get('window_id')
        require(positive_int(wid) and proof.get('window_id') == wid, 'capture window binding')
        require(set(opened) - set(before) == {wid}, 'exactly one new window')
        owner = opened[wid].get('owner')
        require(isinstance(owner, dict) and owner.get('pid') == artifact['app_pid'] and
                opened[wid].get('layer') == 20 and opened[wid].get('on_screen') is True, 'app-owned candidate window')
        require(wid not in closed and row.get('popup_closed') is True, 'candidate still open')
        name = proof.get('capture_basename')
        require(isinstance(name, str) and re.fullmatch(rf'candidate-{index}-{wid}\.png', name) is not None, 'capture basename')
        require(isinstance(proof.get('sha256'), str) and re.fullmatch(r'[0-9a-f]{64}', proof['sha256']) is not None, 'capture digest')
        require(positive_int(proof.get('width')) and positive_int(proof.get('height')) and
                type(proof.get('hanja_rows')) is int and proof['hanja_rows'] >= 3, 'capture shape')
        captures.append(proof)
    require(rows[0]['source_owner'] == rows[1]['target_owner'] and
            rows[0]['target_owner'] == rows[1]['source_owner'], 'owner round trip')
    return captures
