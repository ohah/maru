#!/usr/bin/env python3
"""Real daemon/PTY regression for ending a runtime during a partial snapshot.

Only a newly created private namespace and children launched by this process are used.
No queue offsets, seals, product close state, or user session hosts are modified.
MRSH framing and the small text-row oracle follow persistent-session-host §10/§12;
this is a CLI/socket product test, not evidence of a GUI reconnect.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid

HEADER = struct.Struct('!4sHHIQQI')
MAX_FRAME = 4 * 1024 * 1024

if not __debug__:
    raise RuntimeError('run this verification without Python optimization')


class TruncatedFrame(Exception):
    def __init__(self, expected, received):
        super().__init__(f'frame truncated: {received}/{expected}')
        self.expected, self.received = expected, received


class Peer:
    def __init__(self, path, kind='gui'):
        self.socket = socket.socket(socket.AF_UNIX)
        try:
            self.socket.settimeout(5)
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
            self.socket.connect(str(path))
            self.sequence = 1
            self.send(1, json.dumps(dict(protocol_min=2, protocol_max=2,
                      client_kind=kind, capabilities=['runtime_ended_v1'])).encode(), 1)
            header, payload = self.receive()
            assert header[2] == 2 and header[4] == 1
            self.hello = json.loads(payload)
            assert self.hello['version'] == 2
        except BaseException:
            self.socket.close()
            raise

    def close(self):
        self.socket.close()

    def send(self, kind, payload=b'', request=0, stream=0):
        self.socket.sendall(HEADER.pack(b'MRSH', 2, kind, 0, request, stream,
                                       len(payload)) + payload)

    def read_exact(self, count):
        chunks, received = [], 0
        deadline = time.monotonic() + 10
        while received < count:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('frame read exceeded its absolute deadline')
            self.socket.settimeout(min(5, remaining))
            chunk = self.socket.recv(count - received)
            if not chunk:
                raise TruncatedFrame(count, received)
            chunks.append(chunk)
            received += len(chunk)
        return b''.join(chunks)

    def read_header(self):
        header = HEADER.unpack(self.read_exact(HEADER.size))
        assert header[:2] == (b'MRSH', 2) and header[-1] <= MAX_FRAME
        return header

    def receive(self):
        header = self.read_header()
        return header, self.read_exact(header[-1])

    def call(self, method, params):
        self.sequence += 1
        self.send(3, json.dumps(dict(method=method, params=params)).encode(), self.sequence)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            header, payload = self.receive()
            if header[2] == 4 and header[4] == self.sequence:
                response = json.loads(payload)
                assert 'error' not in response, (method, response)
                return response['result']
        raise TimeoutError('RPC response deadline expired')

    def snapshot(self, stream):
        chunks, total = [], 0
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            header, payload = self.receive()
            if header[2] == 6 and header[5] == stream:
                total += len(payload)
                assert total <= MAX_FRAME
                chunks.append(payload)
                if header[3] & 1:
                    return b''.join(chunks)
        raise TimeoutError('snapshot completion deadline expired')


def text_rows(payload, cols=80, row_count=24):
    """Decode only complete row/set_runs records; malformed/truncated data must fail.

    Colors and style are fixed 16-byte fields. No marker is searched in raw binary
    or metadata: the oracle reconstructs the text actually described by cell runs.
    """
    rows, offset = [], 0
    while offset < len(payload):
        assert offset + 4 <= len(payload)
        size = struct.unpack_from('!I', payload, offset)[0]
        offset += 4
        record = payload[offset:offset + size]
        assert len(record) == size and size >= 28
        offset += size
        version, kind = struct.unpack_from('!HH', record)
        assert version == 2
        if kind not in (2, 10):
            continue
        body = record[28:]
        start = 2 if kind == 2 else 12
        assert len(body) >= start + 4
        row_index = struct.unpack_from('!H', body, 0 if kind == 2 else 8)[0]
        start_col = 0 if kind == 2 else struct.unpack_from('!H', body, 10)[0]
        assert row_index < row_count and start_col < cols
        count = struct.unpack_from('!I', body, start)[0]
        assert count <= cols * 2
        at, row, cells = start + 4, [], 0
        for _ in range(count):
            assert at + 4 <= len(body)
            length = struct.unpack_from('!I', body, at)[0]
            at += 4
            assert length <= 65536 and at + length + 21 <= len(body)
            grapheme = body[at:at + length].decode('utf-8')
            at += length
            width, repeats = struct.unpack_from('!BI', body, at)
            at += 21
            assert width <= 2 and 0 < repeats <= cols
            assert width != 0 or grapheme == ''
            cells += width * repeats
            assert start_col + cells <= cols
            row.append(grapheme * repeats)
        assert at == len(body)
        if kind == 2:
            assert cells == cols
        rows.append(''.join(row))
    return rows


def wait_for(predicate, timeout=10):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        value = predicate()
        if value:
            return value
        time.sleep(.01)
    raise TimeoutError('owned probe deadline expired')


def identity(pid):
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'uid=,ppid=,lstart=,command='],
                            capture_output=True, text=True, timeout=5, check=True)
    return result.stdout.strip()


def terminate(path, runtime):
    peer = Peer(path, 'admin')
    try:
        assert peer.call('runtime.terminate', dict(runtime_id=runtime)) == {'terminated': True}
    finally:
        peer.close()


def run_case(cli, output, partial):
    output.mkdir()
    root = Path(tempfile.mkdtemp(prefix='mr-end-', dir='/tmp'))
    os.chmod(root, 0o700)
    session = root / 'session-host'
    session.mkdir(mode=0o700)
    host_id = uuid.uuid4().hex
    endpoint = root / 'sh' / (host_id + '.sock')
    env = dict(os.environ, MARU_SESSION_HOST_ROOT=str(root))
    peers, child_pids, result = [], [], None
    created = set()
    with (output / 'launcher.log').open('wb') as log:
        host = subprocess.Popen([str(cli), '__session-host', str(session), str(endpoint), host_id],
                                env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        try:
            def daemon_ready():
                if host.poll() is not None:
                    raise RuntimeError('daemon exited before ready')
                return endpoint.exists()
            wait_for(daemon_ready)
            original = Peer(endpoint)
            peers.append(original)
            assert original.hello['host_id'] == host_id
            sibling_code = ('import os,sys;from pathlib import Path;'
                            f'Path({str(root / "sibling.pid")!r}).write_text(str(os.getpid()));'
                            '\nfor line in sys.stdin:print(line.strip(),flush=True)')
            sibling = original.call('runtime.spawn', dict(argv=['/usr/bin/python3', '-u', '-c', sibling_code], cols=80, rows=24))['runtime_id']
            created.add(sibling)
            attached = original.call('runtime.attach', dict(runtime_id=sibling, mode='controller'))
            sibling_stream = attached['stream_id']
            assert attached['granted']['input']
            original.snapshot(sibling_stream)
            wait_for(lambda: (root / 'sibling.pid').exists())
            sibling_pid = int((root / 'sibling.pid').read_text())
            child_pids.append(sibling_pid)
            sibling_identity = identity(sibling_pid)
            assert sibling_identity.split()[:2] == [str(os.getuid()), str(host.pid)]
            target_code = ('import os,sys,time;from pathlib import Path;'
                           f'Path({str(root / "target.pid")!r}).write_text(str(os.getpid()));'
                           "sys.stdout.write('\\x1b[H'+''.join(chr(33+j%90) for j in range(200*120)));sys.stdout.flush();"
                           f'Path({str(root / "ready")!r}).touch();time.sleep(60)')
            target = original.call('runtime.spawn', dict(argv=['/usr/bin/python3', '-u', '-c', target_code], cols=200, rows=120))['runtime_id']
            created.add(target)
            wait_for(lambda: (root / 'ready').exists())
            target_pid = int((root / 'target.pid').read_text())
            assert identity(target_pid).split()[:2] == [str(os.getuid()), str(host.pid)]
            child_pids.append(target_pid)
            # Observe an actual dense snapshot before starting the slow receive case.
            # This avoids substituting a sleep or child write completion for host core readiness.
            def dense():
                probe = Peer(endpoint)
                try:
                    stream = probe.call('runtime.attach', dict(runtime_id=target, mode='observer'))['stream_id']
                    return len(probe.snapshot(stream)) > 500000
                finally:
                    probe.close()
            wait_for(dense)
            target_stream = original.call('runtime.attach', dict(runtime_id=target, mode='observer'))['stream_id']
            expected, received = 0, 0
            if partial:
                header = original.read_header()
                assert header[2] == 6 and header[5] == target_stream and header[-1] > 500000
                expected = header[-1]
                assert original.read_exact(1)
                received = 1
            else:
                assert len(original.snapshot(target_stream)) > 500000
            terminate(endpoint, target)
            if partial:
                host_log = session / ('host-' + host_id + '.log')
                # The admin reply commits termination, not the next producer turn.
                # Keep receiving paused until that turn records its actual failure;
                # draining now could complete the frame and erase the condition.
                wait_for(lambda: host_log.exists() and 'site=ended_purge_tracker err=PartialFrame' in host_log.read_text())
                try:
                    original.read_exact(expected - 1)
                    raise AssertionError('snapshot completed; partial close was not reproduced')
                except TruncatedFrame as error:
                    received += error.received
                assert 0 < received < expected
                exact = re.findall(r'^session host closed client connection: slot=0 reason=client_closing why=socket_error site=ended_purge_tracker err=PartialFrame .*$', host_log.read_text(), re.M)
                assert len(exact) == 1
                original.close()
                peers.remove(original)
                restored = Peer(endpoint)
                peers.append(restored)
                assert restored.hello['host_id'] == host_id
                reattached = restored.call('runtime.attach', dict(runtime_id=sibling, mode='controller'))
                assert reattached['granted']['input'] and not reattached['controller_busy']
                assert reattached['controller_generation'] > attached['controller_generation']
                sibling_stream = reattached['stream_id']
                restored.snapshot(sibling_stream)
            else:
                restored = original
                wait_for(lambda: next_event(restored, target_stream))
            assert identity(sibling_pid) == sibling_identity
            assert host.poll() is None
            marker = 'RESTORED_' + uuid.uuid4().hex[:12]
            restored.send(8, (marker + '\n').encode(), stream=sibling_stream)
            def marker_visible():
                header, payload = restored.receive()
                if header[2] in (6, 7) and header[5] == sibling_stream:
                    return any(marker in row for row in text_rows(payload))
                return False
            wait_for(marker_visible)
            inventory = restored.call('runtime.list', {})['runtimes']
            assert [row['runtime_id'] for row in inventory] == [sibling]
            terminate(endpoint, sibling)
            result = dict(partial=partial, expected_payload_bytes=expected,
                          received_payload_bytes=received, sibling_pid_preserved=True,
                          sibling_input_and_screen=True, target_absent=True,
                          new_controller=partial, host_id=host_id, host_pid=host.pid,
                          sibling_pid=sibling_pid, sibling_runtime_id=sibling,
                          target_runtime_id=target,
                          controller_generation_before=attached['controller_generation'],
                          controller_generation_after=(reattached if partial else attached)['controller_generation'])
        finally:
            for peer in peers:
                peer.close()
            cleanup_errors = []
            # Stop every still-present runtime before SIGTERM: the normal CLI daemon
            # uses the OS signal disposition, which is not a runtime destructor.
            if host.poll() is None and endpoint.exists():
                try:
                    inventory_peer = Peer(endpoint)
                    try:
                        remaining = inventory_peer.call('runtime.list', {})['runtimes']
                    finally:
                        inventory_peer.close()
                    assert all(row['runtime_id'] in created for row in remaining)
                    for row in remaining:
                        try:
                            terminate(endpoint, row['runtime_id'])
                        except BaseException as error:
                            cleanup_errors.append(repr(error))
                except BaseException as error:
                    cleanup_errors.append(repr(error))
            host.terminate()
            try:
                host.wait(timeout=10)
            except subprocess.TimeoutExpired:
                host.kill()
                host.wait(timeout=5)
                raise RuntimeError('owned daemon required forced cleanup')
            for path in session.glob('*.log'):
                (output / path.name).write_bytes(path.read_bytes())
    assert not cleanup_errors, cleanup_errors
    assert host.returncode in (0, -signal.SIGTERM), host.returncode
    for pid in child_pids:
        probe = subprocess.run(['ps', '-p', str(pid), '-o', 'pid='], capture_output=True, timeout=5)
        assert probe.returncode in (0, 1), probe.returncode
        assert not probe.stdout.strip(), ('owned child survived daemon teardown', pid)
    result['cleanup_verified'] = True
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result), flush=True)
    return result


def next_event(peer, stream):
    header, payload = peer.receive()
    return header[2] == 5 and header[5] == stream and json.loads(payload) == {'event': 'runtime.ended'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('the real daemon/PTY probe requires macOS')
    cli = args.cli.resolve(strict=True)
    cli_digest = hashlib.sha256(cli.read_bytes()).hexdigest()
    args.output.mkdir(parents=True)
    result = [run_case(cli, args.output / name, partial) for name, partial in [('drained', False), ('partial', True)]]
    assert hashlib.sha256(cli.read_bytes()).hexdigest() == cli_digest
    (args.output / 'result.json').write_text(json.dumps(dict(cli_sha256=cli_digest, cases=result), indent=2) + '\n')


if __name__ == '__main__':
    main()
