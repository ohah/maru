#!/usr/bin/env python3
"""Run independent, bounded Darwin syscall comparisons, retaining every observation.

A green experiment means predicted differences were observed, not that every
candidate meets the product contract. No app binary, dotfile or PTY is modified.
"""
import argparse
import json
import hashlib
import shutil
import os
from pathlib import Path
import platform
import pwd
import re
import shlex
import subprocess
import tempfile

MODES = ('fork', 'spawn-dup', 'spawn-open', 'spawn-helper')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        parser.error('This is a macOS-only experiment; no skipped-as-passed result.')
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error('Output must be new or empty; preserve previous cohorts.')
    out.mkdir(parents=True, exist_ok=True)
    source = Path(__file__).with_name('probe.c').resolve()
    shutil.copy2(source, out / 'probe.source.c')
    metadata = {'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                'compiler': subprocess.check_output(['cc', '--version'], text=True),
                'sdk': subprocess.check_output(['xcrun', '--show-sdk-version'], text=True).strip(),
                'git_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()}
    results = []
    with tempfile.TemporaryDirectory(prefix='maru-pty-poc-') as temp:
        root = Path(temp).resolve()
        home = root / 'home'; home.mkdir()
        work = root / 'work space'; work.mkdir()
        absent = root / 'missing'
        # An explicit environment removes user dotfiles and untracked test options.
        env = {'PATH': '/usr/bin:/bin', 'HOME': str(home), 'TERM': 'xterm-256color',
               'PTY_POC_VALUE': 'value with spaces'}
        cases = [('baseline', {}, '-', None)]
        cases += [(f'closed-{mask}', {'PTY_POC_CLOSED': str(mask)}, '-', None)
                  for mask in range(1, 8)]
        cases += [(f'cloexec-{fd}', {'PTY_POC_CLOEXEC': str(1 << fd)}, '-', None)
                  for fd in range(3)]
        cases += [
            ('input', {'PTY_POC_INPUT': '1'}, '-', None),
            ('argv-env', {'PTY_POC_VALUE': "value ' quote $ literal"}, '-', None),
            ('cwd-space', {}, str(work), None),
            ('cwd-missing-home', {}, str(absent), None),
            ('cwd-missing-no-home', {'HOME': None}, str(absent), None),
            ('cwd-missing-bad-home', {'HOME': str(absent)}, str(absent), None),
            ('exit-42', {'PTY_POC_EXIT': '42'}, '-', None),
            ('missing-executable', {}, '-', 'missing'),
            ('login-wrapper', {}, str(work), 'login'),
            ('terminal-interrupt', {'PTY_POC_SIGNAL': '1'}, '-', None),
        ]
        assert len(cases) == 21
        for optimize in ('O0', 'O2'):
            exe = root / f'probe-{optimize}'
            command = ['cc', '-Wall', '-Wextra', '-Werror', '-' + optimize,
                       str(source), '-o', str(exe)]
            subprocess.run(command, check=True, capture_output=True)
            shutil.copy2(exe, out / exe.name)
            for mode in MODES:
                for name, overrides, cwd, special in cases:
                    child_env = dict(env)
                    for key, value in overrides.items():
                        if value is None: child_env.pop(key, None)
                        else: child_env[key] = value
                    expected_arg = "space ' quote $ literal" if name == "argv-env" else "plain"
                    target = [str(exe), "--probe", expected_arg]
                    if special == 'missing': target[0] = str(absent)
                    if special == 'login':
                        target = ['/usr/bin/login', '-q', '-flp', pwd.getpwuid(os.getuid()).pw_name,
                                  '/bin/bash', '--noprofile', '--norc', '-c',
                                  'exec -l ' + shlex.join(target)]
                    command = [str(exe), mode, cwd, *target]
                    proc = subprocess.run(command, cwd=root, env=child_env,
                                          capture_output=True, text=True, timeout=12)
                    raw = proc.stdout + '\nDRIVER_STDERR:\n' + proc.stderr
                    (out / f'{optimize}-{mode}-{name}.log').write_text(raw)
                    values = dict(re.findall(r'(\w+)=([^\s]+)', proc.stdout))
                    expected = []
                    def expect(ok, label):
                        if not ok: expected.append(label)
                    expect(proc.returncode == 0, 'driver exit')
                    direct = mode in ('spawn-dup', 'spawn-open')
                    cwd_reject = direct and name.startswith('cwd-missing-')
                    missing = special == 'missing'
                    if cwd_reject or (direct and missing):
                        expect(values.get('spawn_error') == '2', 'native ENOENT')
                    elif missing:
                        expect(values.get('exit') == '127', 'exec failure exit 127')
                    else:
                        expect(values.get('stdio') == '111', 'all stdio tty')
                        expect(values.get('cols') == '91' and values.get('rows') == '27', 'winsize')
                        expect(values.get('sid') == values.get('pgid'), 'session group')
                        # login may keep a supervising leader, so compare group/session,
                        # not the final executable PID, for that one explicit cohort.
                        expect(values.get('tty') == ('0' if direct else '1'), 'controlling tty')
                        expect((values.get('fg') == '-1') if direct else
                               values.get('fg') == values.get('pgid'), 'foreground group')
                        expect(values.get('reaped') == '1', 'child fully reaped')
                        if special != 'login':
                            expect(values.get('sid') == values.get('pid'), 'session leader')
                        expect('arg=' + expected_arg + '\n' in proc.stdout, 'literal argv')
                        expect('env=' + child_env['PTY_POC_VALUE'] + '\n' in proc.stdout, 'environment')
                        expect('stderr=ok' in proc.stdout, 'stderr mapping')
                        expect(values.get('ambient') == ('1' if mode == 'fork' and special != 'login' else '0'), 'ambient FD')
                        expected_cwd = work if name in ('cwd-space', 'login-wrapper') else (
                            home if name == 'cwd-missing-home' else root)
                        expect('cwd=' + str(expected_cwd) + '\n' in proc.stdout, 'cwd')
                        if special == 'login':
                            expect(values.get('login') == '1', 'login argv0')
                            expect(values.get('login_name') == pwd.getpwuid(os.getuid()).pw_name, 'login identity')
                        if name == 'input': expect('input=hello' in proc.stdout, 'terminal input')
                        if name == 'terminal-interrupt':
                            expect(values.get('signal') == ('9' if direct else '2'), 'terminal Ctrl+C')
                        else:
                            expect(values.get('exit') == ('42' if name == 'exit-42' else '0'), 'target exit')
                    results.append({'optimize': optimize, 'mode': mode, 'case': name,
                                    'predicted_difference_observed': not expected,
                                    'mismatches': expected, 'values': values})
    summary = {'metadata': metadata, 'platform': platform.platform(), 'source': str(source),
               'count': len(results), 'matches': sum(not r['mismatches'] for r in results),
               'results': results}
    (out / 'results.json').write_text(json.dumps(summary, indent=2) + '\n')
    failures = [r for r in results if r['mismatches']]
    for row in failures: print(row['optimize'], row['mode'], row['case'], row['mismatches'])
    print(f"{summary['matches']}/{len(results)} predicted comparisons observed; see {out}")
    raise SystemExit(bool(failures))


if __name__ == '__main__':
    main()
