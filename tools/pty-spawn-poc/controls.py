#!/usr/bin/env python3
"""Reproduce four behavioral rejection controls and an equivalent positive control.

Mutations run only on temporary source copies. Compile/driver failures without a
complete results.json are rejected as evidence. The working source is preserved.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

CONTROLS = (
    ('missing-helper-ctty', 'if (ioctl(0, TIOCSCTTY, 0)) return 126;',
     'if (0) return 126;', False),
    ('missing-cloexec-default', 'POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT',
     'POSIX_SPAWN_SETSID', False),
    ('missing-home-fallback', 'if (home) (void)chdir(home);',
     'if (home) (void)home;', False),
    ('missing-fd-promotion', 'master = promote(master); slave = promote(slave);',
     'if (0) { master = promote(master); slave = promote(slave); }', False),
    ('equivalent-min-fd-four', 'F_DUPFD_CLOEXEC, 3', 'F_DUPFD_CLOEXEC, 4', True),
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error('Output must be new or empty; preserve previous cohorts.')
    out.mkdir(parents=True, exist_ok=True)
    base = Path(__file__).resolve().parent
    source = (base / 'probe.c').read_text()
    digest = hashlib.sha256(source.encode()).hexdigest()
    rows = []
    for name, old, new, should_pass in CONTROLS:
        if source.count(old) != 1:
            raise RuntimeError(f'Control site is missing or ambiguous: {name}')
        with tempfile.TemporaryDirectory(prefix='maru-poc-control-') as temp:
            temp = Path(temp)
            shutil.copy2(base / 'run.py', temp / 'run.py')
            (temp / 'probe.c').write_text(source.replace(old, new))
            destination = out / name
            proc = subprocess.run(
                ['python3', str(temp / 'run.py'), '--output', str(destination)],
                capture_output=True, text=True, timeout=110)
            (out / (name + '.log')).write_text(proc.stdout + proc.stderr)
            result_file = destination / 'results.json'
            result = json.loads(result_file.read_text()) if result_file.exists() else None
            accepted = (result is not None and result['count'] == 168
                        and (proc.returncode == 0) == should_pass
                        and (result['matches'] == 168) == should_pass)
            row = {'control': name, 'exit': proc.returncode,
                   'expected_pass': should_pass, 'accepted': accepted,
                   'matches': result['matches'] if result else None}
            rows.append(row)
            print(row, flush=True)
            if not accepted:
                raise RuntimeError(f'Control did not establish behavioral evidence: {name}')
    if hashlib.sha256((base / 'probe.c').read_bytes()).hexdigest() != digest:
        raise RuntimeError('Working source changed during controls')
    (out / 'controls.json').write_text(json.dumps(rows, indent=2) + '\n')


if __name__ == '__main__':
    main()
