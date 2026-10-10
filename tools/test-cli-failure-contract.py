#!/usr/bin/env python3
"""Exercise real CLI failure contracts using private HOME/files and a fake endpoint."""
import argparse
import itertools
import json
import os
from pathlib import Path
import selectors
import socket
import shutil
import subprocess
import tempfile
import threading
import time


def verify(cli, root):
    home = root / 'home'
    home.mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith(('MARU_', 'XDG_', 'DYLD_'))}
    env.update(HOME=str(home), CFFIXED_USER_HOME=str(home), XDG_CACHE_HOME=str(root / 'cache'), MARU_PANE_ID='987654321')
    records = []

    def record(args, code, stdout, stderr, failure=None, fixture_terminated=False):
        # TimeoutExpired can expose bytes even with text=True. Keep partial output.
        def text(value):
            return value.decode(errors='replace') if isinstance(value, bytes) else value or ''
        entry = dict(args=args, exit=code, stdout=text(stdout), stderr=text(stderr))
        if failure:
            entry['failure'] = failure
        if fixture_terminated:
            entry['fixture_terminated'] = True
        records.append(entry)
        (root / 'results.json').write_text(json.dumps(records, indent=2) + '\n')

    def run(args, expected):
        try:
            p = subprocess.run([str(cli), *args], cwd=root, env=env, capture_output=True, text=True, timeout=15)
        except subprocess.TimeoutExpired as exc:
            record(args, None, exc.stdout, exc.stderr, 'timeout')
            raise
        except OSError as exc:
            record(args, None, '', str(exc), 'spawn')
            raise
        # Persist before assertions so CI also retains the failing invocation.
        record(args, p.returncode, p.stdout, p.stderr)
        assert p.returncode == expected, records[-1]
        assert 'panic' not in p.stderr and 'stack trace' not in p.stderr, records[-1]
        return p

    link = home / '.local/bin/maru'
    link.parent.mkdir(parents=True)
    link.write_text('KEEP INSTALL\n')
    for args, code in [(['--help'], 0), (['-h'], 0), (['install-cli'], 1), (['--help', 'extra'], 1), (['unknown'], 1)]:
        run(['install-cli', *args], code)
        assert not link.is_symlink() and link.read_text() == 'KEEP INSTALL\n'
    run(['install-cli'], 0)
    assert link.is_symlink() and link.resolve() == cli
    # Invalid requests also preserve an already installed symlink.
    run(['install-cli', 'extra'], 1)
    assert link.is_symlink() and link.resolve() == cli
    source = root / 'in.trace'
    source.write_text('maru.trace.v1\n')
    output = root / 'out.trace'
    output.write_text('KEEP OUTPUT\n')
    for args in [['anonymize', 'in.trace', 'out.trace', 'extra'], ['anonymize', 'missing', 'out.trace', 'extra']]:
        run(['trace', *args], 1)
        assert output.read_text() == 'KEEP OUTPUT\n'
    for args in [['--help'], ['-h'], ['anonymize', '--help'], ['anonymize', '-h']]:
        assert 'usage:' in run(['trace', *args], 0).stdout
    run(['trace', 'anonymize', 'in.trace', 'out.trace'], 0)
    assert output.read_text().startswith('maru.trace.v1')
    assert run(['trace', 'anonymize', 'in.trace'], 0).stdout.startswith('maru.trace.v1')
    help_text = run(['--help'], 0).stdout
    for command in ['incidents', 'control', 'agent-events', 'agent-hooks', 'browser']:
        assert '  ' + command + ' ' in help_text, command
    run(['editor', 'editor'], 1)
    # Provider overrides can escape a private HOME; pin both explicitly before hook calls.
    hooks = root / 'hook-fixture'
    hooks.mkdir()
    env.update(CLAUDE_CONFIG_DIR=str(hooks / 'claude'), CODEX_HOME=str(hooks / 'codex'))
    hook_dir = hooks / 'events' / '--provider=codex'

    def hook_state():
        state = {}
        # Include directory permissions and symlinks, not just config/trust file bytes.
        for base in [home, hooks]:
            for p in [base, *base.rglob('*')]:
                stat = p.lstat()
                payload = os.readlink(p) if p.is_symlink() else p.read_bytes() if p.is_file() else None
                state[str(p)] = (stat.st_mode, payload)
        return state

    def reject_hook_duplicates():
        before = hook_state()
        for action in ['install', 'uninstall']:
            for provider in ['claude', 'codex']:
                options = [f'--provider={provider}', '--scope=remote', f'--dir={hook_dir}']
                extras = ['--provider=claude', '--provider=codex', f'--dir={hook_dir}', f'--dir={hooks / "other"}', '--scope=remote']
                for order in itertools.permutations(options):
                    for extra in extras:
                        p = run(['agent-hooks', action, *order, extra], 2)
                        assert not p.stdout and 'Each option may only be specified once.' in p.stderr
            for first in ['--dir=', '--dir=relative']:
                run(['agent-hooks', action, '--provider=claude', '--scope=remote', first, f'--dir={hook_dir}'], 2)
        assert hook_state() == before, 'rejected hook selectors changed config, trust or log paths'

    # Check both absence and already-installed hooks: uninstall must not remove existing state.
    reject_hook_duplicates()
    (hooks / 'claude').mkdir()
    (hooks / 'codex').mkdir()
    claude_settings = hooks / 'claude/settings.json'
    claude_settings.write_text('{"keep":"sentinel"}\n')
    codex_config = hooks / 'codex/config.toml'
    codex_config.write_text('# keep sentinel\n')
    for provider in ['claude', 'codex']:
        args = ['agent-hooks', 'install', f'--provider={provider}', '--scope=remote', f'--dir={hook_dir}']
        outcome = json.loads(run(args, 0).stdout)
        assert outcome['provider'] == provider and outcome['action'] == 'install' and outcome['changed']
        assert hook_dir.is_dir()
        target = claude_settings if provider == 'claude' else hooks / 'codex/hooks.json'
        assert 'MARU_HOOK_V3' in target.read_text() and str(hook_dir) in target.read_text()
    assert json.loads(claude_settings.read_text())['keep'] == 'sentinel'
    assert '# keep sentinel' in codex_config.read_text()
    assert 'MARU_HOOK_V3' in codex_config.read_text() and 'trusted_hash' in codex_config.read_text()
    reject_hook_duplicates()
    before = hook_state()
    for flag in ['--help', '-h']:
        for action in ['install', 'uninstall']:
            for extra in ['--provider=codex', f'--dir={hooks / "other"}', '--scope=remote']:
                run(['agent-hooks', action, '--provider=claude', '--scope=remote', f'--dir={hook_dir}', extra, flag], 0)
    assert hook_state() == before, 'hook help changed installed provider state'
    for provider in ['claude', 'codex']:
        options = [f'--provider={provider}', '--scope=remote', f'--dir={hook_dir}']
        assert not json.loads(run(['agent-hooks', 'install', *options], 0).stdout)['changed']
        outcome = json.loads(run(['agent-hooks', 'uninstall', *options], 0).stdout)
        assert outcome['action'] == 'uninstall' and outcome['changed']
        target = claude_settings if provider == 'claude' else hooks / 'codex/hooks.json'
        assert 'MARU_HOOK_V3' not in target.read_text()
    assert json.loads(claude_settings.read_text())['keep'] == 'sentinel'
    assert '# keep sentinel' in codex_config.read_text()
    assert 'MARU_HOOK_V3' not in codex_config.read_text()
    streams = root / 'stream-fixture'
    streams.mkdir()
    stream_dirs = [streams / 'first', streams / 'last']
    for directory in stream_dirs:
        directory.mkdir()
        stale = directory / 'a.ndjson'
        stale.write_text('claude\t{"tag":"stale"}\n')
        os.utime(stale, (0, 0))
    before = {str(p): (p.lstat().st_mode, p.read_bytes() if p.is_file() else None)
              for p in streams.rglob('*')}
    options = ['--stdio', f'--dir={stream_dirs[0]}', '--heartbeat-ms=0', '--resume=']
    extras = [f'--dir={stream_dirs[0]}', f'--dir={stream_dirs[1]}', '--heartbeat-ms=0',
              '--heartbeat-ms=00', '--heartbeat-ms=200', '--resume=', '--resume=a:0']
    for order in itertools.permutations(options):
        for extra in extras:
            p = run(['agent-events', *order, extra], 1)
            assert not p.stdout and 'may only be specified once' in p.stderr
    for first, last in [('--dir=', f'--dir={stream_dirs[0]}'), ('--dir=relative', f'--dir={stream_dirs[0]}'),
                        ('--resume=invalid', '--resume='), ('--heartbeat-ms=0', '--heartbeat-ms=4294967295')]:
        run(['agent-events', '--stdio', f'--dir={stream_dirs[0]}', first, last], 1)
    for flag in ['--help', '-h']:
        run(['agent-events', flag, *options, extras[1]], 0)
        p = run(['agent-events', *options, extras[1], flag], 1)
        assert not p.stdout
    after = {str(p): (p.lstat().st_mode, p.read_bytes() if p.is_file() else None)
             for p in streams.rglob('*')}
    assert before == after, 'rejected stream options started log cleanup'

    # A real bounded stream proves we did not merely disable startup to pass negatives.
    active = streams / 'active' / '--heartbeat-ms=0'
    active.mkdir(parents=True)
    first_line = b'claude\t{"tag":"first"}\n'
    second_line = b'claude\t{"tag":"second"}\n'
    (active / 'a.ndjson').write_bytes(first_line + second_line)

    def check_stream(extra, expected_tags, heartbeat):
        args = ['agent-events', '--stdio', f'--dir={active}', *extra]
        proc = subprocess.Popen([str(cli), *args], cwd=root, env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        selector = selectors.DefaultSelector()
        output = bytearray()
        pending = bytearray()
        frames = []
        settled = None
        try:
            selector.register(proc.stdout, selectors.EVENT_READ)
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                now = time.monotonic()
                if settled is not None and now >= settled:
                    break
                wait_until = min(deadline, settled) if settled is not None else deadline
                for key, _ in selector.select(max(0, wait_until - now)):
                    chunk = os.read(key.fd, 65536)
                    assert chunk, 'stream closed before fixture stopped it'
                    output.extend(chunk)
                    pending.extend(chunk)
                    while b'\n' in pending:
                        line, _, remainder = pending.partition(b'\n')
                        pending[:] = remainder
                        frames.append(json.loads(line))
                tags = [json.loads(f['line'].split('\t', 1)[1])['tag'] for f in frames if 'line' in f]
                cursor = any(f.get('cur') == 'a' and f.get('at') == len(first_line + second_line) for f in frames)
                hb = any(f.get('hb') == 0 for f in frames)
                if frames and tags == expected_tags and (cursor or not expected_tags) and (hb or not heartbeat) and settled is None:
                    settled = time.monotonic() + 0.35
            assert frames and frames[0] == {'hello': 'maru-agent-events', 'v': 1}, frames
            assert tags == expected_tags and (cursor or not expected_tags), frames
            assert hb if heartbeat else not any('hb' in f for f in frames), frames
            assert settled is not None, frames
        finally:
            selector.close()
            controlled = proc.poll() is None
            if controlled:
                proc.terminate()
            try:
                tail, stderr = proc.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
                tail, stderr = proc.communicate(timeout=3)
            output.extend(tail)
            record(args, proc.returncode, bytes(output), stderr, fixture_terminated=controlled)
        assert controlled, 'normal stream exited on its own'

    check_stream([], ['first', 'second'], False)
    check_stream(['--stdio', '--heartbeat-ms=0', '--resume='], ['first', 'second'], False)
    check_stream(['--heartbeat-ms=200', f'--resume=a:{len(first_line)}'], ['second'], True)
    check_stream(['--heartbeat-ms=200', f'--resume=a:{len(first_line + second_line)}'], [], True)
    control = root / 'cache/maru/control'
    control.mkdir(parents=True)
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(str(control / 'fixture.sock'))
    listener.listen()
    listener.settimeout(10)
    # Help cannot connect to reachable control endpoints or modify persistent state.
    before = {str(p.relative_to(root)): p.read_bytes() for p in root.rglob('*') if p.is_file() and p != root / 'results.json'}
    rid = '0000000000000000000000000000aabb'
    for flag in ['--help', '-h']:
        for args in [[flag], ['terminfo', flag], ['control', flag], ['host', 'status', flag],
                     ['host', 'status', '--json', flag], ['runtime', 'list', flag],
                     ['runtime', 'get', flag], ['runtime', 'get', rid, '--json', flag],
                     ['runtime', 'end', flag], ['runtime', 'end', rid, '--yes', flag]]:
            assert 'usage:' in run(args, 0).stdout
    for args in [['--help', '--bad'], ['-h', 'extra'], ['terminfo', '--clear', '--help'], ['terminfo', '--help', '--refresh'],
                 ['control', '--stdio', '--help'], ['control', '--help', '--stdio'],
                 ['host', 'unknown', '--help'], ['host', 'status', '--bad', '--help'],
                 ['runtime', 'unknown', '--help'], ['runtime', 'get', 'bad', '--help'],
                 ['runtime', 'end', 'bad', '--help'],
                 ['runtime', 'end', rid, '--yes', '--yes', '--help']]:
        run(args, 2 if args[0] in ['host', 'runtime'] else 1)
    after = {str(p.relative_to(root)): p.read_bytes() for p in root.rglob('*') if p.is_file() and p != root / 'results.json'}
    assert before == after, 'help or rejected arguments changed filesystem state'
    target_verbs = [
        ['navigate', 'https://example.invalid/'], ['get-url'], ['exec', '1+1'],
        ['get-cookies'], ['set-cookie', '--name', 'n', '--value', 'v'],
        ['delete-cookie', '--name', 'n'], ['get-local-storage', '--key', 'k'],
        ['set-local-storage', '--key', 'k', '--value', 'v'],
        ['remove-local-storage', '--key', 'k'], ['clear-storage'],
        ['click', '--ref', 'e1'], ['type', '--ref', 'e1', '--text', 't'],
        ['scroll', '--ref', 'e1'], ['wait', '--load'], ['snapshot'], ['console'],
        ['screenshot', '--out', 'preserved.png'],
    ]
    sentinel = root / 'preserved.png'
    sentinel.write_bytes(b'KEEP SCREENSHOT OUTPUT')
    for verb in target_verbs:
        for first in [['--surface', '1'], ['--surface=1']]:
            for second in [['--surface', '1'], ['--surface', '2'], ['--surface=1'], ['--surface=2']]:
                p = run(['browser', verb[0], *first, *verb[1:], *second], 1)
                assert '--surface may only be specified once' in p.stderr
                assert sentinel.read_bytes() == b'KEEP SCREENSHOT OUTPUT'
    for first in [['--window', '1'], ['--window=1'], ['--window', '0'], ['--window=0']]:
        for second in [['--window', '1'], ['--window=1'], ['--window', '2'], ['--window=2'], ['--window=0'], ['--window=01']]:
            p = run(['sessions', 'list', *first, *second], 1)
            assert '--window may only be specified once' in p.stderr
    for namespace in [['editor', 'lsp'], ['lsp']]:
        for verb in ['revoke', 'forget']:
            for first in [['--volume', 'a'], ['--volume=A'], ['--volume', '0'], ['--volume=0']]:
                for second in [['--volume', 'a'], ['--volume=A'], ['--volume', 'b'], ['--volume=b'], ['--volume=0'], ['--volume=0a']]:
                    p = run([*namespace, 'trust', verb, '/fixture/repository', *first, *second], 1)
                    assert '--volume may only be specified once' in p.stderr
    # A reachable endpoint exists: rejection must happen before even auth is sent.
    listener.settimeout(0.05)
    try:
        connection, _ = listener.accept()
    except socket.timeout:
        pass
    else:
        connection.close()
        raise AssertionError('duplicate target invocation connected to the endpoint')
    listener.settimeout(10)
    plans = []
    for args, result in [(['sessions', 'list'], []), (['browser', 'get-url', '--surface', '1'], {'url': 'https://example.invalid/'}), (['browser', 'navigate', '--surface', '1', 'https://example.invalid/'], {'ok': True}), (['editor', 'lsp', 'trust', 'list'], {'decisions': []})]:
        for kind in ['success', 'error', 'malformed', 'wrong-envelope']:
            plans.append((args, kind, result))
    selector_positive = []
    for option, value in [(['--window', '2'], 2), (['--window=0'], 0), (['--window=01'], 1)]:
        args = ['sessions', 'list', *option]
        plans.append((args, 'success', []))
        selector_positive.append((args, 'sessions.list', {'window': value}))
    for namespace in [['editor', 'lsp'], ['lsp']]:
        for verb in ['revoke', 'forget']:
            for option, value in [(['--volume', 'A'], 'a'), (['--volume=0'], '0'), (['--volume=0a'], 'a')]:
                args = [*namespace, 'trust', verb, '/fixture/repository', *option]
                plans.append((args, 'success', {'changed': True, 'saved': True, 'previous': 'allow'}))
                selector_positive.append((args, 'lsp.trust.' + verb, {'path': '/fixture/repository', 'volume': value}))
    for namespace in [['editor', 'lsp'], ['lsp']]:
        for verb in ['revoke', 'forget']:
            args = [*namespace, 'trust', verb, '/fixture/repository']
            plans.append((args, 'success', {'changed': True, 'saved': True, 'previous': 'allow'}))
            selector_positive.append((args, 'lsp.trust.' + verb, {'path': '/fixture/repository'}))
    wire_seen = []
    # Empty wrapped results are successful, not protocol failures.
    plans += [(['browser', 'snapshot', '--surface', '1'], 'success', {'snapshot': {'tree': []}}), (['browser', 'console', '--surface', '1'], 'success', {'console': []})]
    errors = []

    def serve():
        try:
            for _, kind, result in plans:
                conn, _ = listener.accept()
                with conn:
                    conn.settimeout(10)
                    f = conn.makefile('rb')
                    auth = json.loads(f.readline())
                    req = json.loads(f.readline())
                    wire_seen.append((auth, req))
                    if kind == 'malformed':
                        wire = 'invalid-json'
                    elif kind == 'wrong-envelope':
                        wire = json.dumps({'jsonrpc': '2.0', 'method': 'fixture.notification'})
                    elif kind == 'error':
                        wire = json.dumps({'jsonrpc': '2.0', 'id': req['id'], 'error': {'code': -32601, 'message': 'fixture error'}})
                    else:
                        wire = json.dumps({'jsonrpc': '2.0', 'id': req['id'], 'result': result})
                    conn.sendall((wire + '\n').encode())
                    f.close()
        except Exception as exc:
            errors.append(repr(exc))
        finally:
            listener.close()

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    for args, kind, _ in plans:
        run(args, 0 if kind == 'success' else 1)
        for positive_args, method, params in selector_positive:
            if args == positive_args:
                auth, req = wire_seen[-1]
                assert req['method'] == method and req['params'] == params, req
                if method.startswith('lsp.'):
                    assert auth['params'] == {}, auth
    thread.join(timeout=10)
    assert not thread.is_alive() and not errors, errors
    (root / 'results.json').write_text(json.dumps(records, indent=2) + '\n')
    return len(records)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cli', type=Path, default=Path('zig-out/bin/maru'))
    parser.add_argument('--repeat', type=int, default=1)
    parser.add_argument('--output-dir', type=Path)
    opts = parser.parse_args()
    if opts.repeat < 1:
        parser.error('--repeat must be at least 1')
    if opts.output_dir:
        opts.output_dir.mkdir(parents=True, exist_ok=True)
    cli = opts.cli.resolve(strict=True)
    for index in range(opts.repeat):
        root = Path(tempfile.mkdtemp(prefix='maru-cli-failure-', dir='/tmp'))
        try:
            count = verify(cli, root)
        finally:
            # Keep AF_UNIX endpoints in short /tmp paths, independent of CI checkout length.
            if opts.output_dir and (root / 'results.json').exists():
                shutil.copy2(root / 'results.json', opts.output_dir / f'{root.name}.json')
        print(f'iteration {index + 1}: {count} process checks passed; evidence: {root}', flush=True)


if __name__ == '__main__':
    main()
