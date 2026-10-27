"""Private Save As fixture contract and independent file/model/UI evidence checks."""
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import stat
import struct
import unicodedata

SOURCE = 'save-as-source.txt'
DEFAULT_NAME = 'save-as-destination.txt'
SENTINEL = b'existing destination\n'


def need(value, message):
    if not value:
        raise ValueError(message)


def canonical(value):
    return unicodedata.normalize('NFC', value)


def valid_name(name):
    need(isinstance(name, str) and 0 < len(name.encode()) <= 128, 'filename length')
    need(name not in ('.', '..') and not any(c in '/\\:' or ord(c) < 32 or ord(c) == 127 for c in name), 'filename component')
    need(canonical(name).casefold() != SOURCE.casefold(), 'source filename collision')
    return name


@dataclass(frozen=True)
class Case:
    name: str = DEFAULT_NAME
    scenario: str = 'save'
    existing: bool = False
    overwrite: str = 'accept'
    input_mode: str = 'ax'
    physical_body: bool = False

    def __post_init__(self):
        valid_name(self.name)
        need(type(self.existing) is bool and type(self.physical_body) is bool, 'case boolean types')
        need(self.scenario in ('save', 'cancel', 'edit-during-write'), 'scenario')
        need(self.overwrite in ('accept', 'cancel'), 'overwrite choice')
        need(self.input_mode in ('ax', 'korean', 'hanja'), 'input mode')
        need(self.existing or self.overwrite == 'accept', 'overwrite without target')
        need(self.scenario != 'edit-during-write' or not self.cancelled, 'writer edit cannot be cancelled')
        if self.input_mode != 'ax':
            need(self.name == ('한' if self.input_mode == 'korean' else '韓') + '.txt', 'physical filename')
            need(self.scenario == 'save' and not self.physical_body, 'overlapping input scenes')

    @property
    def cancelled(self):
        return self.scenario == 'cancel' or (self.existing and self.overwrite == 'cancel')

    @property
    def model_body(self):
        return 'foo한' if self.physical_body else 'foo!?' if self.scenario == 'edit-during-write' else 'foo!'

    @property
    def saved_body(self):
        return 'foo한'.encode() if self.physical_body else b'foo!'


def read_regular(path, limit):
    info = path.lstat()
    need(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size <= limit, 'unsafe evidence file')
    return path.read_bytes()


def png_proof(path):
    data = read_regular(path, 16 * 1024 * 1024)
    need(len(data) >= 33 and data[:8] == b'\x89PNG\r\n\x1a\n' and data[12:16] == b'IHDR', 'PNG header')
    width, height = struct.unpack('>II', data[16:24])
    need(100 < width <= 8192 and 100 < height <= 8192, 'PNG dimensions')
    return dict(sha256=hashlib.sha256(data).hexdigest(), width=width, height=height)


def verify(root, case, pid):
    """Do not infer persistence from Save/Replace clicks; check settled model and disk separately."""
    root = Path(root)
    project = root / 'project'
    artifacts = root / 'artifacts'
    panel = json.loads(read_regular(artifacts / 'save-as-panel-state.json', 32768))
    action = json.loads(read_regular(artifacts / 'save-as-action.json', 32768))
    model = json.loads(read_regular(artifacts / 'save-as-model.json', 32768))
    capture = json.loads(read_regular(artifacts / 'save-as-capture-proof.json', 32768))
    for row in (panel, action, model):
        need(type(row['pid']) is int and row['pid'] == pid and pid > 0, 'process identity')
    need(model['schema'] == 'maru.save-as-model.v1', 'model schema')
    need(type(model['pending']) is int and model['pending'] == 0, 'save still pending')
    need(type(model['surface_id']) is int and model['surface_id'] > 0, 'source surface')
    need(model['history_verified'] is True, 'Undo/Redo not verified')
    need(model['body'] == case.model_body, 'document content')
    need(type(model['dirty']) is bool and model['dirty'] == (case.cancelled or case.scenario == 'edit-during-write'), 'dirty state')
    expected_name = SOURCE if case.cancelled else case.name
    path = Path(model['path'])
    need(path.parent.resolve() == project.resolve() and canonical(path.name) == canonical(expected_name), 'adopted path')
    need(panel['name_before'] == SOURCE and Path(panel['directory']).resolve() == project.resolve(), 'native source directory')
    need(type(panel['window_id']) is int and type(panel['panel_id']) is int and min(panel['window_id'], panel['panel_id']) > 0, 'native window identity')
    need(capture['window_id'] == panel['panel_id'] and type(capture['owner_pid']) is int and capture['owner_pid'] > 0, 'capture window binding')
    need(action['requested_name'] == case.name and canonical(action['name_after']) == canonical(case.name), 'native destination name')
    need(action['name_before'] == SOURCE and action['finished'] is True, 'native action incomplete')
    need(action['main_cancelled'] is case.cancelled, 'native cancellation')
    replacement = case.existing and case.scenario != 'cancel'
    need(action['replace_seen'] is replacement, 'replacement confirmation')
    if replacement:
        need(action['overwrite_choice'] == case.overwrite, 'replacement decision')
    need(action['input_mode'] == case.input_mode, 'input scene')
    if case.input_mode != 'ax':
        word = '한' if case.input_mode == 'korean' else '韓'
        need(canonical(action['typed_hangul']) == '한' and canonical(action['typed_word']) == word, 'physical text evidence')
        need(action['keys'] == ([5, 40, 1, 124] if case.input_mode == 'korean' else [5, 40, 1, 36, 36]), 'physical key sequence')
        need(action['restoration'] == 'restored', 'input source restoration')
    else:
        need(action['keys'] == [] and action['restoration'] == 'not-needed', 'unexpected physical input')
    for name in ('save-as-panel', 'save-as-name'):
        actual = png_proof(artifacts / (name + '.png'))
        need(capture[name] == actual, 'capture digest or size')
    if replacement:
        need(capture['save-as-overwrite'] == png_proof(artifacts / 'save-as-overwrite.png'), 'replacement capture')
    need(read_regular(project / SOURCE, 1024) == b'foo', 'original source changed')
    matches = [p for p in project.iterdir() if canonical(p.name) == canonical(case.name)]
    if case.cancelled and not case.existing:
        need(not matches, 'cancelled destination created')
    else:
        need(len(matches) == 1, 'destination identity')
        wanted = SENTINEL if case.cancelled else case.saved_body
        need(read_regular(matches[0], 1024) == wanted, 'destination bytes')
    return dict(schema='maru.save-as-file-lifecycle.v1', passed=True, requested_name=case.name,
                actual_names=[p.name for p in matches], raw_name_utf8=[p.name.encode().hex() for p in matches],
                cancelled=case.cancelled, replacement=replacement, input_mode=case.input_mode,
                pid=pid, source_preserved=True, pending=0)


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--name', default=DEFAULT_NAME)
    parser.add_argument('--scenario', default='save', choices=('save', 'cancel', 'edit-during-write'))
    parser.add_argument('--existing', action='store_true')
    parser.add_argument('--overwrite', default='accept', choices=('accept', 'cancel'))
    parser.add_argument('--input-mode', default='ax', choices=('ax', 'korean', 'hanja'))
    parser.add_argument('--physical-body', action='store_true')
    args = parser.parse_args()
    case = Case(args.name, args.scenario, args.existing, args.overwrite, args.input_mode, args.physical_body)
    print(json.dumps(verify(args.root, case, args.pid), ensure_ascii=False, indent=2))
