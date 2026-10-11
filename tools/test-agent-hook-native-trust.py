#!/usr/bin/env python3
"""Opt-in installed Codex oracle. Isolated home; no model, login or real config."""
import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument('--codex', required=True)
parser.add_argument('--driver')
parser.add_argument('--cli')
parser.add_argument('--results', default='tests/artifacts/agent-log-record/results.json')
args = parser.parse_args()
if not args.driver or not args.cli:
    rows = json.loads(Path(args.results).read_text())
    if not args.driver:
        args.driver = next((row['argv'][0] for row in rows if 'hook-transition' in row.get('argv', [])), None)
    if not args.cli:
        args.cli = next((row['argv'][0] for row in rows if len(row.get('argv', [])) > 2 and row['argv'][1] == 'agent-hooks'), None)
    if not args.driver or not args.cli:
        parser.error('run test-agent-log-record-process to completion before using --results, or pass --driver and --cli')
version = subprocess.run([args.codex, '--version'], capture_output=True, text=True, check=True, timeout=5).stdout.strip()


def listed(codex_home, cwd):
    inbox = queue.Queue()
    env = {'PATH': os.environ.get('PATH', ''), 'HOME': str(codex_home.parent),
           'CODEX_HOME': str(codex_home), 'CFFIXED_USER_HOME': str(codex_home.parent)}
    process = subprocess.Popen([str(Path(args.codex).resolve()), 'app-server'], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=env,
                               cwd=cwd)
    def receive():
        for line in process.stdout:
            try:
                inbox.put(json.loads(line))
            except json.JSONDecodeError:
                inbox.put({'error': 'invalid app-server output'})
        inbox.put({'error': 'app-server closed'})
    reader = threading.Thread(target=receive, daemon=True)
    reader.start()
    def send(message):
        process.stdin.write(json.dumps(message) + '\n')
        process.stdin.flush()
    def reply(identifier):
        # A finite notification budget keeps noisy/broken providers from hanging this gate.
        deadline = time.monotonic() + 10
        for _ in range(128):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('provider reply deadline exceeded')
            response = inbox.get(timeout=remaining)
            if response.get('id') == identifier:
                assert 'error' not in response, response
                return response['result']
            assert 'error' not in response, response
        raise AssertionError('provider notification budget exceeded')
    try:
        send({'id': 1, 'method': 'initialize', 'params': {'clientInfo': {'name': 'maru_native_hook_test', 'version': '1'}, 'capabilities': {'experimentalApi': True}}})
        reply(1)
        send({'method': 'initialized', 'params': {}})
        send({'id': 2, 'method': 'hooks/list', 'params': {'cwds': [str(cwd)]}})
        result = reply(2)
        entries = result['data']
        assert len(entries) == 1 and not entries[0]['errors'], result
        return {hook['key']: hook for hook in entries[0]['hooks']}
    finally:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)
        reader.join(timeout=3)
        process.stdin.close()
        process.stdout.close()


with tempfile.TemporaryDirectory(prefix='maru-native-trust-') as temporary:
    root = Path(temporary).resolve()
    home, cwd = root / 'codex', root / 'project'
    home.mkdir(mode=0o700)
    cwd.mkdir(mode=0o700)
    roots = [root / name for name in ('lv1', 'rv1', 'lv2', 'rv2')]
    for directory in roots:
        directory.mkdir(mode=0o700)
    def generated(binary, before=''):
        process = subprocess.run([str(Path(args.driver).resolve()), str(home), 'hook-trust', str(binary), 'codex', *map(str, roots), before], capture_output=True, timeout=5)
        assert process.returncode == 0, process.stderr
        return json.loads(process.stdout)
    def install(fixture):
        hooks = {'hooks': {entry['event']: [{'matcher': '*', 'hooks': [{'type': 'command', 'command': fixture['command'], 'timeout': 2}]}] for entry in fixture['entries']}}
        (home / 'hooks.json').write_text(json.dumps(hooks))
    first = generated(Path(args.cli).resolve())
    install(first)
    (home / 'config.toml').write_text('[features]\nhooks = true\n')
    missing = listed(home, cwd)
    assert len(missing) == len(first['entries']), missing
    for entry in first['entries']:
        actual = missing[entry['key']]
        assert actual['currentHash'] == entry['hash'], (entry['event'], actual)
        assert actual['trustStatus'] == 'untrusted', actual
    trusted = generated(Path(args.cli).resolve(), (home / 'config.toml').read_text())
    (home / 'config.toml').write_text(trusted['config'])
    assert all(hook['trustStatus'] == 'trusted' for hook in listed(home, cwd).values())
    moved = generated(root / 'Moved Maru.app/Contents/MacOS/maru', trusted['config'])
    install(moved)
    assert all(hook['trustStatus'] == 'modified' for hook in listed(home, cwd).values())
    (home / 'config.toml').write_text(moved['config'])
    final = listed(home, cwd)
    for entry in moved['entries']:
        assert final[entry['key']]['currentHash'] == entry['hash']
        assert final[entry['key']]['trustStatus'] == 'trusted'
    repeated = generated(root / 'Moved Maru.app/Contents/MacOS/maru', moved['config'])
    assert repeated['config'] == moved['config'] and repeated['stats']['refreshed'] == 0
    corrected = moved['config']
    for entry in moved['entries']:
        corrected = corrected.replace('trusted_hash = "' + entry['hash'] + '"', 'trusted_hash = "sha256:' + '0' * 64 + '"')
    divergent = generated(root / 'Moved Maru.app/Contents/MacOS/maru', corrected)
    assert divergent['config'] == corrected and divergent['stats']['diverged'] == len(final)
    print(json.dumps({'events': len(final), 'oracle': 'installed Codex hooks/list', 'version': version,
                      'untrusted_modified_trusted': True, 'real_user_config_changed': False}))
