#!/usr/bin/env python3
"""Actual CLI transport gate: generations, flush ordering and concurrent writers.
Only synthetic private directories and owned child processes are used.
"""
import argparse
import json
import os
from pathlib import Path
import queue
import resource
import signal
import subprocess
import tempfile
import threading
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--cli', required=True)
    ap.add_argument('--driver', required=True)
    ap.add_argument('--output-dir', required=True)
    args = ap.parse_args()
    cli, driver = str(Path(args.cli).resolve()), str(Path(args.driver).resolve())
    children = []
    results = []

    def stop(p):
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait(timeout=3)
        for pipe in (p.stdin, p.stdout, p.stderr):
            if pipe:
                pipe.close()

    with tempfile.TemporaryDirectory(prefix='maru-stream-') as root:
        root = Path(root).resolve()
        os.chmod(root, 0o700)
        env = dict(os.environ, HOME=str(root), PATH='/nonexistent', LC_ALL='C')

        def directory(tag):
            d = root / tag
            d.mkdir(mode=0o700)
            return d

        def record(d, tag):
            start = time.monotonic()
            p = subprocess.run([cli, 'agent-hooks', 'record', f'--file={d}/a.ndjson'],
                               input=f'claude\t{{"tag":"{tag}"}}\n'.encode(),
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=3)
            assert p.returncode == 0 and not p.stdout and not p.stderr, p.stderr
            return time.monotonic() - start

        def generation(d):
            return (d / 'a.ndjson').read_bytes().split(b'\n', 1)[0].split(b'\t')[1].decode()

        def hold(d):
            p = subprocess.Popen([driver, str(d), 'hold'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            children.append(p)
            # Readiness is bounded even if the driver fails before taking its lock.
            ready = queue.Queue()
            threading.Thread(target=lambda: ready.put(p.stdout.readline()), daemon=True).start()
            assert ready.get(timeout=3) == b'ready\n'
            return p

        def stream(d, resume='', read=True, file_limit=None, heartbeat_ms=0):
            cmd = [cli, 'agent-events', '--stdio', f'--dir={d}', '--log-format=v2', f'--heartbeat-ms={heartbeat_ms}']
            if resume:
                cmd.append('--resume=' + resume)
            def limited():
                signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
                resource.setrlimit(resource.RLIMIT_FSIZE, (file_limit, file_limit))
            p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, preexec_fn=limited if file_limit is not None else None)
            children.append(p)
            hello = queue.Queue()
            threading.Thread(target=lambda: hello.put(p.stdout.readline()), daemon=True).start()
            assert json.loads(hello.get(timeout=3)) == {'hello': 'maru-agent-events-v2', 'v': 2}
            q = queue.Queue()
            if read:
                drain(p, q)
            return p, q

        def drain(p, q):
            def run():
                try:
                    for line in iter(p.stdout.readline, b''):
                        q.put(json.loads(line))
                except (ValueError, OSError):
                    pass
            threading.Thread(target=run, daemon=True).start()

        def until(q, predicate, seconds=8):
            end = time.monotonic() + seconds
            seen = []
            while time.monotonic() < end:
                item = q.get(timeout=max(.01, end - time.monotonic()))
                seen.append(item)
                if predicate(item):
                    return seen
            raise AssertionError('transport deadline')

        def tagged(item, tag):
            return item.get('line') == f'claude\t{{"tag":"{tag}"}}'

        try:
            d = directory('resume')
            record(d, 'first')
            gen = generation(d)
            end = (d / 'a.ndjson').stat().st_size - len(f'MARU_AGENT_LOG_V2\t{gen}\n')
            record(d, 'second')
            p, q = stream(d, f'a:{end}:{gen}')
            seen = until(q, lambda x: x.get('cur') == 'a')
            assert not any(tagged(x, 'first') for x in seen) and any(tagged(x, 'second') for x in seen)
            stop(p)
            # Same-size replacement must not inherit the old EOF, even on reconnect.
            previous_size = (d / 'a.ndjson').stat().st_size
            old_eof = previous_size - len(f'MARU_AGENT_LOG_V2\t{gen}\n')
            (d / 'a.ndjson').unlink()
            record(d, 'third')
            record(d, 'otherx')
            assert (d / 'a.ndjson').stat().st_size == previous_size
            new = generation(d)
            assert new != gen
            p, q = stream(d, f'a:{old_eof}:{gen}')
            seen = until(q, lambda x: x.get('cur') == 'a')
            assert any(tagged(x, 'third') for x in seen) and seen[-1]['gen'] == new
            stop(p)
            results.append('generation-aware resume and same-size replacement')

            d = directory('startup')
            record(d, 'drop')
            old = generation(d)
            path = d / 'a.ndjson'
            header = path.read_bytes().split(b'\n', 1)[0] + b'\n'
            payload = b'claude\t{"tag":"bulk","padding":"' + b'x' * 16000 + b'"}\n'
            path.write_bytes(header + payload * 70)
            p, q = stream(d)
            seen = until(q, lambda x: x.get('cur') == 'a')
            assert seen[-1]['at'] == 0 and seen[-1]['gen'] != old and not any('line' in x for x in seen)
            assert path.read_bytes() == f'MARU_AGENT_LOG_V2\t{seen[-1]["gen"]}\n'.encode()
            stop(p)
            record(d, 'expire')
            os.utime(path, (1, 1))
            p, q = stream(d)
            deadline = time.monotonic() + 3
            while path.exists() and time.monotonic() < deadline:
                time.sleep(.01)
            assert not path.exists()
            assert len(list(d.glob('.maru-agent-log-lock-v1-*'))) == 1
            stop(p)
            results.append('startup generation rotation, expiry and permanent lock retention')

            d = directory('quota')
            record(d, 'seed')
            path = d / 'a.ndjson'
            header = path.read_bytes().split(b'\n', 1)[0] + b'\n'
            before = header + payload * 70
            path.write_bytes(before)
            p, q = stream(d, file_limit=10)
            until(q, lambda x: x.get('cur') == 'a')
            stop(p)
            assert path.read_bytes() == before and not list(d.glob('*.tmp'))
            results.append('kernel file-size failure during startup publication preserves backlog')


            def backlog(tag):
                d = directory(tag)
                record(d, 'seed')
                path = d / 'a.ndjson'
                header = path.read_bytes().split(b'\n', 1)[0] + b'\n'
                path.write_bytes(header + payload * 70)
                holder = hold(d)
                p, q = stream(d, read=False, heartbeat_ms=200)
                # A heartbeat is the product barrier after startup cleanup and a
                # loop iteration. Killing at hello alone races cleanup's lease.
                barrier = queue.Queue()
                threading.Thread(target=lambda: barrier.put(p.stdout.readline()), daemon=True).start()
                assert 'hb' in json.loads(barrier.get(timeout=3))
                holder.kill()
                holder.wait(timeout=3)
                time.sleep(.4)
                assert p.poll() is None
                return d, p, q

            d, p, q = backlog('backpressure')
            old = generation(d)
            elapsed = record(d, 'while-blocked')
            assert elapsed < 1.5
            drain(p, q)
            seen = until(q, lambda x: x.get('cur') == 'a' and x.get('at') == 0 and x.get('gen') != old)
            assert sum('line' in x for x in seen) == 71
            assert sum(tagged(x, 'while-blocked') for x in seen) == 1
            assert (d / 'a.ndjson').stat().st_size == len(f'MARU_AGENT_LOG_V2\t{generation(d)}\n')
            stop(p)
            results.append({'backpressure_append_seconds': elapsed, 'events_before_rotation': 71})

            d, p, q = backlog('broken-pipe')
            before = (d / 'a.ndjson').read_bytes()
            p.stdout.close()
            assert p.wait(timeout=3) != 0
            assert (d / 'a.ndjson').read_bytes() == before
            results.append('broken pipe preserves unflushed disk copy')

            d = directory('unsafe')
            record(d, 'intact')
            path = d / 'a.ndjson'
            before = path.read_bytes()
            for spec in ('a:0,a:1', 'a:0:BAD', 'a:+1'):
                r = subprocess.run([cli, 'agent-events', '--stdio', f'--dir={d}', '--log-format=v2', '--resume=' + spec], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=3)
                assert r.returncode != 0 and not r.stdout and path.read_bytes() == before
            alias = root / 'alias'
            alias.symlink_to(d, target_is_directory=True)
            r = subprocess.run([cli, 'agent-events', '--stdio', f'--dir={alias}', '--log-format=v2'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=3)
            assert r.returncode != 0 and not r.stdout and path.read_bytes() == before
            results.append('invalid resume and unsafe directory leave logs intact')
            # A FIFO sidecar is rejected before any read; regular events still flow.
            os.mkfifo(d / 'a.tmux', 0o600)
            os.mkfifo(d / 'b.ndjson', 0o600)
            (d / 'c.ndjson').symlink_to(path)
            legacy = d / 'e.ndjson'
            legacy.write_bytes(payload * 70)
            os.chmod(legacy, 0o600)
            os.utime(legacy, (1, 1))
            corrupt = d / 'f.ndjson'
            corrupt.write_bytes(b'MARU_AGENT_LOG_V2\tpartial')
            os.chmod(corrupt, 0o600)
            p, q = stream(d)
            seen = until(q, lambda x: x.get('cur') == 'a')
            assert any(tagged(x, 'intact') for x in seen)
            assert legacy.read_bytes() == payload * 70 and corrupt.read_bytes() == b'MARU_AGENT_LOG_V2\tpartial'
            stop(p)
            results.append('FIFO log/sidecar and linked log cannot block generation stream')

            # Retain authenticated directory authority across pathname replacement.
            d = directory('authority')
            record(d, 'initial')
            p, q = stream(d)
            until(q, lambda x: x.get('cur') == 'a')
            held = root / 'held'
            d.rename(held)
            d.mkdir(mode=0o700)
            record(d, 'substituted')
            record(held, 'held')
            seen = until(q, lambda x: tagged(x, 'held'))
            assert not any(tagged(x, 'substituted') for x in seen)
            stop(p)
            results.append('held authenticated directory survives pathname replacement')

        finally:
            for p in children:
                stop(p)
    out = Path(args.output_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / 'summary.json').write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps({'passed': results}))


if __name__ == '__main__':
    main()
