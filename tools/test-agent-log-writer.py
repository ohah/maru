#!/usr/bin/env python3
"""Real native writer processes in a private directory; no provider or SSH calls."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import hashlib
import os
from pathlib import Path
import selectors
import statistics
import subprocess
import tempfile
import time
import threading
import shutil

parser = argparse.ArgumentParser()
parser.add_argument('--driver', required=True)
parser.add_argument('--output-dir')
options = parser.parse_args()
driver = str(Path(options.driver).resolve())
root = Path(tempfile.mkdtemp(prefix='maru-log-writer-'))
root.chmod(0o700)
home = root / 'home'
home.mkdir(mode=0o700)
env = {key: value for key, value in os.environ.items()
       if not key.startswith(('MARU_', 'XDG_', 'DYLD_'))}
env.update(HOME=str(home), CFFIXED_USER_HOME=str(home), XDG_CACHE_HOME=str(root / 'cache'))
lock_leaf = f'.maru-agent-log-lock-v1-{hashlib.sha256(b"a").digest()[0] & 63:02x}'
records = []
record_lock = threading.Lock()
output_dir = Path(options.output_dir).resolve() if options.output_dir else None
if output_dir:
    output_dir.mkdir(parents=True, exist_ok=True)


def save_records():
    (root / 'results.json').write_text(json.dumps(records, indent=2))
    if output_dir:
        shutil.copy2(root / 'results.json', output_dir / 'results.json')



def run(directory, *args, success=True):
    start = time.monotonic()
    try:
        process = subprocess.run([driver, str(directory), *args], capture_output=True, timeout=5, env=env)
    except subprocess.TimeoutExpired as error:
        with record_lock:
            records.append(dict(directory=str(directory), args=args, exit=None, failure='timeout',
                                stdout=(error.stdout or b'').decode(errors='replace'),
                                stderr=(error.stderr or b'').decode(errors='replace')))
            save_records()
        raise
    elapsed = time.monotonic() - start
    entry = dict(directory=str(directory), args=args, exit=process.returncode,
                 stdout=process.stdout.decode(errors='replace'),
                 stderr=process.stderr.decode(errors='replace'), seconds=elapsed)
    with record_lock:
        records.append(entry)
        save_records()
    assert (process.returncode == 0) == success, entry
    return json.loads(process.stdout) if success else process


def directory(name):
    path = root / name
    path.mkdir(mode=0o700)
    return path


def log(path):
    header, payload = (path / 'a.ndjson').read_bytes().split(b'\n', 1)
    assert header.startswith(b'MARU_AGENT_LOG_V2\t') and len(header.split(b'\t')[1]) == 32
    tags = [json.loads(line.split(b'\t', 1)[1])['tag'] for line in payload.splitlines()]
    return header.split(b'\t')[1].decode(), tags


shared = directory('shared')
with ThreadPoolExecutor(max_workers=8) as pool:
    results = list(pool.map(lambda index: run(shared, 'append', f'p{index}', '25'), range(8)))
generation, tags = log(shared)
assert len(tags) == 200 and set(tags) == {f'p{i}{j}' for i in range(8) for j in range(25)}
assert {entry['gen'] for entry in results} == {generation}
latest = max(results, key=lambda result: result['at'])
assert run(shared, 'rotate', generation, str(latest['at']), str(latest['at']))['gen'] != generation
assert log(shared)[1] == []
new = run(shared, 'append', 'n', '1')
assert run(shared, 'rotate', generation, str(latest['at']), str(latest['at'])) is None
assert log(shared)[1] == ['n0']
# An append after the consumed snapshot prevents truncating the unconsumed tail.
run(shared, 'append', 'later', '1')
assert run(shared, 'rotate', new['gen'], str(new['at']), str(new['at'])) is None
assert log(shared)[1] == ['n0', 'later0']

held = directory('held')
holder = subprocess.Popen([driver, str(held), 'hold'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
selector = selectors.DefaultSelector()
try:
    selector.register(holder.stdout, selectors.EVENT_READ)
    assert selector.select(5), 'holder never acquired lock'
    assert holder.stdout.readline() == b'ready\n'
    process = run(held, 'append', 'blocked', success=False)
    assert 'WouldBlock' in process.stderr.decode()
finally:
    selector.close()
    if holder.poll() is None:
        holder.kill()
    holder_output, holder_errors = holder.communicate(timeout=3)
    records.append(dict(args=['holder-kill'], exit=holder.returncode, fixture_terminated=True,
                        stdout=holder_output.decode(errors='replace'), stderr=holder_errors.decode(errors='replace')))
    save_records()
run(held, 'append', 'released')
assert log(held)[1] == ['released0']

# POSIX-only security and kernel file-size failure; Windows gets separate native gates.
if os.name == 'posix':
    import resource
    import signal
    sentinel = root / 'sentinel'
    sentinel.write_bytes(b'keep')
    for name, leaf in [('log-link', 'a.ndjson'), ('lock-link', lock_leaf)]:
        path = directory(name)
        (path / leaf).symlink_to(sentinel)
        run(path, 'append', 'blocked', success=False)
        assert sentinel.read_bytes() == b'keep'
    for name, leaf in [('log-fifo', 'a.ndjson'), ('lock-fifo', lock_leaf)]:
        path = directory(name)
        os.mkfifo(path / leaf, 0o600)
        run(path, 'append', 'blocked', success=False)
    linked = directory('hard-link')
    os.link(sentinel, linked / lock_leaf)
    assert 'UnsafeFile' in run(linked, 'append', 'blocked', success=False).stderr.decode()
    for name, leaf in [('log-mode', 'a.ndjson'), ('lock-mode', lock_leaf)]:
        path = directory(name)
        run(path, 'append', 'private')
        before_mode_change = (path / 'a.ndjson').read_bytes()
        (path / leaf).chmod(0o644)
        assert 'UnsafeFile' in run(path, 'append', 'blocked', success=False).stderr.decode()
        assert (path / 'a.ndjson').read_bytes() == before_mode_change
    limited = directory('size-limit')
    run(limited, 'append', 'first')
    before = (limited / 'a.ndjson').read_bytes()

    def limit_size():
        signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
        resource.setrlimit(resource.RLIMIT_FSIZE, (len(before) + 1, len(before) + 1))

    process = subprocess.run([driver, str(limited), 'append', 'second'],
                             preexec_fn=limit_size, capture_output=True, timeout=5, env=env)
    records.append(dict(args=['kernel-file-size-limit'], exit=process.returncode,
                        stderr=process.stderr.decode(errors='replace')))
    save_records()
    assert process.returncode != 0 and (limited / 'a.ndjson').read_bytes() == before

benchmark = directory('benchmark')
native = []
plain = []
for index in range(12):
    before = time.monotonic()
    run(benchmark, 'append', f'b{index}')
    native.append(records[-1]['seconds'])
    if os.name == 'posix':
        before = time.monotonic()
        subprocess.run(['/bin/sh', '-c', 'umask 077; printf "claude\\t{}\\n" >> "$1"',
                        'fixture', str(benchmark / 'plain.ndjson')], check=True, timeout=5, env=env)
        plain.append(time.monotonic() - before)
summary = dict(native_median_ms=1000 * statistics.median(native),
               native_max_ms=1000 * max(native),
               plain_median_ms=1000 * statistics.median(plain) if plain else None,
               platform=os.name, record_count=len(records))
(root / 'results.json').write_text(json.dumps(records, indent=2))
(root / 'summary.json').write_text(json.dumps(summary, indent=2))
if output_dir:
    shutil.copy2(root / 'summary.json', output_dir / 'summary.json')
    save_records()
assert max(native) < 2, summary
print(json.dumps(dict(evidence=str(root), **summary)))
