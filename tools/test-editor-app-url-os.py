#!/usr/bin/env python3
"""Opt-in exact-bundle cold/warm URL delivery; requires a usable macOS GUI session.

Uses private HOME/config and generated files only. A delegate injection or merely
successful `open` exit cannot satisfy this test: actual backend receipts must bind
the filename hash, byte caret, request order, and reused surface identity.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
from urllib.parse import quote


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    output = (args.output or Path(tempfile.mkdtemp(prefix='maru-editor-url-os-'))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error('a new empty output directory is required')
    source = args.app.resolve()
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(source)], check=True, capture_output=True, timeout=15)
    app = output/'Maru.app'
    shutil.copytree(source, app, symlinks=True)
    executable = app/'Contents/MacOS/maru-macos-app'
    for name in ('home', 'cache', 'state', 'backups', 'host'):
        (output/name).mkdir(mode=0o700)
    (output/'config').write_text('session.keep-alive-after-quit = false\nworkspace.restore = false\n')
    document = output/'한글 + file.txt'
    document.write_bytes('A😀B\r\n한\n'.encode())
    digest = hashlib.sha256(str(document).encode()).hexdigest()
    raw = 'maru://open?path='+quote(str(document), safe='')
    log = output/'app.stderr'
    env = dict(HOME=str(output/'home'), CFFIXED_USER_HOME=str(output/'home'),
               MARU_CONFIG=str(output/'config'), XDG_CONFIG_HOME=str(output/'home/.config'),
               XDG_CACHE_HOME=str(output/'cache'), XDG_STATE_HOME=str(output/'state'),
               MARU_SESSION_HOST_ROOT=str(output/'host'), MARU_EDITOR_BACKUP_ROOT=str(output/'backups'),
               MARU_MACOS_APP_SMOKE_MS='10000', MARU_NO_WORKSPACE_RESTORE='1',
               MARU_EDITOR_APP_URL_RECEIPTS='1')
    base = ['/usr/bin/open', '-a', str(app)]
    cold = base+['-n', '--stdout', str(output/'app.stdout'), '--stderr', str(log)]
    for key, value in env.items():
        cold += ['--env', key+'='+value]
    pattern = re.compile(r'\[EDITOR_URL\] id=(\d+) surface=(\d+) byte=(\d+) path_sha256=([0-9a-f]{64})')

    def receipts():
        return pattern.findall(log.read_text(errors='replace')) if log.exists() else []

    def send(command, label):
        result = subprocess.run(command, text=True, capture_output=True, timeout=15)
        (output/(label+'.log')).write_text(result.stdout+result.stderr)
        if result.returncode:
            raise RuntimeError(f'{label}: OS launch failed ({result.returncode}); see {label}.log')

    def wait(count):
        deadline = time.monotonic()+7
        while time.monotonic() < deadline:
            rows = receipts()
            if len(rows) >= count:
                return rows
            time.sleep(0.05)
        raise RuntimeError(f'missing actual backend receipt {count}; app auto-quits after 10 seconds')

    send(cold+[raw+'&line=2&column=2'], 'cold')
    wait(1)
    send(base+[raw+'&line=1&column=3'], 'warm')
    wait(2)
    send(base+[raw], 'file-only')
    rows = wait(3)
    # A malformed warm URL must be rejected; opening without applying its caret
    # would otherwise let a parser/dispatcher silently look successful.
    send(base+[raw+'&line=0'], 'invalid')
    time.sleep(0.3)
    rows = receipts()
    if len(rows) != 3 or [int(row[2]) for row in rows] != [11, 5, 5]:
        raise RuntimeError('unexpected receipt count or independent byte offsets')
    if len({row[1] for row in rows}) != 1 or any(row[3] != digest for row in rows):
        raise RuntimeError('wrong file/surface identity')
    if [int(row[0]) for row in rows] != [1, 2, 3] or 'editor URL rejected status=1' not in log.read_text():
        raise RuntimeError('request order or malformed negative control missing')
    (output/'result.json').write_text(json.dumps(dict(
        scope='exact-bundle OS URL delivery and backend caret; default handler and pixels are separate',
        passed=True, app_sha256=hashlib.sha256(executable.read_bytes()).hexdigest(),
        receipt_ids=[int(row[0]) for row in rows], byte_offsets=[11, 5, 5]), indent=2)+'\n')
    print(output/'result.json')


if __name__ == '__main__':
    main()
