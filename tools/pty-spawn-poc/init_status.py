#!/usr/bin/env python3
"""Run owned Darwin helper/channel contracts; never modify the product or user shells."""
import argparse
import errno
import fcntl
import termios
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess


def require(condition, message):
    if not condition:
        raise ValueError(message)


def tty_errno():
    fd = os.open('/dev/null', os.O_RDWR)
    try:
        try: fcntl.ioctl(fd, termios.TIOCSCTTY, 0)
        except OSError as exc: return exc.errno
        raise ValueError('non-TTY unexpectedly accepted TIOCSCTTY')
    finally: os.close(fd)


def cases():
    normal = ['baseline', 'cwd-space', 'cwd-missing-home', 'cloexec-stdio', 'poll-eintr', 'prep-valid']
    normal += [f'closed-{i}' for i in range(1, 8)]
    rows = [(n, 'target-ready', 0, 0) for n in normal]
    rows += [(n, 'helper-error', 1, errno.EPROTO) for n in
             ('request-version', 'request-magic', 'request-reserved', 'request-short', 'request-extra', 'request-eof')]
    rows += [(n, 'protocol-error', 0, 0) for n in
             ('wire-magic', 'wire-version', 'wire-stage', 'wire-reserved', 'wire-zero-errno',
              'wire-negative-errno', 'wire-short', 'wire-extra', 'wire-duplicate')]
    rows += [('wire-fragment', 'helper-error', 5, errno.ENOENT),
             ('not-a-tty', 'helper-error', 3, tty_errno()),
             ('cwd-both-missing', 'helper-error', 4, errno.ENOENT),
             ('cwd-no-home', 'helper-error', 4, errno.ENOENT),
             ('exec-missing', 'helper-error', 5, errno.ENOENT),
             ('exec-denied', 'helper-error', 5, errno.EACCES),
             ('exec-format', 'helper-error', 5, errno.ENOEXEC),
             ('spawn-missing', 'spawn-error', 0, 0),
             ('spawn-bad-fd', 'spawn-error', 0, 0),
             ('fd-exhaustion', 'setup-error', 0, errno.EMFILE),
             ('prep-deadline', 'timeout', 0, 0),
             ('request-open', 'timeout', 0, 0),
             ('wire-hold', 'timeout', 0, 0),
             ('wire-full-open', 'timeout', 0, 0),
             ('wire-trickle', 'timeout', 0, 0),
             ('early-death', 'closed-unverified', 0, 0),
             ('early-zero', 'closed-unverified', 0, 0),
             ('silent-zero', 'closed-unverified', 0, 0),
             ('signal-death', 'closed-unverified', 0, 0),
             ('channel-error', 'closed-unverified', 0, 0),
             ('silent-target', 'closed-unverified', 0, 0),
             ('hang-helper', 'timeout', 0, 0),
             ('hang-target', 'timeout', 0, 0),
             ('cancel', 'cancelled', 0, 0),
             ('read-error', 'read-error', 0, errno.EBADF),
             ('request-write-error', 'request-write-error', 0, errno.EBADF),
             ('request-broken-pipe', 'request-write-error', 0, errno.EPIPE)]
    return rows


def verify(row, expected):
    name, outcome, stage, error = expected
    require(row['case'] == name and row['outcome'] == outcome, f'{name}: wrong outcome {row}')
    require(row['stage'] == stage and row['errno'] == error, f'{name}: wrong failure attribution')
    no_child = name in ('spawn-missing', 'spawn-bad-fd', 'fd-exhaustion', 'prep-deadline')
    require(row['reaped'] is (not no_child), f'{name}: child not reaped or fictitious reap')
    require(row['group_gone'] is (not no_child), f'{name}: group remains or fictitious group')
    require(0 <= row['elapsed_ms'] < 2000, f'{name}: outer deadline exceeded')
    if outcome == 'target-ready':
        require(row['eof'] and row['target_ready'] and row['target_contract'], f'{name}: EOF alone is not readiness')
        require(row['status_bytes'] == 0 and row['exit'] == 0 and row['signal'] == 0,
                f'{name}: ready must retain clean target completion')
    else:
        require(not row['target_ready'], f'{name}: unexpected target marker')
    if outcome == 'helper-error':
        require(row['eof'] and row['status_bytes'] == 12, f'{name}: complete unique failure frame required')
    if name in ('spawn-missing', 'spawn-bad-fd'):
        require(row['spawn_error'] == (errno.ENOENT if name == 'spawn-missing' else errno.EBADF), 'spawn errno')
    if name == 'early-death':
        require(row['eof'] and row['exit'] == 23, 'early helper death must remain unverified')
    if name == 'silent-target':
        require(row['eof'] and row['exit'] == 42, 'silent exec must remain unverified')
    if name in ('early-zero', 'silent-zero'):
        require(row['eof'] and row['exit'] == 0 and not row['target_ready'], 'zero exit plus EOF is not readiness')
    if name == 'signal-death':
        require(row['signal'] == signal.SIGKILL and row['eof'], 'signal termination is not exec success')
    if name == 'poll-eintr':
        require(row['alarm_seen'] == 1 and row['poll_eintr'] > 0, 'poll never observed EINTR')
    if name == 'prep-deadline':
        require(row['elapsed_ms'] >= 500, 'deadline restarted after preparation')


