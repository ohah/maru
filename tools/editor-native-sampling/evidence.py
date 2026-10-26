"""기존 기준 모집단의 검증을 재사용하고 프로파일 한 실행의 근거를 대조한다."""
import hashlib
import importlib.util
import json
from pathlib import Path, PurePosixPath
import sys

import stacks
import symbols

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / 'tools/editor-native-parse-measure'
saved = sys.path[:]
try:
    sys.path.insert(0, str(NATIVE))
    spec = importlib.util.spec_from_file_location('sampling_baseline_evidence', NATIVE / 'verify.py')
    native = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(native)
finally:
    sys.path[:] = saved
require = stacks.require
load = native.load
XPATH = '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'
TOP = {'profile.trace', 'target.stdout', 'recorder.log', 'export-toc.log',
       'export-profile.log', 'toc.xml', 'time-profile.xml', 'address-symbols.json', 'run.json'}


def sha(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def strict(value, expected, label):
    require(type(value) is int and value == expected, 'Wrong ' + label)


def same_summary(actual, expected):
    # Python의 False == 0·0.0 == 0이 JSON 계수 타입을 대신하지 못하게 한다. 키 순서는 의미가 없다.
    canonical = lambda value: json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(',', ':'))
    return canonical(actual) == canonical(expected)


def inventory(root, exclude=()):
    result = {}
    for path in root.rglob('*'):
        require(not path.is_symlink(), 'Evidence symlinks are not supported')
        if path.is_file() and str(path.relative_to(root)) not in exclude:
            result[str(path.relative_to(root))] = sha(path)
    return result


def files(root, expected, exclude=()):
    require(isinstance(expected, dict) and expected, 'Missing file hashes')
    for name, value in expected.items():
        path = PurePosixPath(name)
        require(isinstance(name, str) and not path.is_absolute() and '..' not in path.parts
                and str(path) == name, 'Invalid evidence file path')
        native.digest(root / name, value)
    require(inventory(root, exclude) == expected, 'Missing or extra evidence files')


def baseline(root, head):
    return native.checked_dataset(root, 'baseline', head, native.git_sources(head))


def environment(base, filename, workload):
    return dict(MARU_EW2_FILE=str(base / 'fixtures' / filename),
                MARU_EW2_WORKLOAD=workload, MARU_EW2_VERIFY_EACH_EDIT='0')


def commands(folder, base, filename, workload):
    record = ['xcrun', 'xctrace', 'record', '--template', 'Time Profiler',
              '--output', str(folder / 'profile.trace'), '--no-prompt']
    for key, value in environment(base, filename, workload).items():
        record.extend(['--env', key + '=' + value])
    record.extend(['--target-stdout', str(folder / 'target.stdout'), '--launch', '--',
                   str(base / 'archived-test'), '--maru-expect-tests=5', '--maru-expect-passed=5'])
    toc = ['xcrun', 'xctrace', 'export', '--input', str(folder / 'profile.trace'),
           '--toc', '--output', str(folder / 'toc.xml')]
    profile = ['xcrun', 'xctrace', 'export', '--input', str(folder / 'profile.trace'),
               '--xpath', XPATH, '--output', str(folder / 'time-profile.xml')]
    return [record, toc, profile]


def read_run(folder, base, rep, filename, workload, binary_sha256, binary_uuid):
    meta = load(folder / 'run.json')
    strict(meta.get('schema'), 1, 'run schema')
    strict(meta.get('repetition'), rep, 'run repetition')
    require(meta.get('fixture') == filename and meta.get('workload') == workload, 'Wrong run identity')
    require(meta.get('cwd') == str(base / 'source-1') and meta.get('commands') == commands(folder, base, filename, workload),
            'Wrong executed command or working directory')
    require(meta.get('binary_sha256') == binary_sha256, 'Wrong run binary')
    require(type(meta.get('exit_codes')) is list and len(meta['exit_codes']) == 3
            and all(type(x) is int and x == 0 for x in meta['exit_codes']), 'Recorder or exporter did not succeed')
    files(folder, meta.get('files_sha256'), ('run.json',))
    resolution = load(folder / 'address-symbols.json')
    calls = resolution.get('commands')
    require(type(calls) is list and bool(calls), 'Missing address resolution commands')
    expected_files = TOP | {f'atos-{i:03d}.{suffix}' for i in range(len(calls)) for suffix in ('stdout', 'stderr')}
    require({x.name for x in folder.iterdir()} == expected_files, 'Missing or extra run artifacts')
    target = stacks.target((folder / 'toc.xml').read_text(), str(base / 'archived-test'),
                           environment(base, filename, workload))
    xml = (folder / 'time-profile.xml').read_text()
    resolved = symbols.checked(folder, xml, base / 'archived-test', symbols.symbol_file(folder.parent, binary_uuid),
                               binary_uuid, resolution)
    result = stacks.profile(xml, target['pid'], str(base / 'archived-test'), binary_uuid, resolved)
    source = (base / 'fixtures' / filename).read_bytes()
    text = (folder / 'target.stdout').read_text()
    parsed = native.contract.provider.validate(text, workload, source, filename, 0, 3, 'revision-snapshots', 2)
    require(len(parsed) == 20 and 'All 5 tests passed.' in text, 'Target test selection or product result differs')
    require(same_summary(meta.get('summary'), result), 'Stored profile summary differs from raw samples')
    return dict(target=target, profile=result, inputs=len(parsed))


def producer_files():
    # 실제 실행 중 읽는 코드만 고정한다. 뒤에 작성할 테스트/적대적 검사기는 생산자가 아니다.
    own = ['tools/editor-native-sampling/' + name for name in ('run.py', 'evidence.py', 'stacks.py', 'symbols.py')]
    dependencies = [str(p.relative_to(ROOT)) for folder in (
        'editor-native-parse-measure', 'editor-provider-measure', 'editor-frame-measure',
        'editor-storage-measure', 'editor-fold-product', 'editor-fold-points')
        for p in (ROOT / 'tools' / folder).rglob('*') if p.is_file() and p.suffix in ('.py', '.inc')]
    return {name: sha(ROOT / name) for name in own + dependencies}


def checked_tools(root, expected):
    required = {'tools/editor-native-sampling/' + name for name in ('run.py', 'evidence.py', 'stacks.py', 'symbols.py')}
    required |= {'tools/editor-native-parse-measure/verify.py', 'tools/editor-native-parse-measure/contract.py',
                 'tools/editor-provider-measure/summarize.py', 'tools/editor-frame-measure/summarize.py',
                 'tools/editor-frame-measure/contract.py', 'tools/editor-storage-measure/summarize.py'}
    require(isinstance(expected, dict) and required <= set(expected), 'Missing captured sampling producer')
    files(root / 'tool-snapshot', expected)
