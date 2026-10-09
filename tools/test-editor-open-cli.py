#!/usr/bin/env python3
"""Test the built CLI through its real execve boundary without opening user files.

A test-only DYLD interposer records argv and simulates exec failure. This verifies
CLI process wiring, not LaunchServices delivery or application-level file opening.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import socket
import threading
from urllib.parse import quote

INTERPOSER = r'''
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static int capture_exec(const char *path, char *const argv[], char *const envp[]) {
    (void)envp;
    if (strcmp(path, "/usr/bin/open")) _exit(95);
    FILE *f = fopen(getenv("MARU_CLI_TEST_CAPTURE"), "wb");
    if (!f) _exit(96);
    for (size_t i = 0; argv[i]; ++i) fwrite(argv[i], 1, strlen(argv[i]) + 1, f);
    fclose(f);
    if (getenv("MARU_CLI_TEST_DENIED")) { errno = EACCES; return -1; }
    _exit(0);
}
__attribute__((used)) static struct { const void *replacement; const void *original; }
interpose __attribute__((section("__DATA,__interpose"))) = {capture_exec, execve};
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    cli = args.cli.resolve()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        parser.error('output must be empty')
    source = out/'capture.c'
    source.write_text(INTERPOSER)
    dylib = out/'capture.dylib'
    subprocess.run(['/usr/bin/clang', '-dynamiclib', str(source), '-o', str(dylib)], check=True)
    cwd = out/'cwd'
    cwd.mkdir()
    (cwd/'link').symlink_to('/tmp')
    capture = out/'argv.bin'
    env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(dylib), MARU_CLI_TEST_CAPTURE=str(capture))
    results = []

    def run(name, arguments, expected_url=None, denied=False):
        capture.unlink(missing_ok=True)
        current = dict(env)
        if denied:
            current['MARU_CLI_TEST_DENIED'] = '1'
        result = subprocess.run([str(cli), 'editor', 'open', *arguments], cwd=cwd, env=current, capture_output=True, timeout=15)
        delivered = capture.read_bytes().split(b'\0')[:-1] if capture.exists() else None
        if expected_url is not None:
            assert delivered == [b'/usr/bin/open', expected_url.encode()], (name, delivered, result.returncode, result.stderr)
            assert result.returncode == (1 if denied else 0), (name, result.stderr)
            if denied:
                assert b'cannot execute OS URL delivery' in result.stderr
        else:
            assert delivered is None and result.returncode == 1, (name, delivered, result.returncode)
            assert b'usage:' in result.stderr or b'invalid path' in result.stderr
        assert b'stack trace' not in result.stderr
        results.append(dict(name=name, exit_code=result.returncode, delivered=delivered is not None))

    filenames = ['a file 한😀%2F&=#.zig', 'link/../actual.zig', '$(touch injected)`id`"\'.zig', '-option.zig']
    for index, filename in enumerate(filenames):
        url = 'maru://open?path='+quote(str(cwd)+'/'+filename, safe='~')+'&line=2&column=3'
        run('relative-'+str(index), ['-l', '2', '-c', '3', '--', filename], url)
    url = 'maru://open?path='+quote('/tmp/file +%.zig', safe='~')
    run('absolute', ['/tmp/file +%.zig'], url)
    run('delivery-failure', ['/tmp/file +%.zig'], url, denied=True)
    for index, arguments in enumerate([[], [''], ['a', 'b'], ['a', '--line', '0'], ['a', '--line', '4294967296'], ['a', '--column', '1'], ['a', '--line', '1', '--line', '2'], ['a\n'], ['a'*4097], ['a', '--wat'], ['a', '-l', '1', '--line', '2'], ['a', '-l', '1', '-c', '2', '--column', '3'], ['a']*10]):
        run('reject-'+str(index), arguments)
    assert not (cwd/'injected').exists()
    capture.unlink(missing_ok=True)
    help_result = subprocess.run([str(cli), 'editor', 'open', '--help'], cwd=cwd, env=env, capture_output=True, timeout=15)
    assert help_result.returncode == 0 and b'UTF-16' in help_result.stdout and not capture.exists()
    for arguments in [[], ['--help'], ['-h']]:
        result = subprocess.run([str(cli), 'editor', *arguments], cwd=cwd, env=env, capture_output=True, timeout=15)
        assert result.returncode == 0 and b'Editor commands:' in result.stdout and not capture.exists()
    for arguments in [['editor', 'unknown'], ['editor', 'editor'], ['editor', 'editor', 'open', 'a'], ['editor', 'open', 'editor', 'editor'], ['editor', 'open', '--help', 'editor'], ['editor', '--', 'editor'], ['editor', 'lsp', 'editor'], ['editor', 'lsp', 'trust', 'editor'], ['open', 'a']]:
        result = subprocess.run([str(cli), *arguments], cwd=cwd, env=env, capture_output=True, timeout=15)
        assert result.returncode == 1 and not capture.exists()
    run('filename-editor', ['editor'], 'maru://open?path='+quote(str(cwd)+'/editor', safe='~'))
    run('filename-help', ['--', '--help'], 'maru://open?path='+quote(str(cwd)+'/--help', safe='~'))
    capture.unlink(missing_ok=True)
    canonical = subprocess.run([str(cli), 'editor', 'lsp', '--help'], cwd=cwd, env=env, capture_output=True, timeout=15)
    legacy = subprocess.run([str(cli), 'lsp', '--help'], cwd=cwd, env=env, capture_output=True, timeout=15)
    assert canonical.returncode == legacy.returncode == 0
    assert canonical.stdout == legacy.stdout and b'maru editor lsp trust' in canonical.stdout
    assert not capture.exists()
    # Fail before IPC: compare both entrypoints without changing live trust state.
    for arguments in [[], ['editor'], ['trust', 'grant'], ['trust', 'revoke'], ['trust', 'list', 'editor']]:
        canonical = subprocess.run([str(cli), 'editor', 'lsp', *arguments], cwd=cwd, env=env, capture_output=True, timeout=15)
        legacy = subprocess.run([str(cli), 'lsp', *arguments], cwd=cwd, env=env, capture_output=True, timeout=15)
        assert canonical.returncode == legacy.returncode == 1
        assert canonical.stderr == legacy.stderr and not capture.exists()
    # A private fake socket verifies successful dispatch and exact wire parity;
    # revoke/forget never reach a real application's trust table.
    control = out/'ipc/maru/control'
    control.mkdir(parents=True, mode=0o700)
    socket_path = control/'fixture.sock'
    requests, failures = [], []
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(str(socket_path))
    listener.listen()
    listener.settimeout(10)

    def serve():
        try:
            for _ in range(6):
                connection, _ = listener.accept()
                with connection:
                    connection.settimeout(10)
                    stream = connection.makefile('rb')
                    auth = json.loads(stream.readline())
                    request = json.loads(stream.readline())
                    requests.append((auth, request))
                    payload = {'decisions': []} if request['method'] == 'lsp.trust.list' else {'previous': None, 'changed': False, 'saved': True}
                    connection.sendall((json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': payload})+'\n').encode())
        except Exception as error:
            failures.append(str(error))
        finally:
            listener.close()

    server = threading.Thread(target=serve, daemon=True)
    server.start()
    private_env = dict(env, HOME=str(out/'home'), XDG_CACHE_HOME=str(out/'ipc'), MARU_PANE_ID='987654321')
    for operation in ['list', 'revoke', 'forget']:
        arguments = ['trust', operation]+([] if operation == 'list' else ['/fixture/repository', '--volume', 'ab'])
        canonical = subprocess.run([str(cli), 'editor', 'lsp', *arguments], cwd=cwd, env=private_env, capture_output=True, timeout=15)
        legacy = subprocess.run([str(cli), 'lsp', *arguments], cwd=cwd, env=private_env, capture_output=True, timeout=15)
        assert canonical.returncode == legacy.returncode == 0, (operation, canonical.stderr, legacy.stderr)
        assert canonical.stdout == legacy.stdout and canonical.stdout
        first, second = requests[-2:]
        assert first[0] == {'jsonrpc': '2.0', 'method': 'auth.self', 'params': {}}
        assert first == second and first[1]['method'] == 'lsp.trust.'+operation
        if operation != 'list':
            assert first[1]['params'] == {'path': '/fixture/repository', 'volume': 'ab'}
        assert not capture.exists()
    server.join(timeout=10)
    assert not server.is_alive() and not failures and len(requests) == 6
    (out/'lsp-wire.json').write_text(json.dumps(requests, indent=2)+'\n')
    root_help = subprocess.run([str(cli), '--help'], cwd=cwd, env=env, capture_output=True, timeout=15)
    assert root_help.returncode == 0 and b'maru editor open' in root_help.stdout
    assert b'  editor ' in root_help.stdout
    (out/'result.json').write_text(json.dumps(dict(passed=True, scope='CLI process argv and exec failure; OS delivery is separate', results=results), indent=2)+'\n')
    print(out/'result.json')


if __name__ == '__main__':
    main()