def execute(exe, out, selected):
    home = out / 'home'; home.mkdir()
    work = out / 'work space'; work.mkdir()
    absent = out / 'absent'
    denied = out / 'not executable'; denied.write_text('not executable\n'); denied.chmod(0o600)
    bad_format = out / 'no format'; bad_format.write_text('not a native image or script\n'); bad_format.chmod(0o700)
    observations = []
    for spec in selected:
        name = spec[0]; cwd = work; expected_cwd = work; target = exe
        env = {'PATH': '/usr/bin:/bin', 'HOME': str(home), 'TERM': 'xterm-256color'}
        if name in ('cwd-missing-home', 'cwd-both-missing', 'cwd-no-home'):
            cwd = absent; expected_cwd = home
        if name == 'cwd-both-missing': env['HOME'] = str(absent)
        if name == 'cwd-no-home': env.pop('HOME')
        if name == 'exec-missing': target = absent
        if name == 'exec-denied': target = denied
        if name == 'exec-format': target = bad_format
        if name == 'poll-eintr': env['INIT_DELAY_TARGET'] = '1'
        env['INIT_EXPECT_CWD'] = str(expected_cwd)
        proc = subprocess.Popen([str(exe), name, str(cwd), str(target), '500'], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            stdout, stderr = proc.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            # The driver catches TERM and kills/reaps only its own SETSID child.
            proc.terminate()
            try: stdout, stderr = proc.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill(); stdout, stderr = proc.communicate()
            (out / (name + '.timeout.log')).write_text(stdout + '\n' + stderr)
            raise RuntimeError(f'{name}: driver watchdog fired; not a passing observation')
        (out / (name + '.stdout')).write_text(stdout)
        (out / (name + '.stderr')).write_text(stderr)
        require(proc.returncode == 0, f'{name}: driver failed {proc.returncode}: {stderr}')
        row = json.loads(stdout)
        observations.append(row)
        # Keep incomplete results even if the independent expected contract rejects a row.
        (out / 'progress.json').write_text(json.dumps(observations, indent=2) + '\n')
        verify(row, spec)
    return observations


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if platform.system() != 'Darwin': parser.error('Darwin only; no skipped-as-passed cohort')
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()): parser.error('Output must be new or empty')
    out.mkdir(parents=True, exist_ok=True)
    source = Path(__file__).with_suffix('.c').resolve()
    (out / source.name).write_bytes(source.read_bytes())
    (out / 'init_status.py').write_bytes(Path(__file__).read_bytes())
    results = []
    for optimize in ('O0', 'O2'):
        exe = out / ('init-' + optimize)
        command = ['cc', '-Wall', '-Wextra', '-Werror', '-' + optimize, str(source), '-o', str(exe)]
        build = subprocess.run(command, capture_output=True, text=True)
        (out / (optimize + '.build.log')).write_text(build.stdout + build.stderr)
        require(build.returncode == 0, 'compile failed')
        cohort = out / optimize; cohort.mkdir()
        results.append({'optimization': optimize, 'observations': execute(exe, cohort, cases())})
    metadata = {'git_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
                'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                'compiler': subprocess.check_output(['cc', '--version'], text=True),
                'sdk': subprocess.check_output(['xcrun', '--show-sdk-version'], text=True).strip(),
                'platform': platform.platform(), 'non_tty_native_errno': tty_errno()}
    (out / 'results.json').write_text(json.dumps({'metadata': metadata, 'cohorts': results}, indent=2) + '\n')
    print(f'{len(cases())} distinct contracts x O0/O2 passed; independent PoC, not product validation')


if __name__ == '__main__':
    main()
