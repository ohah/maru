"""Bounded real-PTY shell fixture for the independent Darwin spawn model."""
import errno
import fcntl
import os
import re
import select
import shlex
import signal
import struct
import subprocess
import termios
import time


class Session:
    def __init__(self, exe, mode, root, shell, login=False, extra_env=None):
        self.exe, self.root = exe, root
        self.data = bytearray()
        self.jobs = set()
        self.sequence = 0
        self.prompt_cursor = 0
        self.finished = False
        self.pid = None
        self.shell_group = None
        self.startup_error = None
        self.cleanup_error = None
        self.control_eof = False
        self.pty_eof = False
        self.master, slave = os.openpty()
        self.resize(91, 27)
        target = [shell, '--noprofile', '--norc', '-i'] if shell.endswith('bash') else [shell, '-f', '-i']
        if login:
            import pwd
            target = ['/usr/bin/login', '-q', '-flp', pwd.getpwuid(os.getuid()).pw_name,
                      '/bin/bash', '--noprofile', '--norc', '-c', 'exec -l ' + shlex.join(target)]
        env = {'HOME': str(root), 'ZDOTDIR': str(root), 'PATH': '/usr/bin:/bin',
               'TERM': 'dumb', 'LC_ALL': 'C', 'PS1': '', 'HISTFILE': '/dev/null',
               'BASH_SILENCE_DEPRECATION_WARNING': '1'}
        # Only diagnostic callers add variables for their own actor copies.
        env.update(extra_env or {})
        self.proc = subprocess.Popen(
            [str(exe), '--bridge', mode, str(root), str(self.master), str(slave), *target],
            pass_fds=(self.master, slave), env=env, cwd=root,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        os.close(slave)
        self.control = bytearray()
        try:
            self.read_control(rb'ROOT=(\d+)\n')
            self.pid = int(re.search(rb'ROOT=(\d+)', self.control)[1])
            self.send((b"set +H; " if shell.endswith("bash") else b"unsetopt BANG_HIST; ") + b"unset HISTFILE; export PS1='__POC_PROMPT__'; stty -echo; printf '\\n__READY__\\n'\n")
            ready = self.expect(rb'[\r\n]__READY__\r?\n')
            self.prompt(ready.end())
            self.shell_group = os.tcgetpgrp(self.master)
            if os.getsid(self.pid) != self.pid or self.shell_group <= 0:
                raise AssertionError('shell session/foreground ownership')
        except Exception as exc:
            self.startup_error = repr(exc)

    def pump(self, timeout=.02):
        # macOS tty close can wait for queued output to drain. Keep reading the
        # PTY while waiting for the separate child-exit/reap control channel.
        descriptors = [] if self.control_eof else [self.proc.stdout.fileno()]
        if self.master >= 0 and not self.pty_eof:
            descriptors.append(self.master)
        ready = select.select(descriptors, [], [], timeout)[0]
        for descriptor in ready:
            try:
                chunk = os.read(descriptor, 8192)
            except OSError as exc:
                if exc.errno != errno.EIO or descriptor != self.master:
                    raise
                chunk = b''
            if descriptor == self.master:
                self.data.extend(chunk)
                if not chunk:
                    self.pty_eof = True
            elif chunk:
                self.control.extend(chunk)
            else:
                self.control_eof = True

    def read_control(self, pattern, timeout=4):
        end = time.monotonic() + timeout
        while not re.search(pattern, self.control):
            if self.control_eof:
                raise AssertionError('bridge control EOF: ' + repr(self.control))
            if time.monotonic() >= end:
                raise TimeoutError('bridge control: ' + repr(self.control))
            self.pump()

    def resize(self, cols, rows):
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))

    def send(self, data):
        # Commands are bounded and small, but preserve partial-write semantics.
        while data:
            n = os.write(self.master, data)
            data = data[n:]

    def expect(self, pattern, start=0, timeout=3):
        end = time.monotonic() + timeout
        while True:
            match = re.search(pattern, self.data[start:])
            if match:
                return match
            if self.pty_eof:
                raise AssertionError('PTY EOF before marker: ' + repr(pattern))
            if time.monotonic() >= end:
                raise TimeoutError('PTY marker: ' + repr(pattern) + '\n' + repr(self.data[-1500:]))
            self.pump()

    def prompt(self, start=None):
        start = self.prompt_cursor if start is None else start
        match = self.expect(rb'(?:^|[\r\n])__POC_PROMPT__', start)
        self.prompt_cursor = start + match.end()

    def command(self, script, want=0):
        start = len(self.data)
        self.sequence += 1
        marker = f'__SYNC_{self.sequence}__'
        self.send((script + f"; printf '\\n{marker}%d\\n' \"$?\"\n").encode())
        match = self.expect((r'[\r\n]' + marker + r'(\d+)\r?\n').encode(), start)
        actual = int(match[1])
        self.prompt(start + match.end())
        if want is not None and actual != want:
            raise AssertionError(f'command status {actual}, expected {want}: {script}')
        return bytes(self.data[start:]), actual

    def launch_job(self, kind, background=False):
        start = len(self.data)
        script = shlex.join([str(self.exe), '--job', kind])
        if background:
            self.send((script + " & printf '\\n__BG__%s\\n' \"$!\"\n").encode())
            pid = int(self.expect(rb'[\r\n]__BG__(\d+)\r?\n', start)[1])
        else:
            self.send((script + '\n').encode())
            pid = int(self.expect(rb'[\r\n]__JOB__(\d+):\d+\r?\n', start)[1])
        self.jobs.add(pid)
        if os.getsid(pid) != self.pid:
            raise AssertionError('job escaped owned test session')
        group = os.getpgid(pid)
        if not background:
            self.wait(lambda: os.tcgetpgrp(self.master) == group, 'job foreground')
        return pid, group

    @staticmethod
    def stopped(pid):
        proc = subprocess.run(['/bin/ps', '-o', 'state=', '-p', str(pid)],
                              capture_output=True, text=True, timeout=2)
        return 'T' in proc.stdout

    def wait(self, condition, label, timeout=3):
        end = time.monotonic() + timeout
        while not condition():
            if time.monotonic() >= end:
                raise TimeoutError(label)
            self.pump(.01)

    def foreground_shell(self):
        self.wait(lambda: os.tcgetpgrp(self.master) == self.shell_group, 'shell regained foreground')
        self.prompt()

    def stop(self, pid):
        self.send(b'\x1a')
        self.wait(lambda: self.stopped(pid), 'terminal SIGTSTP stopped job')
        self.foreground_shell()

    def finish(self, expected_exit=0, expected_signal=0):
        self.read_control(rb'EXIT=(-?\d+) SIGNAL=(\d+) REAPED=1\n')
        status = re.search(rb'EXIT=(-?\d+) SIGNAL=(\d+) REAPED=1', self.control)
        if (int(status[1]), int(status[2])) != (expected_exit, expected_signal):
            raise AssertionError('bridge exit: ' + repr(self.control))
        if self.proc.wait(timeout=2) != 0:
            raise AssertionError('bridge driver exit')
        self.finished = True

    def close(self):
        # Every signalled PID belongs to this fixture's still-live session. Jobs
        # have their own groups, so killing only the shell group is insufficient.
        for pid in self.jobs:
            try:
                if os.getsid(pid) == self.pid:
                    os.killpg(os.getpgid(pid), signal.SIGKILL)
                    self.wait(lambda: not self.stopped(pid), "owned job killed")
            except ProcessLookupError:
                pass
            except (OSError, TimeoutError) as exc:
                self.cleanup_error = repr(exc)
        if not self.finished and self.master >= 0 and self.pid:
            try:
                if os.tcgetpgrp(self.master) != self.shell_group:
                    self.send(b'\x03')
                    self.foreground_shell()
                targets = ' '.join(str(pid) for pid in self.jobs)
                self.send(('wait ' + targets + ' 2>/dev/null; exit 0\n').encode())
                self.finish()
            except (AssertionError, OSError, TimeoutError, subprocess.TimeoutExpired) as exc:
                self.cleanup_error = repr(exc)
        if self.master >= 0:
            os.close(self.master)
            self.master = -1
        try:
            self.proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            if self.pid:
                try:
                    if os.getsid(self.pid) == self.pid:
                        os.killpg(self.pid, signal.SIGKILL)
                        os.kill(self.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            self.proc.kill()
            self.proc.wait(timeout=2)
