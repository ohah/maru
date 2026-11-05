#!/usr/bin/env python3
"""Compare real bash/zsh terminal job control through fork and a fresh helper.

Twenty distinct contracts in bash and both C optimization modes; zsh is opt-in on a clean host.
This remains a syscall model, not a product PtySession or GUI validation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import tempfile
from live import Session

CASES = (
    'shell-tty', 'login-shell', 'foreground-int', 'foreground-stop',
    'fg-resume', 'bg-resume', 'background-read-ttin', 'background-write-ttou',
    'foreground-quit', 'background-exit-status', 'master-hangup', 'shell-eof',
    'foreground-winch', 'shell-winch', 'resize-sequence', 'stdin-after-resume',
    'raw-control-byte', 'foreground-exit-status', 'cwd-env-argv', 'command-not-found',
)


def exercise(s, case):
    if case in ('shell-tty', 'login-shell'):
        s.command('test -t 0 && test -t 1 && test -t 2')
        if case == 'login-shell':
            # bash and zsh both expose login status through shell options.
            s.command('shopt -q login_shell' if 'bash' in s.shell else '[[ -o login ]]')
    elif case in ('foreground-int', 'foreground-stop', 'fg-resume', 'bg-resume'):
        pid, group = s.launch_job('wait')
        if case != 'foreground-int':
            s.stop(pid)
        if case == 'foreground-stop':
            return
        if case == 'bg-resume':
            s.command('bg')
            s.wait(lambda: not s.stopped(pid), 'bg continued job')
            if os.tcgetpgrp(s.master) != s.shell_group:
                raise AssertionError('bg stole foreground')
            return
        if case == 'fg-resume':
            s.send(b'fg\n')
            s.wait(lambda: os.tcgetpgrp(s.master) == group, 'fg restored job')
            s.wait(lambda: not s.stopped(pid), 'fg continued job')
        s.send(b'\x03')
        s.foreground_shell()
        s.command('test "$?" -eq 130')
    elif case in ('background-read-ttin', 'background-write-ttou'):
        if case.endswith('ttou'):
            s.command('stty tostop')
        pid, _ = s.launch_job('read' if case.endswith('ttin') else 'wait', background=True)
        s.wait(lambda: s.stopped(pid), 'background terminal access stopped job')
        if os.tcgetpgrp(s.master) != s.shell_group:
            raise AssertionError('background terminal access stole foreground')
        output, _ = s.command('jobs -l')
        reason = b'tty input' if case.endswith('ttin') else b'tty output'
        if reason not in output.lower():
            raise AssertionError('wrong background stop reason')
        s.command('stty -tostop')
    elif case == 'foreground-quit':
        s.launch_job('wait')
        s.send(b'\x1c')
        s.foreground_shell()
        s.command('test "$?" -eq 131')
    elif case == 'background-exit-status':
        command = shlex.join([str(s.exe), '--job', 'fast42'])
        s.command(command + ' & child=$!; wait "$child"', want=42)
    elif case == 'master-hangup':
        s.command("trap 'exit 77' HUP")
        os.close(s.master)
        s.master = -1
        s.finish(expected_exit=77)
    elif case == 'shell-eof':
        s.send(b'\x04')
        s.finish()
    elif case == 'foreground-winch':
        s.launch_job('resize')
        start = len(s.data)
        s.resize(103, 41)
        s.expect(rb'[\r\n]__JOB_WINCH__\r?\n', start)
        s.send(b'\x03')
        s.foreground_shell()
    elif case == 'shell-winch':
        s.command("trap 'printf \"\\n__SHELL_WINCH__\\n\"' WINCH")
        start = len(s.data)
        s.resize(103, 41)
        s.expect(rb'[\r\n]__SHELL_WINCH__\r?\n', start)
        s.command(":")
        output, _ = s.command('stty size')
        if not re.search(rb'(?:^|[\r\n])41 103\r?\n', output):
            raise AssertionError('shell dimensions after SIGWINCH')
    elif case == 'resize-sequence':
        for cols, rows in ((120, 50), (60, 20), (91, 27)):
            s.resize(cols, rows)
            output, _ = s.command('stty size')
            if not re.search(fr'(?:^|[\r\n]){rows} {cols}\r?\n'.encode(), output):
                raise AssertionError('ordered resize dimensions')
    elif case == 'stdin-after-resume':
        pid, group = s.launch_job('read')
        s.stop(pid)
        s.send(b'fg\n')
        s.wait(lambda: os.tcgetpgrp(s.master) == group, 'reader foreground restored')
        start = len(s.data)
        s.send(b'hello\n')
        s.expect(rb'[\r\n]__READ__1\r?\n', start)
        s.foreground_shell()
    elif case == 'raw-control-byte':
        s.launch_job('raw')
        start = len(s.data)
        s.send(b'\x03')
        s.expect(rb'[\r\n]__BYTE__3\r?\n', start)
        s.foreground_shell()
        s.command('true')
    elif case == 'foreground-exit-status':
        s.launch_job('exit42')
        s.send(b'exit\n')
        s.foreground_shell()
        s.command('test "$?" -eq 42')
    elif case == 'cwd-env-argv':
        cwd = s.root / 'space directory'
        cwd.mkdir(exist_ok=True)
        literal = "quote ' dollar $ spaces"
        s.command('cd ' + shlex.quote(str(cwd)) + ' && test "$(pwd -P)" = ' + shlex.quote(str(cwd))
                  + ' && export POC_VALUE=' + shlex.quote(literal)
                  + ' && set -- ' + shlex.quote(literal)
                  + ' && test "$1" = "$POC_VALUE"')
    elif case == 'command-not-found':
        s.command('/definitely/no/maru-poc-command', want=127)
        s.command('true')
    else:
        raise AssertionError('unknown contract')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--shell', action='append', choices=('/bin/bash', '/bin/zsh'))
    parser.add_argument('--case', action='append', choices=CASES)
    parser.add_argument('--mode', action='append', choices=('fork', 'spawn-helper'))
    parser.add_argument('--optimization', action='append', choices=('O0', 'O2'))
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        parser.error('macOS required')
    shells = args.shell or ['/bin/bash']
    cases = args.case or CASES
    modes = args.mode or ('fork', 'spawn-helper')
    optimizations = args.optimization or ('O0', 'O2')
    if '/bin/zsh' in shells:
        system_init = Path('/etc/zshenv')
        if system_init.exists() and any(line.strip() and not line.lstrip().startswith('#')
                                        for line in system_init.read_text().splitlines()):
            parser.error('zsh requires a clean system zshenv; use an isolated clean host, do not modify this one')
    for selected in (shells, cases, modes, optimizations):
        if len(selected) != len(set(selected)):
            parser.error('duplicate selections would repeat evidence')
    expected = len(shells) * len(cases) * len(modes) * len(optimizations)
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error('output must be new or empty')
    out.mkdir(parents=True, exist_ok=True)
    base = Path(__file__).resolve().parent
    for name in ('probe.c', 'live.py', 'lifecycle.py'):
        shutil.copy2(base / name, out / name)
    metadata = {'platform': platform.platform(),
                'git_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
                'sources': {name: hashlib.sha256((base / name).read_bytes()).hexdigest()
                            for name in ('probe.c', 'live.py', 'lifecycle.py')},
                'compiler': subprocess.check_output(['cc', '--version'], text=True),
                'sdk': subprocess.check_output(['xcrun', '--show-sdk-version'], text=True).strip()}
    results = []
    assert len(CASES) == len(set(CASES)) == 20
    with tempfile.TemporaryDirectory(prefix='maru-pty-live-') as temp:
        root = Path(temp).resolve()
        for optimize in optimizations:
            exe = root / ('probe-' + optimize)
            subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-' + optimize,
                            str(base / 'probe.c'), '-o', str(exe)], check=True, capture_output=True)
            shutil.copy2(exe, out / exe.name)
            for mode in modes:
                for shell in shells:
                    for case in cases:
                        label = f'{optimize}-{mode}-{Path(shell).name}-{case}'
                        session = None
                        failure = None
                        try:
                            session = Session(exe, mode, root, shell, login=case == 'login-shell')
                            if session.startup_error:
                                raise AssertionError(session.startup_error)
                            session.shell = shell
                            exercise(session, case)
                        except Exception as exc:
                            failure = repr(exc)
                        finally:
                            if session:
                                session.close()
                                (out / (label + '.pty')).write_bytes(session.data)
                                (out / (label + '.control')).write_bytes(session.control)
                                (out / (label + '.stderr')).write_bytes(session.proc.stderr.read())
                                if session.cleanup_error:
                                    failure = failure or 'cleanup: ' + session.cleanup_error
                                if session.proc.returncode != 0:
                                    failure = failure or f'bridge exit {session.proc.returncode}'
                        results.append({'label': label, 'passed': failure is None, 'failure': failure})
                        if failure:
                            print(label, failure, flush=True)
    summary = {'metadata': metadata, 'expected': expected, 'shells': shells, 'cases': list(cases),
               'modes': list(modes), 'optimizations': list(optimizations), 'count': len(results),
               'passed': sum(row['passed'] for row in results), 'results': results}
    (out / 'lifecycle.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(f"{summary['passed']}/{summary['count']} real-shell comparisons passed", flush=True)
    raise SystemExit(summary['passed'] != expected)


if __name__ == '__main__':
    main()
