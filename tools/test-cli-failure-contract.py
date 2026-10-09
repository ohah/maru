#!/usr/bin/env python3
"""Exercise real CLI failure contracts using private HOME/files and a fake endpoint."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading


def verify(cli, root):
    home = root / 'home'
    home.mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith(('MARU_', 'XDG_', 'DYLD_'))}
    env.update(HOME=str(home), CFFIXED_USER_HOME=str(home), XDG_CACHE_HOME=str(root / 'cache'))
    records = []

    def run(args, expected):
        p = subprocess.run([str(cli), *args], cwd=root, env=env, capture_output=True, text=True, timeout=15)
        records.append(dict(args=args, exit=p.returncode, stdout=p.stdout, stderr=p.stderr))
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
    control = root / 'cache/maru/control'
    control.mkdir(parents=True)
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(str(control / 'fixture.sock'))
    listener.listen()
    listener.settimeout(10)
    # Help cannot connect to reachable control endpoints or modify persistent state.
    before = {str(p.relative_to(root)): p.read_bytes() for p in root.rglob('*') if p.is_file()}
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
    after = {str(p.relative_to(root)): p.read_bytes() for p in root.rglob('*') if p.is_file()}
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
                    json.loads(f.readline())
                    req = json.loads(f.readline())
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
    thread.join(timeout=10)
    assert not thread.is_alive() and not errors, errors
    (root / 'results.json').write_text(json.dumps(records, indent=2) + '\n')
    return len(records)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cli', type=Path, default=Path('zig-out/bin/maru'))
    parser.add_argument('--repeat', type=int, default=1)
    opts = parser.parse_args()
    cli = opts.cli.resolve(strict=True)
    for index in range(opts.repeat):
        root = Path(tempfile.mkdtemp(prefix='maru-cli-failure-', dir='/tmp'))
        count = verify(cli, root)
        print(f'iteration {index + 1}: {count} process checks passed; evidence: {root}', flush=True)


if __name__ == '__main__':
    main()
