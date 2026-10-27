"""Independent first-save state and disk oracle; candidate OCR is outside this scope."""
import hashlib
import json
from pathlib import Path
import stat
import struct
import unicodedata

BODY = b'first save body\n'
SENTINEL = b'existing destination\n'
CASES = ('hanja', 'korean', 'cancel', 'overwrite', 'reject', 'write-failure')


def h(text):
    return str(int.from_bytes(hashlib.sha256(text.encode()).digest()[:8], 'little'))


def need(value, message):
    if not value:
        raise ValueError(message)


def regular(path):
    info = path.lstat()
    need(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size < 32768, 'unsafe record/file')
    return path.read_bytes()


def capture(root, label, expected_window, expected_owner=None):
    record = json.loads(regular(root / 'captures' / ('native-'+label+'.json')))
    need(type(expected_window) is int and expected_window > 0 and record['window_id'] == expected_window, 'capture window')
    need(type(record['owner_pid']) is int and record['owner_pid'] > 0, 'capture owner')
    if expected_owner is not None:
        need(record['owner_pid'] == expected_owner, 'capture owner changed')
    path = root / 'captures' / ('native-'+label+'.png')
    info = path.lstat()
    need(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size < 16*1024*1024, 'unsafe capture')
    data = path.read_bytes()
    need(len(data) >= 33 and data[:8] == b'\x89PNG\r\n\x1a\n' and data[12:16] == b'IHDR', 'PNG header')
    width, height = struct.unpack('>II', data[16:24])
    need(8 <= min(width, height) and max(width, height) <= 8192, 'PNG bounds')
    need(record['sha256'] == hashlib.sha256(data).hexdigest(), 'capture hash')
    return dict(width=width, height=height, **record)


def validate_diagnostic(report, artifact_root=None):
    need(report['schema'] == 'maru.untitled-first-save-ime.v1' and report['passed'] is True and report['failures'] == [], 'failed GUI')
    scenario = report['scenario']
    need(scenario in CASES and report['mode'] == 'diagnostic', 'scene')
    need(type(report['pid']) is int and report['pid'] > 0, 'process')
    need(report['source_restored'] is True, 'input source not restored')
    rows = report['observations']
    selected = [r for r in rows if r['name'] == 'selected']
    ready = [r for r in rows if r['name'] == 'filename_ready']
    settled = [r for r in rows if r['name'] == 'settled']
    need(len(selected) == len(ready) == len(settled) == 1, 'missing/duplicate stage')
    word = '한' if scenario == 'korean' else '韓'
    name = word
    initial = rows[0]
    surface = initial['surface_id']
    need(type(surface) is int and surface > 0, 'surface')
    for row in rows:
        need(all(type(row[key]) is int for key in ('surface_id','terminal_bytes','untitled','dirty','navigate_pending','open','palette_owner','confirm')), 'state types')
        need(row['surface_id'] == surface and row['first_responder'] is True, 'owner changed')
        need(row['terminal_bytes'] == initial['terminal_bytes'] and row['body_hash'] == h(BODY.decode()), 'body or terminal changed')
        if row['name'] not in ('settled', 'overwrite_prompt'):
            need(row['confirm'] == 0 and row['open'] == 1 and row['palette_owner'] == 1, 'early confirmation or owner loss')
        if row['name'] != 'settled':
            need(row['untitled'] == 1 and row['dirty'] == 1 and row['navigate_pending'] == 0 and row['target_hash'] == h(''), 'early save')
    for row, text in ((selected[0], word), (ready[0], name)):
        need(row['document_hash'] == h(text) and row['document_bytes'] == len(text.encode()) and row['open'] == 1 and row['palette_owner'] == 1 and row['has_marked'] is False, 'filename selection')
    if scenario != 'korean':
        for prefix in ('opened_', 'cancel_'):
            need(any(r['name'].startswith(prefix) for r in rows), 'candidate transition missing')
    if scenario in ('overwrite', 'reject'):
        prompt = [r for r in rows if r['name'] == 'overwrite_prompt']
        need(len(prompt) == 1 and prompt[0]['confirm'] == 1, 'overwrite not confirmed')
    composition = report['composition']
    for syllable in ('ㅎ', '하', '한'):
        need(any(r['name'] == syllable and r['document_hash'] == h(syllable) for r in composition), 'physical composition missing')
    root = Path(artifact_root or report['root'])
    need(not (root/'input-source.json').exists(), 'source restoration record remains')
    captures = {'filename':capture(root,'filename',report['main_window_id'],report['pid'])}
    if scenario != 'korean':
        need(report['candidate_window_id'] != report['main_window_id'], 'candidate/main window confused')
        captures['candidate'] = capture(root,'candidate',report['candidate_window_id'])
    if scenario in ('overwrite','reject'):
        captures['overwrite'] = capture(root,'overwrite',report['main_window_id'],report['pid'])
    model = json.loads(regular(root / 'model.json'))
    saved = scenario in ('hanja', 'korean', 'overwrite')
    need(model['schema'] == 'maru.untitled-first-save-model.v1' and model['pid'] == report['pid'] and model['surface_id'] == surface, 'model identity')
    need(model['body'].encode() == BODY and model['untitled'] is (not saved) and model['dirty'] is (not saved), 'settled document')
    need(type(model['pending']) is int and model['pending'] == 0 and model['history_verified'] is True, 'pending/history')
    need(settled[0]['untitled'] == int(not saved) and settled[0]['dirty'] == int(not saved) and settled[0]['open'] == 0, 'settled UI model')
    project = root / 'project'
    files = list(project.iterdir())
    matching = [p for p in files if unicodedata.normalize('NFC', p.name) == name]
    need(len(files) == (1 if saved or scenario == 'reject' else 0), 'unexpected files')
    if saved:
        path = Path(model['path'])
        original_project = Path(report['root']) / 'project'
        need(path.parent.resolve() == original_project.resolve() and unicodedata.normalize('NFC', path.name) == name, 'adopted path')
        need(len(matching) == 1 and regular(matching[0]) == BODY, 'saved bytes')
    else:
        need(model['path'] is None, 'cancelled/failed path adopted')
        if scenario == 'reject':
            need(len(matching) == 1 and regular(matching[0]) == SENTINEL, 'existing file overwritten')
        if scenario == 'write-failure':
            need(model['notice'] is True, 'failure not reported')
    return {'scenario': scenario, 'passed': True, 'saved': saved, 'raw_names': [p.name for p in files], 'captures':captures}


def validate(*args, **kwargs):
    raise ValueError('This scene does not claim the shared candidate OCR/live protocol')
