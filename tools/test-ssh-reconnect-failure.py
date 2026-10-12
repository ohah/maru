#!/usr/bin/env python3
"""Product CLI subprocess: immediate SSH failures and Ctrl-C during backoff.
The SSH executable is an owned fault injector; no server or user config is touched.
"""
import argparse
import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cli', required=True)
    args = parser.parse_args()
    cli = str(Path(args.cli).resolve())
    with tempfile.TemporaryDirectory(prefix='ssh-retry-failure-', dir='/tmp') as raw:
        root = Path(raw).resolve()
        root.chmod(0o700)
        bindir = root / 'bin'; bindir.mkdir()
        cache = root / '.cache/maru'; cache.mkdir(parents=True)
        (cache / 'ssh-terminfo-hosts').write_text('failure-fixture\n')
        config = root / 'config'; config.write_text('sidebar.agent-hooks = false\nssh.reconnect = true\n')
        trace = root / 'attempts'
        fake = bindir / 'ssh'
        fake.write_text('#!/bin/sh\nprintf "attempt\\n" >> "$SSH_FAILURE_TRACE"\nexit 255\n')
        fake.chmod(0o700)
        env = dict(os.environ, HOME=str(root), XDG_CACHE_HOME=str(root / '.cache'),
                   MARU_CONFIG=str(config), SSH_FAILURE_TRACE=str(trace),
                   PATH=str(bindir) + ':/usr/bin:/bin')
        for key in ['TMUX', 'TMUX_PANE', 'MARU_HOOK_INSTANCE', 'MARU_HOOK_PANE']:
            env.pop(key, None)
        result = subprocess.run([cli, 'ssh', '-T', 'failure-fixture'], env=env,
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=10)
        assert result.returncode == 255, result.stderr
        assert trace.read_text().splitlines() == ['attempt'] * 3
        assert b'giving up after 3 attempts' in result.stderr
        assert result.stdout.count(b'\x1b]5379;ssh;') == 3
        assert result.stdout.count(b'\x1b]5379;ssh-end') == 3
        print(json.dumps({'case': 'unreachable', 'attempts': 3, 'exit': 255}), flush=True)
        trace.unlink()
        proc = subprocess.Popen([cli, 'ssh', '-T', 'failure-fixture'], env=env,
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, start_new_session=True)
        lines = queue.Queue()
        reader = threading.Thread(target=lambda: [lines.put(line) for line in iter(proc.stderr.readline, b'')], daemon=True)
        reader.start()
        try:
            deadline = time.monotonic() + 5
            while True:
                line = lines.get(timeout=max(.01, deadline - time.monotonic()))
                if b'reconnecting in' in line:
                    break
                assert time.monotonic() < deadline
            os.killpg(proc.pid, signal.SIGINT)  # Owned foreground group, as Ctrl-C signals.
            proc.wait(timeout=3)
            output = proc.stdout.read()
            assert proc.returncode == 130, proc.returncode
            assert trace.read_text().splitlines() == ['attempt']
            try:
                os.killpg(proc.pid, 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError('owned retry process group still exists after cancellation')
            assert output.count(b'\x1b]5379;ssh;') == 1
            assert output.count(b'\x1b]5379;ssh-end') == 1
            print(json.dumps({'case': 'cancel-backoff', 'attempts': 1, 'exit': 130}), flush=True)
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGKILL); proc.wait(timeout=3)
            proc.stdout.close(); proc.stderr.close(); reader.join(timeout=1)


if __name__ == '__main__':
    main()
