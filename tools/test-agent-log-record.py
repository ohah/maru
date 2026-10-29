#!/usr/bin/env python3
"""Synthetic native hook -> product CLI binary tests; never touches provider config."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import statistics
import subprocess
import tempfile
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument('--cli', required=True)
parser.add_argument('--driver', required=True)
parser.add_argument('--output-dir', required=True)
args = parser.parse_args()
cli, driver = str(Path(args.cli).resolve()), str(Path(args.driver).resolve())
output = Path(args.output_dir).resolve()
output.mkdir(parents=True, exist_ok=True)
root = Path(tempfile.mkdtemp(prefix='maru-log-record-')).resolve()
root.chmod(0o700)
results, guard = [], threading.Lock()
env = dict(HOME=str(root), CFFIXED_USER_HOME=str(root), PATH='/nonexistent', LC_ALL='C')


def save():
    (output / 'results.json').write_text(json.dumps(results, indent=2))


def invoke(argv, data=b'', success=True, extra=None, silent=False):
    start = time.monotonic()
    try:
        p = subprocess.run(argv, input=data, capture_output=True, timeout=5,
                           env=env | (extra or {}))
    except subprocess.TimeoutExpired as error:
        with guard:
            results.append(dict(argv=argv, failure='timeout', stdout=(error.stdout or b'').decode(errors='replace'),
                                stderr=(error.stderr or b'').decode(errors='replace')))
            save()
        raise
    elapsed = time.monotonic() - start
    row = dict(argv=argv, exit=p.returncode, stdout=p.stdout.decode(errors='replace'),
               stderr=p.stderr.decode(errors='replace'), seconds=elapsed)
    with guard:
        results.append(row)
        save()
    assert (p.returncode == 0) == success, row
    if silent:
        assert not p.stdout and not p.stderr, row
    return p, elapsed


def directory(name):
    p = root / name
    p.mkdir(mode=0o700)
    return p


def record(path, data=b'claude\t{"hook_event_name":"Stop"}\n', success=True, extra_args=()):
    p, elapsed = invoke([cli, 'agent-hooks', 'record', '--file=' + str(path), *extra_args], data, success)
    assert not p.stdout
    if not success:
        # Diagnostics must not echo event content or the selected private path.
        assert str(path).encode() not in p.stderr and (not data or data not in p.stderr)
    return elapsed


def payload(path):
    head, body = path.read_bytes().split(b'\n', 1)
    magic, generation = head.split(b'\t')
    assert magic == b'MARU_AGENT_LOG_V2' and len(generation) == 32
    assert all(c in b'0123456789abcdef' for c in generation)
    assert path.stat().st_mode & 0o777 == 0o600
    return generation, body


def hook(d, binary=cli, provider='claude', native=True):
    p, _ = invoke([driver, str(d), 'hook' if native else 'hook-legacy', binary, provider])
    return p.stdout.decode()


try:
    d = directory('normal')
    target = d / 'a.ndjson'
    record(target)
    maximum = d / 'maximum.ndjson'
    prefix, suffix = b'claude\t{"pad":"', b'"}'
    maximum_record = prefix + b'x' * (32768 - len(prefix) - len(suffix)) + suffix + b'\n'
    record(maximum, maximum_record)
    assert payload(maximum)[1] == maximum_record
    record(maximum, maximum_record[:-1] + b'x\n', False)
    assert payload(maximum)[1] == maximum_record
    generation, body = payload(target)
    assert body == b'claude\t{"hook_event_name":"Stop"}\n'
    with ThreadPoolExecutor(max_workers=8) as workers:
        list(workers.map(lambda i: record(target, f'claude\t{{"tag":{i}}}\n'.encode()), range(32)))
    assert payload(target)[0] == generation
    events = payload(target)[1].splitlines()[1:]
    assert {json.loads(x.split(b'\t')[1])['tag'] for x in events} == set(range(32)) and len(events) == 32
    for data in (b'', b'claude\t{}', b'claude\t{}\nclaude\t{}\n', b'bad provider\t{}\n', b'claude\t' + b'x' * 32768 + b'\n'):
        old = target.read_bytes()
        record(target, data, False)
        assert target.read_bytes() == old
    record(target, success=False, extra_args=('--file=' + str(target),))
    for leaf in ('legacy', 'empty', 'partial'):
        path = d / (leaf + '.ndjson')
        initial = {'legacy': b'claude\t{}\n', 'empty': b'', 'partial': b'MARU_AGENT_LOG_V2\t'}[leaf]
        path.write_bytes(initial)
        path.chmod(0o600)
        record(path, success=False)
        assert path.read_bytes() == initial
    unsafe = directory('unsafe')
    unsafe.chmod(0o755)
    record(unsafe / 'a.ndjson', success=False)
    assert not list(unsafe.iterdir())
    unsafe.chmod(0o700)
    alias = root / 'alias'
    alias.symlink_to(d, target_is_directory=True)
    record(alias / 'a.ndjson', success=False)
    nested = d / 'child'
    nested.mkdir(mode=0o700)
    record(alias / 'child' / 'a.ndjson', success=False)
    if os.geteuid() == 0:
        foreign = directory('foreign')
        os.chown(foreign, 12345, 12345)
        try:
            record(foreign / 'a.ndjson', success=False)
            assert not list(foreign.iterdir())
        finally:
            os.chown(foreign, 0, 0)
    link = d / 'linked.ndjson'
    link.symlink_to(target)
    before = target.read_bytes()
    record(link, success=False)
    assert target.read_bytes() == before
    os.link(target, d / 'hard.ndjson')
    record(d / 'hard.ndjson', success=False)
    (d / 'hard.ndjson').unlink()
    fifo = d / 'fifo.ndjson'
    os.mkfifo(fifo, 0o600)
    record(fifo, success=False)
    fifo.unlink()
    parent_fifo = d / 'parent-fifo'
    os.mkfifo(parent_fifo, 0o600)
    record(parent_fifo / 'a.ndjson', success=False)
    parent_fifo.unlink()
    # The exact generated native command uses no PATH lookup and emits no provider output.
    calls = []
    for provider in ('claude', 'codex'):
        hd = directory(provider)
        command = hook(hd, provider=provider)
        _, elapsed = invoke(['/bin/sh', '-e', '-c', command], b'{"hook_event_name":"Stop"}\nignored\n',
                            extra={'LC_MARU_PANE': 'a'}, silent=True)
        calls.append(elapsed)
        event = payload(hd / 'a.ndjson')[1].split(b'\t', 1)
        assert event[0] == provider.encode()
        metadata = json.loads(event[1])
        assert metadata['hook_event_name'] == 'Stop'
        if provider == 'codex':
            assert isinstance(metadata['maru_hook_ppid'], int)
        # Missing writer, invalid pane, denied directory and sidecar failure all preserve sh -e exit 0.
        invoke(['/bin/sh', '-e', '-c', hook(hd, str(root / 'missing'))], b'{}\n', extra={'LC_MARU_PANE': 'a'}, silent=True)
        invoke(['/bin/sh', '-e', '-c', command], b'{}\n', extra={'MARU_HOOK_INSTANCE': '../bad', 'MARU_HOOK_PANE': '1'}, silent=True)
        hd.chmod(0o755)
        invoke(['/bin/sh', '-e', '-c', command], b'{}\n', extra={'LC_MARU_PANE': 'a'}, silent=True)
        hd.chmod(0o700)
        (hd / 'a_t1.tmux').mkdir()
        invoke(['/bin/sh', '-e', '-c', command], b'{}\n', extra={'LC_MARU_PANE': 'a', 'TMUX_PANE': '%1', 'TMUX': '/synthetic'}, silent=True)
    local = directory('local')
    (local / 'inst').mkdir(mode=0o700)
    invoke(['/bin/sh', '-e', '-c', hook(local)], b'{"hook_event_name":"Stop"}\n',
           extra={'MARU_HOOK_INSTANCE': 'inst', 'MARU_HOOK_PANE': '1', 'LC_MARU_PANE': 'remote', 'TMUX_PANE': '%2'}, silent=True)
    assert payload(local / 'inst' / '1.ndjson')[1] == b'claude\t{"hook_event_name":"Stop"}\n'
    assert not (local / 'remote_t2.ndjson').exists()
    for fault in ('log', 'sidecar'):
        legacy_failure = directory('legacy-failure-' + fault)
        if fault == 'log':
            (legacy_failure / 'a.ndjson').mkdir()
            extra = {'LC_MARU_PANE': 'a'}
        else:
            (legacy_failure / 'a_t1.tmux').mkdir()
            extra = {'LC_MARU_PANE': 'a', 'TMUX_PANE': '%1', 'TMUX': '/synthetic'}
        invoke(['/bin/sh', '-e', '-c', hook(legacy_failure, native=False)], b'{}\n', extra=extra, silent=True)
    quoted_directory = directory("cache's $(false)")
    invoke(['/bin/sh', '-e', '-c', hook(quoted_directory)], b'{}\n', extra={'LC_MARU_PANE': 'a'}, silent=True)
    assert payload(quoted_directory / 'a.ndjson')[1] == b'claude\t{}\n'
    quoted = root / "maru's $(false)"
    quoted.symlink_to(cli)
    invoke(['/bin/sh', '-e', '-c', hook(local, str(quoted))], b'{}\n',
           extra={'MARU_HOOK_INSTANCE': 'inst', 'MARU_HOOK_PANE': '2'}, silent=True)
    assert payload(local / 'inst' / '2.ndjson')[1] == b'claude\t{}\n'
    # Fold oversized JSON through the shared original hook logic, never hand-roll a new projection.
    huge = json.dumps(dict(hook_event_name='Stop', session_id='synthetic', prose='x' * 40000)).encode() + b'\n'
    invoke(['/bin/sh', '-e', '-c', hook(local)], huge,
           extra={'MARU_HOOK_INSTANCE': 'inst', 'MARU_HOOK_PANE': '3'}, silent=True)
    projected = payload(local / 'inst' / '3.ndjson')[1]
    assert len(projected) <= 32769 and json.loads(projected.split(b'\t')[1])['session_id'] == 'synthetic'
    holder_dir = directory('holder')
    holder = subprocess.Popen([driver, str(holder_dir), 'hold'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    try:
        with selectors.DefaultSelector() as wait:
            wait.register(holder.stdout, selectors.EVENT_READ)
            assert wait.select(3), 'holder did not acquire lock'
        assert holder.stdout.readline() == b'ready\n'
        waited = record(holder_dir / 'a.ndjson', success=False)
        assert 1.4 <= waited < 3
        invoke(['/bin/sh', '-e', '-c', hook(holder_dir)], b'{}\n', extra={'LC_MARU_PANE': 'a'}, silent=True)
        assert not (holder_dir / 'a.ndjson').exists()
    finally:
        holder.kill()
        holder.communicate(timeout=3)
        results.append(dict(fixture_terminated=True))
        save()
    record(holder_dir / 'a.ndjson')
    # A copied legacy command may finish after the new writer starts.
    roots = [directory(name) for name in ('local-v1', 'remote-v1', 'local-v2', 'remote-v2')]
    for selected in (roots[0], roots[2]):
        (selected / 'inst').mkdir(mode=0o700)
    transition, _ = invoke([driver, str(root), 'hook-transition', cli, 'claude', *map(str, roots)])
    transition = transition.stdout.decode()
    local_identity = {'MARU_HOOK_INSTANCE': 'inst', 'MARU_HOOK_PANE': '9'}
    def run_transition(extra, data=b'{}\n', command=transition):
        return invoke(['/bin/sh', '-e', '-c', command], data, extra=extra, silent=True)
    run_transition(local_identity)
    legacy_target, native_target = roots[0] / 'inst/9.ndjson', roots[2] / 'inst/9.ndjson'
    assert legacy_target.read_bytes() == b'claude\t{}\n' and not native_target.exists()
    run_transition(local_identity | {'MARU_AGENT_LOG_FORMAT': '2', 'LC_MARU_LOG_FORMAT': 'invalid'})
    native_before = native_target.read_bytes()
    assert payload(native_target)[1] == b'claude\t{}\n'
    copied_old = hook(roots[0], native=False)
    run_transition(local_identity | {'MARU_AGENT_LOG_FORMAT': '2'}, command=copied_old)
    assert native_target.read_bytes() == native_before
    assert legacy_target.read_bytes() == b'claude\t{}\n' * 2
    for invalid in ('', '02', '3', ' 2', '2\n'):
        run_transition(local_identity | {'MARU_AGENT_LOG_FORMAT': invalid}, b'x' * 262144)
        assert native_target.read_bytes() == native_before
        assert legacy_target.read_bytes() == b'claude\t{}\n' * 2
    run_transition({'LC_MARU_PANE': 'remote', 'LC_MARU_LOG_FORMAT': '2', 'MARU_AGENT_LOG_FORMAT': 'invalid'})
    assert payload(roots[3] / 'remote.ndjson')[1] == b'claude\t{}\n'
    run_transition({'LC_MARU_PANE': 'remote', 'LC_MARU_LOG_FORMAT': '1'})
    assert (roots[1] / 'remote.ndjson').read_bytes() == b'claude\t{}\n'
    run_transition({'LC_MARU_PANE': 'remote', 'LC_MARU_LOG_FORMAT': '2', 'TMUX_PANE': '%17', 'TMUX': '/tmp/server,1,0'})
    assert payload(roots[3] / 'remote_t17.ndjson')[1] == b'claude\t{}\n'
    assert (roots[3] / 'remote_t17.tmux').exists()
    remote_before = (roots[3] / 'remote_t17.ndjson').read_bytes()
    sidecar_before = (roots[3] / 'remote_t17.tmux').read_bytes()
    run_transition({'LC_MARU_PANE': 'remote', 'LC_MARU_LOG_FORMAT': '', 'TMUX_PANE': '%17', 'TMUX': '/tmp/other,2,0'}, b'x' * 262144)
    assert (roots[3] / 'remote_t17.ndjson').read_bytes() == remote_before
    assert (roots[3] / 'remote_t17.tmux').read_bytes() == sidecar_before
    run_transition(local_identity | {'MARU_HOOK_INSTANCE': '../bad', 'LC_MARU_PANE': 'remote', 'LC_MARU_LOG_FORMAT': '2'})
    assert payload(roots[3] / 'remote.ndjson')[1] == b'claude\t{}\n'
    missing, _ = invoke([driver, str(root), 'hook-transition', str(root / 'missing'), 'claude', *map(str, roots)])
    run_transition(local_identity | {'MARU_AGENT_LOG_FORMAT': '2'}, command=missing.stdout.decode())
    assert native_target.read_bytes() == native_before
    assert legacy_target.read_bytes() == b'claude\t{}\n' * 2
    invoke([driver, str(root), 'hook-transition', cli, 'claude', str(roots[0]), str(roots[1]), str(roots[0]), str(roots[3])], success=False)
    with ThreadPoolExecutor(max_workers=4) as workers:
        list(workers.map(lambda index: run_transition(local_identity | {'MARU_AGENT_LOG_FORMAT': '2'}, command=copied_old if index % 2 else transition), range(8)))
    assert payload(native_target)[1] == b'claude\t{}\n' * 5
    assert legacy_target.read_bytes() == b'claude\t{}\n' * 6
    quoted_roots = [directory("quoted ' $() " + str(index)) for index in range(4)]
    (quoted_roots[2] / 'inst').mkdir(mode=0o700)
    quoted, _ = invoke([driver, str(root), 'hook-transition', cli, 'claude', *map(str, quoted_roots)])
    run_transition(local_identity | {'MARU_AGENT_LOG_FORMAT': '2'}, command=quoted.stdout.decode())
    assert payload(quoted_roots[2] / 'inst/9.ndjson')[1] == b'claude\t{}\n'
    # Keep one generated command while an app bundle replaces its sibling CLI.
    bundle = directory('Maru test.app') / 'Contents' / 'MacOS'
    bundle.mkdir(parents=True, mode=0o700)
    pinned_binary = bundle / 'maru'
    shutil.copy2(cli, pinned_binary)
    lifetime, _ = invoke([driver, str(root), 'hook-transition', str(pinned_binary), 'claude', *map(str, roots)])
    pinned_command = lifetime.stdout.decode()
    before = payload(native_target)
    run_transition(local_identity | {'MARU_AGENT_LOG_FORMAT': '2'}, command=pinned_command)
    replacement = bundle / 'maru-next'
    shutil.copy2(cli, replacement)
    os.replace(replacement, pinned_binary)
    run_transition(local_identity | {'MARU_AGENT_LOG_FORMAT': '2'}, command=pinned_command)
    assert payload(native_target) == (before[0], before[1] + b'claude\t{}\n' * 2)
    pinned_binary.unlink()
    missing_before = native_target.read_bytes()
    legacy_before = legacy_target.read_bytes()
    run_transition(local_identity | {'MARU_AGENT_LOG_FORMAT': '2'}, command=pinned_command)
    assert native_target.read_bytes() == missing_before and legacy_target.read_bytes() == legacy_before
    shutil.copy2(cli, pinned_binary)
    moved_bundle = bundle.parent.parent.with_name('Moved Maru.app')
    bundle.parent.parent.rename(moved_bundle)
    run_transition(local_identity | {'MARU_AGENT_LOG_FORMAT': '2'}, command=pinned_command)
    assert native_target.read_bytes() == missing_before and legacy_target.read_bytes() == legacy_before
    moved, _ = invoke([driver, str(root), 'hook-transition', str(moved_bundle / 'Contents/MacOS/maru'), 'claude', *map(str, roots)])
    assert moved.stdout != lifetime.stdout
    run_transition(local_identity | {'MARU_AGENT_LOG_FORMAT': '2'}, command=moved.stdout.decode())
    assert payload(native_target) == (before[0], before[1] + b'claude\t{}\n' * 3)
    # Exercise the actual installed command, not just the unguarded projection fixture.
    installed_home = directory("installed-home")
    installed_local = installed_home / '.cache/maru/agent-turn-events-v2/inst'
    installed_local.mkdir(parents=True, mode=0o700)
    installed_remote = installed_home / '.cache/maru/remote-agent-events-v2'
    installed_remote.mkdir(parents=True, mode=0o700)
    generated, _ = invoke([driver, str(root), 'hook-installed', cli, 'claude', str(installed_home),
                           str(roots[0]), str(roots[1])])
    installed_command = generated.stdout.decode()
    assert ' agent-hooks guard ' in installed_command
    installed_env = {'MARU_HOOK_INSTANCE': 'inst', 'MARU_HOOK_PANE': 'a', 'MARU_AGENT_LOG_FORMAT': '2'}
    invoke(['/bin/sh', '-c', installed_command], b'{"hook_event_name":"UserPromptSubmit"}\n',
           extra=installed_env, silent=True)
    assert payload(installed_local / 'a.ndjson')[1] == b'claude\t{"hook_event_name":"UserPromptSubmit"}\n'
    # The guard must preserve Codex's intentional SessionStart receipt on stdout.
    codex, _ = invoke([driver, str(root), 'hook-installed', cli, 'codex', str(installed_home),
                       str(roots[0]), str(roots[1])])
    start_record = b'{"hook_event_name":"SessionStart","session_id":"11111111-2222-3333-4444-555555555555"}\n'
    codex_start, _ = invoke(['/bin/sh', '-c', codex.stdout.decode()], start_record,
                            extra=installed_env | {'MARU_HOOK_PANE': 'b'})
    assert b'MARU_SESSION_V1:' in codex_start.stdout, codex_start.stdout
    assert payload(installed_local / 'b.ndjson')[1].startswith(b'codex\t')
    for size in (2_000_000, 8_000_000):
        huge = json.dumps(dict(hook_event_name='UserPromptSubmit', prompt='x' * size)).encode() + b'\n'
        _, elapsed = invoke(['/bin/sh', '-c', installed_command], huge, extra=installed_env, silent=True)
        assert elapsed < 2, (size, elapsed)
    # A provider may leave stdin open after the first JSON line. Draining must still be bounded.
    pending = subprocess.Popen(['/bin/sh', '-c', installed_command], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env | installed_env)
    started = time.monotonic()
    try:
        pending.stdin.write(b'{"hook_event_name":"UserPromptSubmit"}\n')
        pending.stdin.flush()
        assert pending.wait(timeout=2) == 0
        assert time.monotonic() - started < 2
        assert not pending.stdout.read() and not pending.stderr.read()
    finally:
        if pending.poll() is None:
            pending.kill()
        pending.communicate()
    # Lock contention must consume the SAME budget as shell parsing.
    holder = subprocess.Popen([driver, str(installed_remote), 'hold'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    try:
        assert holder.stdout.readline() == b'ready\n'
        large = json.dumps(dict(hook_event_name='UserPromptSubmit', prompt='x' * 2_000_000)).encode() + b'\n'
        _, elapsed = invoke(['/bin/sh', '-c', installed_command], large,
                            extra={'LC_MARU_PANE': 'a', 'LC_MARU_LOG_FORMAT': '2'}, silent=True)
        assert elapsed < 2, elapsed
        assert not (installed_remote / 'a.ndjson').exists()
    finally:
        holder.kill()
        holder.communicate(timeout=3)
    # Reap the shell AND its blocked descendants; no background sleeper may survive the guard.
    child_pid_file = root / 'guard-child.pid'
    _, elapsed = invoke([cli, 'agent-hooks', 'guard',
                         f"/bin/sleep 30 & echo $! > '{child_pid_file}'; wait"], silent=True)
    assert elapsed < 2, elapsed
    descendant = int(child_pid_file.read_text())
    state = subprocess.run(['/bin/ps', '-p', str(descendant), '-o', 'stat='], capture_output=True).stdout.strip()
    assert not state or state.startswith(b'Z'), state
    baseline = []
    native_command, legacy_command = hook(local), hook(local, native=False)
    for i in range(8):
        _, elapsed = invoke(['/bin/sh', '-e', '-c', legacy_command], b'{}\n',
                            extra={'MARU_HOOK_INSTANCE': 'inst', 'MARU_HOOK_PANE': '5'}, silent=True)
        baseline.append(elapsed)
        _, elapsed = invoke(['/bin/sh', '-e', '-c', native_command], b'{}\n',
                            extra={'MARU_HOOK_INSTANCE': 'inst', 'MARU_HOOK_PANE': '4'}, silent=True)
        calls.append(elapsed)
    assert (local / 'inst' / '5.ndjson').read_bytes() == b'claude\t{}\n' * 8
    assert max(calls) < 2, calls
    guarded_calls = [row['seconds'] for row in results
                     if any(' agent-hooks guard ' in arg for arg in row.get('argv', []))]
    summary = dict(cases=len(results), native_hook_median_seconds=statistics.median(calls),
                   native_hook_max_seconds=max(calls), legacy_hook_median_seconds=statistics.median(baseline),
                   guarded_hook_max_seconds=max(guarded_calls), overall_hook_budget_ms=1500,
                   uid_rejection_tested=os.geteuid() == 0,
                   unspecified_format_is_legacy=True)
    (output / 'summary.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary))
finally:
    save()
    shutil.rmtree(root)
