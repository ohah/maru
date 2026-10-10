"""Real pipe and disk recovery checks; called by the default CLI process gate."""
import json
import os
from pathlib import Path
import selectors
import subprocess
import time


def verify_recovery(cli, root, env, record):
    fixture = root / 'recovery'
    fixture.mkdir()
    # Fixture boundary: src/session/agent_hook_event.zig rotate_at_bytes.
    prefix = 1024 * 1024

    class Stream:
        def __init__(self, directory, resume=''):
            self.directory = directory
            directory.mkdir(exist_ok=True)
            self.args = ['agent-events', '--stdio', f'--dir={directory}',
                         '--heartbeat-ms=1000', f'--resume={resume}']
            self.proc = subprocess.Popen([str(cli), *self.args], cwd=root, env=env,
                                         stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE)
            self.selector = selectors.DefaultSelector()
            self.selector.register(self.proc.stdout, selectors.EVENT_READ)
            self.output = bytearray()
            self.pending = bytearray()
            self.frames = []

        def until(self, predicate):
            deadline = time.monotonic() + 15
            while not predicate(self.frames):
                remaining = deadline - time.monotonic()
                assert remaining > 0, self.frames
                for key, _ in self.selector.select(remaining):
                    chunk = os.read(key.fd, 65536)
                    assert chunk, ('unexpected EOF', self.frames)
                    self.output.extend(chunk)
                    self.pending.extend(chunk)
                    while b'\n' in self.pending:
                        line, _, rest = self.pending.partition(b'\n')
                        self.pending[:] = rest
                        self.frames.append(json.loads(line))
            assert self.frames[0] == {'hello': 'maru-agent-events', 'v': 1}

        def ready(self):
            # The first heartbeat proves startup cleanup has finished. A full second
            # until the next heartbeat lets the closed-pipe case reach file consumption.
            self.until(lambda fs: any(f.get('hb') == 0 for f in fs))

        def stop(self, broken=False):
            self.selector.close()
            controlled = self.proc.poll() is None and not broken
            if controlled:
                self.proc.terminate()
            try:
                if broken:
                    self.proc.wait(timeout=5)
                    tail, stderr = b'', self.proc.stderr.read()
                else:
                    tail, stderr = self.proc.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                if broken:
                    self.proc.wait(timeout=3)
                    tail, stderr = b'', self.proc.stderr.read()
                else:
                    tail, stderr = self.proc.communicate(timeout=3)
                record(self.args, self.proc.returncode, bytes(self.output) + tail, stderr,
                       failure='recovery-timeout', fixture_terminated=True)
                raise
            self.output.extend(tail)
            record(self.args, self.proc.returncode, bytes(self.output), stderr,
                   fixture_terminated=controlled)
            if broken:
                assert self.proc.returncode != 0 and b'WriteFailed' in stderr, stderr
            else:
                assert controlled and not stderr, stderr

    def line(tag):
        return ('claude\t' + json.dumps({'tag': tag}, separators=(',', ':')) + '\n').encode()

    def tags(stream):
        return [json.loads(f['line'].split('\t', 1)[1])['tag']
                for f in stream.frames if 'line' in f]

    def cursor(offset):
        return lambda fs: any(f.get('cur') == 'a' and f.get('at') == offset for f in fs)

    def replace(directory, data):
        pending = directory / 'pending'
        pending.write_bytes(data)
        pending.chmod(0o600)
        os.replace(pending, directory / 'a.ndjson')

    # Shrink in place, then replace with a shorter file. Both must restart at zero.
    directory = fixture / 'rotation'
    stream = Stream(directory)
    try:
        stream.ready()
        original = line('first') + line('second')
        replace(directory, original)
        stream.until(cursor(len(original)))
        (directory / 'a.ndjson').write_bytes(line('third'))
        stream.until(cursor(len(line('third'))))
        replace(directory, line('x'))
        stream.until(cursor(len(line('x'))))
        assert tags(stream) == ['first', 'second', 'third', 'x'], stream.frames
    finally:
        stream.stop()
    stream = Stream(directory, f'a:{len(line("x"))}')
    try:
        stream.ready()
        assert tags(stream) == [], stream.frames
        with (directory / 'a.ndjson').open('ab') as file:
            file.write(line('after'))
        stream.until(cursor(len(line('x') + line('after'))))
        assert tags(stream) == ['after'], stream.frames
    finally:
        stream.stop()

    # Consume the small tail of an already-read large log, then observe reset zero.
    directory = fixture / 'truncate'
    stream = Stream(directory, f'a:{prefix}')
    tail = line('tail')
    try:
        stream.ready()
        replace(directory, b'x' * prefix + tail)
        stream.until(cursor(0))
        assert tags(stream) == ['tail'], stream.frames
        assert cursor(prefix + len(tail))(stream.frames), stream.frames
        assert (directory / 'a.ndjson').read_bytes() == b''
        assert (directory / 'a.ndjson').stat().st_mode & 0o777 == 0o600
    finally:
        stream.stop()
    stream = Stream(directory, 'a:0')
    try:
        stream.ready()
        replace(directory, line('new'))
        stream.until(cursor(len(line('new'))))
        assert tags(stream) == ['new'], stream.frames
    finally:
        stream.stop()

    # A dead consumer must not let buffered output erase the only disk copy.
    for large in [False, True]:
        directory = fixture / ('broken-large' if large else 'broken-small')
        offset = prefix if large else 0
        stream = Stream(directory, f'a:{offset}')
        payload = b'x' * offset + tail
        try:
            stream.ready()
            stream.selector.unregister(stream.proc.stdout)
            stream.proc.stdout.close()
            replace(directory, payload)
        finally:
            stream.stop(broken=True)
        assert (directory / 'a.ndjson').read_bytes() == payload, 'output failure erased log'
        assert (directory / 'a.ndjson').stat().st_mode & 0o777 == 0o600
