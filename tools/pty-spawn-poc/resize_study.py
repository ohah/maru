#!/usr/bin/env python3
"""Choose resize/write order on owned actor copies; never patch installed shells.

This is a causal diagnostic on instrumented copies. It does not identify a writer
retroactively in an old uninstrumented incident, or fix the product backend.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import struct
import subprocess
import termios
from live import Session

SCENARIOS = ('stale', 'after', 'drop-stale')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def text_digest(path, architecture):
    # Hash bytes exposed by otool's data-section dump; do not inspect assembly
    # or read third-party implementation source. Signing may change __LINKEDIT.
    output = subprocess.check_output(['/usr/bin/otool', '-arch', architecture,
                                      '-s', '__TEXT', '__text', str(path)], text=True)
    lines = [line.split(None, 1)[1] for line in output.splitlines()
             if re.match(r'^[0-9a-fA-F]{16}\s', line)]
    if not lines:
        raise AssertionError('missing executable text section')
    return hashlib.sha256(bytes.fromhex(''.join(lines).replace(' ', '').replace('\t', ''))).hexdigest()


def verify(data):
    """Require writer identity, successful native observations and syscall order."""
    require(type(data) is dict and type(data.get('schema')) is int and data.get('schema') == 1, 'invalid capture schema')
    require(type(data['metadata']['controller_pid']) is int and data['metadata']['controller_pid'] > 0, 'invalid controller identity')
    require(data['observer_check']['baseline_exit'] == 0 and data['observer_check']['instrumented_exit'] == 0, 'observer probe failed')
    require(data['observer_check']['baseline'] == data['observer_check']['instrumented'], 'observer changed return values or errno')
    require(data['mode'] in ('fork', 'spawn-helper'), 'unknown backend')
    require(data['complete'] is True, 'capture is incomplete')
    require(set(data['actors']) == {'bash', 'stty'}, 'actor identities do not match')
    for actor in data['actors'].values():
        require(re.fullmatch('[0-9a-f]{64}', actor['original_text_sha256']), 'actor text digest changed')
        require(actor['original_text_sha256'] == actor['copy_text_sha256'], 'actor text digest changed')
    cases = data['cases']
    require(len(cases) == 3 and {case['scenario'] for case in cases} == set(SCENARIOS), 'missing or duplicate schedule')
    for case in cases:
        name = case['scenario']
        require(type(case['root_pid']) is int and case['root_pid'] > 0, 'invalid actor identity')
        require(type(case['gate_pid']) is int and case['gate_pid'] == case['root_pid'], 'gate belongs to another actor')
        require(case['post_command_prompt_seen'] is False, 'gate did not precede the next prompt')
        require(case['gate_timeout'] is False, 'gate timed out')
        require(type(case['driver_exit']) is int and case['driver_exit'] == 0 and case['reaped'] is True, 'child exit or reap failed')
        require(case['cleanup_error'] is None, 'cleanup failed')
        before, requested = case['before'], case['requested']
        for size in (before, requested, case['proposal'], case['final']):
            require(type(size) is list and len(size) == 4, 'invalid native size shape')
            require(all(type(n) is int and 0 <= n <= 65535 for n in size), 'invalid native size value')
        require(case['proposal'] == before and requested != before, 'proposal is not the old native size')
        records = case['records']
        require(type(records) is list and all(type(record) is dict for record in records), 'invalid trace records')
        writes = [(i, record) for i, record in enumerate(records) if record.get('gated') == 1]
        require(len(writes) == 1, 'missing or duplicate gated write')
        index, write = writes[0]
        require(type(write['gated']) is int and type(write['pid']) is int and write['pid'] == case['root_pid'] and type(write['rc']) is int and write['rc'] == 0, 'invalid actor identity')
        require(write['size'] == before, 'actor did not write the cached size')
        require(write['op'] == ('skip' if name == 'drop-stale' else 'set'), 'wrong counterfactual operation')
        parents = [(i, record) for i, record in enumerate(records) if record.get('op') == 'parent-set']
        require(len(parents) == 1, 'missing or duplicate parent write')
        parent_index, parent = parents[0]
        require(parent['size'] == requested and type(parent['rc']) is int and parent['rc'] == 0, 'parent resize failed')
        require(type(parent['pid']) is int and parent['pid'] == data['metadata']['controller_pid'] and parent['pid'] != case['root_pid'], 'invalid actor identity')
        require((parent_index > index) if name == 'after' else (parent_index < index), 'wrong syscall order')
        require(case['final'] == (before if name == 'stale' else requested), 'unexpected final native size')
    return True


def study(out, mode):
    base = Path(__file__).resolve().parent
    leaves = ('probe.c', 'live.py', 'resize_trace.c', 'resize_trace_check.c', 'resize_study.py')
    snapshots = {leaf: digest(base / leaf) for leaf in leaves}
    for leaf in leaves:
        shutil.copyfile(base / leaf, out / leaf)
    subprocess.run(['cc', '-arch', 'arm64', '-arch', 'arm64e', '-dynamiclib',
                    '-Wall', '-Wextra', '-Werror', str(base / 'resize_trace.c'),
                    '-o', str(out / 'trace.dylib')], check=True, capture_output=True)
    subprocess.run(['cc', '-O0', '-Wall', '-Wextra', '-Werror', str(base / 'probe.c'),
                    '-o', str(out / 'probe')], check=True, capture_output=True)
    check_dir = out / 'observer-check'
    check_dir.mkdir()
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', str(base / 'resize_trace_check.c'),
                    '-o', str(check_dir / 'bash')], check=True, capture_output=True)
    check_env = {'PATH': '/usr/bin:/bin', 'MARU_POC_GATE': str(check_dir),
                 'MARU_POC_TRACE': str(check_dir / 'trace.jsonl')}
    baseline = subprocess.run([str(check_dir / 'bash')], env=check_env, check=True,
                              capture_output=True, text=True)
    check_env['DYLD_INSERT_LIBRARIES'] = str(out / 'trace.dylib')
    instrumented = subprocess.run([str(check_dir / 'bash')], env=check_env, check=True,
                                  capture_output=True, text=True)
    observer_check = {'baseline': baseline.stdout, 'instrumented': instrumented.stdout,
                      'baseline_exit': baseline.returncode, 'instrumented_exit': instrumented.returncode}
    (out / 'observer-check.json').write_text(json.dumps(observer_check, indent=2) + '\n')
    require(baseline.stdout == instrumented.stdout, 'observer changed native return values or errno')
    actors = out / 'actors'
    actors.mkdir()
    identities = {}
    for name in ('bash', 'stty'):
        original, target = Path('/bin') / name, actors / name
        architectures = subprocess.check_output(['/usr/bin/lipo', '-archs', str(original)], text=True).split()
        architecture = 'arm64e' if 'arm64e' in architectures else 'arm64'
        require(architecture in architectures, 'no supported native actor architecture')
        original_sha = digest(original)
        # copy2 attempts protected system file flags; copy bytes instead.
        shutil.copyfile(original, target)
        os.chmod(target, 0o700)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(target)],
                       check=True, capture_output=True)
        identities[name] = {'original_sha256': original_sha, 'copy_sha256': digest(target),
                            'architecture': architecture,
                            'original_text_sha256': text_digest(original, architecture),
                            'copy_text_sha256': text_digest(target, architecture)}
        require(digest(original) == original_sha, 'installed actor changed')
    data = {'schema': 1, 'complete': False, 'observer_check': observer_check, 'mode': mode, 'actors': identities, 'cases': [], 'metadata': {
        'platform': platform.platform(), 'controller_pid': os.getpid(), 'git_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
        'sources': snapshots,
        'compiler': subprocess.check_output(['cc', '--version'], text=True),
        'sdk': subprocess.check_output(['xcrun', '--show-sdk-version'], text=True).strip()}}
    (out / 'actor-identities.json').write_text(json.dumps(identities, indent=2) + '\n')
    for name in SCENARIOS:
        gate = out / name
        gate.mkdir()
        extra = {'PATH': str(actors) + ':/usr/bin:/bin', 'DYLD_INSERT_LIBRARIES': str(out / 'trace.dylib'),
                 'MARU_POC_TRACE': str(gate / 'trace.jsonl'), 'MARU_POC_GATE': str(gate)}
        if name == 'drop-stale':
            extra['MARU_POC_DROP_STALE'] = '1'
        session = Session(out / 'probe', mode, gate, str(actors / 'bash'), extra_env=extra)
        case = {'scenario': name, 'requested': [41, 103, 0, 0]}
        def size():
            return list(struct.unpack('HHHH', fcntl.ioctl(session.master, termios.TIOCGWINSZ, b'\0' * 8)))
        def parent_resize():
            session.resize(103, 41)
            actual = size()
            require(actual == case['requested'], 'invalid causal observation')
            record = {'op': 'parent-set', 'pid': os.getpid(), 'rc': 0, 'size': actual}
            fd = os.open(gate / 'trace.jsonl', os.O_WRONLY | os.O_APPEND)
            try:
                os.write(fd, (json.dumps(record) + '\n').encode())
            finally:
                os.close(fd)
        try:
            require(session.startup_error is None, session.startup_error)
            start = len(session.data)
            session.send((': > ' + shlex.quote(str(gate / 'arm')) + "; printf '\\n__ARMED__\\n'\n").encode())
            command_done = session.expect(rb'[\r\n]__ARMED__\r?\n', start)
            session.wait(lambda: (gate / 'ready').exists(), 'interposed actor SET ready', timeout=2)
            session.pump(.01)
            case['post_command_prompt_seen'] = bool(re.search(rb'(?:^|[\r\n])__POC_PROMPT__', session.data[start + command_done.end():]))
            proposal = list(map(int, (gate / 'ready').read_text().split()))
            require(len(proposal) == 5, 'proposal is not the old native size')
            case.update(root_pid=session.pid, gate_pid=proposal[0], proposal=proposal[1:], before=size())
            if name != 'after':
                parent_resize()
            (gate / 'release').touch()
            session.command(':')
            if name == 'after':
                parent_resize()
                session.command(':')
            case['final'] = size()
        finally:
            (gate / 'release').touch()
            session.close()
            (gate / 'output.pty').write_bytes(session.data)
            (gate / 'control.log').write_bytes(session.control)
            (gate / 'stderr.log').write_bytes(session.proc.stderr.read())
            case.update(driver_exit=session.proc.returncode, reaped=session.finished,
                        cleanup_error=session.cleanup_error, gate_timeout=(gate / 'timeout').exists())
            case['records'] = [json.loads(line) for line in (gate / 'trace.jsonl').read_text().splitlines()]
            data['cases'].append(case)
            (out / 'progress.json').write_text(json.dumps(data, indent=2) + '\n')
    data['complete'] = True
    verify(data)
    for name, identity in identities.items():
        require(digest(Path('/bin') / name) == identity['original_sha256'], 'invalid causal observation')
    require(all(digest(base / leaf) == snapshots[leaf] for leaf in leaves), 'diagnostic source changed')
    (out / 'study.json').write_text(json.dumps(data, indent=2) + '\n')
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--mode', choices=('fork', 'spawn-helper'), default='fork')
    args = parser.parse_args()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        parser.error('this diagnostic is validated only on macOS arm64')
    out = args.output.resolve()
    if ':' in str(out) or any(ord(c) < 32 for c in str(out)):
        parser.error('output path cannot contain DYLD/PATH separators or control characters')
    if out.exists() and any(out.iterdir()):
        parser.error('output must be new or empty; preserve earlier cohorts')
    out.mkdir(parents=True, exist_ok=True)
    study(out, args.mode)
    print('Three causal schedules verified: stale overwrite / parent later / stale write suppressed.')


if __name__ == '__main__':
    main()
