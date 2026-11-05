#!/usr/bin/env python3
"""Behavioral mutation controls for the real-shell experiment, on source copies."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

CONTROLS = (
    ('missing-session', 'probe.c', 'POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT',
     'POSIX_SPAWN_CLOEXEC_DEFAULT', 'shell-tty', False),
    ('ignored-stop', 'probe.c', '    struct termios original, raw;',
     '    signal(SIGTSTP,SIG_IGN);\n    struct termios original, raw;', 'foreground-stop', False),
    ('missing-raw', 'probe.c', 'cfmakeraw(&raw);', '(void)raw;', 'raw-control-byte', False),
    ('ignored-winch', 'probe.c', 'if (!strcmp(kind,"resize")) signal(SIGWINCH,winch);',
     'if (!strcmp(kind,"resize")) { (void)winch; signal(SIGWINCH,SIG_IGN); }', 'foreground-winch', False),
    ('missing-exit-drain', 'live.py',
     '            self.pump()\n\n    def resize',
     "            ready = select.select([self.proc.stdout], [], [], .02)[0]\n"
     "            if ready:\n"
     "                chunk = os.read(self.proc.stdout.fileno(), 4096)\n"
     "                if chunk: self.control.extend(chunk)\n"
     "                else: self.control_eof = True\n\n    def resize",
     'shell-tty', False),
    ('equivalent-pause', 'probe.c', '    for (;;) pause();',
     '    while (1) pause();', 'fg-resume', True),
)
FILES = ('probe.c', 'live.py', 'lifecycle.py')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error('output must be new or empty')
    out.mkdir(parents=True, exist_ok=True)
    base = Path(__file__).resolve().parent
    originals = {name: (base / name).read_text() for name in FILES}
    hashes = {name: hashlib.sha256((base / name).read_bytes()).hexdigest() for name in FILES}
    rows = []
    for name, file, old, new, case, positive in CONTROLS:
        if originals[file].count(old) != 1:
            raise RuntimeError('missing or ambiguous mutation: ' + name)
        with tempfile.TemporaryDirectory(prefix='maru-pty-live-control-') as temp:
            temp = Path(temp)
            for leaf in FILES:
                (temp / leaf).write_text(originals[leaf].replace(old, new) if leaf == file else originals[leaf])
            destination = out / name
            proc = subprocess.run(
                ['python3', str(temp / 'lifecycle.py'), '--output', str(destination),
                 '--case', case, '--mode', 'spawn-helper', '--optimization', 'O0'],
                capture_output=True, text=True, timeout=40)
            (out / (name + '.log')).write_text(proc.stdout + proc.stderr)
            result_file = destination / 'lifecycle.json'
            result = json.loads(result_file.read_text()) if result_file.exists() else None
            accepted = (result is not None and result['count'] == 1
                        and (result['passed'] == 1) == positive
                        and (proc.returncode == 0) == positive)
            row = {'control': name, 'expected_pass': positive, 'exit': proc.returncode,
                   'accepted': accepted, 'behavioral_result_present': result is not None}
            print(row, flush=True)
            rows.append(row)
            if not accepted:
                raise RuntimeError('no valid behavioral evidence: ' + name)
    if any(hashlib.sha256((base / leaf).read_bytes()).hexdigest() != hashes[leaf] for leaf in FILES):
        raise RuntimeError('working source changed')
    (out / 'controls.json').write_text(json.dumps({'source_hashes': hashes, 'results': rows}, indent=2) + '\n')


if __name__ == '__main__':
    main()
