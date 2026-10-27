#!/usr/bin/env python3
"""Adversarial hook receipt checks; --live adds two real TUI clients on one private server.
No provider/model service is contacted: the private provider points at localhost:9.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time

PATTERN = rb'MARU_SESSION_V1:[0-9a-fA-F-]{36}:[0-9a-f]{32}:[0-9]+!'
SID = '12345678-1234-1234-1234-123456789abc'


def run(executable, root, event):
    result = subprocess.run([executable, 'agent-hooks', 'codex-receipt', str(root / 'registry')],
                            input=json.dumps(event), text=True, capture_output=True, timeout=5, check=True)
    assert not result.stderr, result.stderr
    return result.stdout


def marker(output):
    return re.search(PATTERN, output.encode() if isinstance(output, str) else output).group().decode()


def live(executable, root):
    home = root / 'codex'
    home.mkdir()
    work = root / 'work'
    work.mkdir()
    env = os.environ.copy()
    env.update(CODEX_HOME=str(home), TERM='xterm-256color', MARU_HOOK_PANE='same-inherited-pane')
    for key in list(env):
        if key.startswith('OPENAI_') or key in ('CODEX_API_KEY', 'CODEX_THREAD_ID'):
            env.pop(key, None)
    # Installed production command, isolated HOME determines only the receipt registry.
    install_env = dict(env, HOME=str(root), LC_MARU_PANE='probe', LC_MARU_LOG_FORMAT='1')
    events = root / 'events'
    events.mkdir(mode=0o700)
    home.joinpath('config.toml').write_text('''model = "gpt-5.3-codex"
model_provider = "maru_probe"
approval_policy = "never"
sandbox_mode = "read-only"
[model_providers.maru_probe]
name = "Maru probe"
base_url = "http://127.0.0.1:9/v1"
wire_api = "responses"
requires_openai_auth = false
[tui]
alternate_screen = "never"
show_tooltips = false
[projects.''' + json.dumps(str(work)) + ''']
trust_level = "trusted"
''')
    subprocess.run([executable, 'agent-hooks', 'install', '--provider=codex', '--scope=remote', '--dir=' + str(events)],
                   env=install_env, capture_output=True, check=True, timeout=20)
    socket = root / 'server.sock'
    with (root / 'server.log').open('wb') as logfile:
        server = subprocess.Popen(['codex', 'app-server', '--listen', 'unix://' + str(socket)],
                                  env=env, cwd=work, stdout=logfile, stderr=logfile, start_new_session=True)
        clients = []
        try:
            deadline = time.monotonic() + 15
            while not socket.exists():
                assert server.poll() is None, 'private server failed'
                assert time.monotonic() < deadline, 'socket timeout'
                time.sleep(.1)
            # Both clients stay alive; hook environment and cwd are identical.
            for _ in range(2):
                pid, fd = pty.fork()
                if pid == 0:
                    os.chdir(work)
                    os.execvpe('codex', ['codex', '--remote',
                                        'unix://' + str(socket), '--no-alt-screen'], env)
                clients.append([pid, fd, b'', time.monotonic(), 0])
                fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 240, 0, 0))
            deadline = time.monotonic() + 25
            while time.monotonic() < deadline:
                for client in clients:
                    pid, fd, output, started, state = client
                    if state == 0 and time.monotonic() - started > 3:
                        os.write(fd, '계속'.encode())
                        client[4] = 1
                    if client[4] == 1 and time.monotonic() - started > 5:
                        os.write(fd, b'\r')
                        client[4] = 2
                    if select.select([fd], [], [], .05)[0]:
                        data = os.read(fd, 65536)
                        client[2] += data
                        if b'\x1b[6n' in data:
                            os.write(fd, b'\x1b[1;1R')
                        if b'\x1b[c' in data:
                            os.write(fd, b'\x1b[?62;4;22c')
                if all(re.search(PATTERN, c[2]) for c in clients):
                    break
            values = [marker(client[2]) for client in clients]
            ids = [value.split(':')[1] for value in values]
            assert ids[0] != ids[1], 'different TUI sessions received the same ID'
            registry = root / '.cache/maru/codex-session-receipts'
            for sid, value in zip(ids, values):
                assert (registry / sid).read_text() == value
            print('live: two simultaneous clients, same cwd, same short prompt, same daemon env: distinct verified receipts', flush=True)
            # Resume the exact first session in a third client on this same daemon.
            pid, fd = pty.fork()
            if pid == 0:
                os.chdir(work)
                os.execvpe('codex', ['codex', '--remote',
                                    'unix://' + str(socket), '--no-alt-screen', 'resume', ids[0]], env)
            clients.append([pid, fd, b'', time.monotonic(), 0])
            fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 240, 0, 0))
            # A live cached thread does not rerun SessionStart on rejoin. This is
            # a distinct client launch with explicit resume UUID, the production
            # argv fallback's evidence; do not pretend the old receipt is fresh.
            time.sleep(2)
            arguments = subprocess.check_output(['/bin/ps', '-p', str(pid), '-o', 'command='], text=True)
            assert 'resume ' + ids[0] in arguments
            assert (registry / ids[0]).read_text() == values[0]
            print('live cached resume: no new SessionStart; client-owned explicit resume UUID available (kernel extraction covered by app test)', flush=True)
        finally:
            for pid, *_ in clients:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            try:
                os.killpg(server.pid, signal.SIGTERM)
                server.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(server.pid, signal.SIGKILL)
                server.wait()
            for pid, fd, *_ in clients:
                try:
                    os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    pass
                os.close(fd)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('executable')
    parser.add_argument('--live', action='store_true')
    args = parser.parse_args()
    executable = str(Path(args.executable).resolve())
    with tempfile.TemporaryDirectory(prefix='maru-receipt-') as directory:
        root = Path(directory)
        event = {'session_id': SID, 'hook_event_name': 'SessionStart', 'source': 'startup'}
        first = marker(run(executable, root, event))
        assert (root / 'registry' / SID).read_text() == first
        assert (root / 'registry').stat().st_mode & 0o777 == 0o700
        assert (root / 'registry' / SID).stat().st_mode & 0o777 == 0o600
        second = marker(run(executable, root, dict(event, source='resume')))
        assert first != second and (root / 'registry' / SID).read_text() == second
        print('replay: resume replaces token; old screen receipt no longer matches registry', flush=True)
        for sid in ('../../escape', SID + 'a' * 1000, SID + '\\n', SID + '$(touch /tmp/maru-receipt-injection)', '', 123):
            assert not run(executable, root, dict(event, session_id=sid))
        assert not run(executable, root, dict(event, hook_event_name='UserPromptSubmit'))
        print('hostile input: path, oversized/malformed ID and wrong event rejected', flush=True)
        if args.live:
            live(executable, root)


if __name__ == '__main__':
    main()
