"""보관 trace를 SDK로 다시 내보내 표시 이름과 무관한 표본 사실을 대조한다."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

import stacks

_ROOT = None
_CACHE = {}
XPATH = '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'


def configure(root):
    global _ROOT
    stacks.require(not root.exists(), 'Use a new SDK replay directory')
    _ROOT = root


def digest(value):
    return hashlib.sha256(json.dumps(value, separators=(',', ':'), sort_keys=True).encode()).hexdigest()


def trace_files(root):
    result = {}
    for path in root.rglob('*'):
        stacks.require(not path.is_symlink(), 'Trace replay symlinks are not supported')
        if path.is_file():
            result[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
    stacks.require(bool(result), 'Empty original trace')
    return result


def canonical(text):
    _, table, refs = stacks.exported_table(text)
    rows = []
    for row in table.findall('row'):
        stacks.require(len(row) == 7, 'Wrong SDK replay row')
        thread = refs.get(row[1])
        process = refs.get(row[2])
        pcs = None if row[-1].tag == 'sentinel' else [int(refs.get(frame).get('addr'), 16)
                    for frame in refs.get(row[-1])]
        rows.append([int(refs.get(row[0]).text), int(refs.get(stacks.one(thread, 'tid')).text),
            int(refs.get(stacks.one(process, 'pid')).text), int(refs.get(row[3]).text),
            refs.get(row[4]).text, int(refs.get(row[5]).text), pcs])
    return rows


def image_binding(text, binary):
    root, _, refs = stacks.exported_table(text)
    return sorted({(image.get('path'), image.get('UUID'), image.get('load-addr'))
                   for image in (refs.get(node) for node in root.iter('binary'))
                   if image.get('path') == binary or image.get('name') == 'archived-test'})


def check(folder, toc, profile, binary, expected_env, expected_trace):
    global _ROOT
    actual = trace_files(folder / 'profile.trace')
    stacks.require(actual == expected_trace, 'Original trace files differ before SDK replay')
    key = digest(actual)
    if key not in _CACHE:
        if _ROOT is None:
            _ROOT = Path(tempfile.mkdtemp(prefix='maru-native-sampling-replay-'))
        destination = _ROOT / key
        destination.mkdir(parents=True)
        commands = [
            ['xcrun', 'xctrace', 'export', '--input', str(folder / 'profile.trace'), '--toc', '--output', str(destination / 'toc.xml')],
            ['xcrun', 'xctrace', 'export', '--input', str(folder / 'profile.trace'), '--xpath', XPATH, '--output', str(destination / 'time-profile.xml')],
        ]
        for index, command in enumerate(commands):
            with (destination / f'export-{index}.log').open('xb') as stream:
                result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT)
            stacks.require(result.returncode == 0, 'Trace SDK replay failed; artifacts: ' + str(destination))
        stacks.require(trace_files(folder / 'profile.trace') == actual, 'SDK export changed original trace')
        decoded = (destination / 'time-profile.xml').read_text()
        _CACHE[key] = dict(toc=(destination / 'toc.xml').read_text(), rows=canonical(decoded),
                           binding=image_binding(decoded, binary), folder=str(destination))
    replayed = _CACHE[key]
    expected = stacks.target(toc, binary, expected_env)
    observed = stacks.target(replayed['toc'], binary, expected_env)
    stacks.require(expected == observed, 'Trace target replay differs')
    rows = canonical(profile)
    stacks.require(rows == replayed['rows'], 'Trace sample replay differs')
    stacks.require(image_binding(profile, binary) == replayed['binding'], 'Trace image replay differs')
    return dict(rows=len(rows), canonical_sha256=digest(rows), replay_folder=replayed['folder'], trace_sha256=key)
