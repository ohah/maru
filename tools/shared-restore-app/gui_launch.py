"""Short-lived GUI-session launcher for opt-in candidate tests initiated over SSH.

The job lives only in launchd's gui domain. The signed app stays byte-identical;
HOME/config/state remain private. No TCC record or persistent LaunchAgent is edited.
"""
import ctypes
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import struct
import subprocess
import time
import uuid


def process_identity(pid):
    lib = ctypes.CDLL('/usr/lib/libproc.dylib')
    lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    info = ctypes.create_string_buffer(136)  # SDK sys/proc_info.h: proc_bsdinfo, PROC_PIDTBSDINFO=3.
    path = ctypes.create_string_buffer(4096)
    if lib.proc_pidinfo(pid, 3, 0, info, len(info)) != len(info) or lib.proc_pidpath(pid, path, len(path)) <= 0:
        return None
    uid = struct.unpack_from('I', info.raw, 20)[0]
    birth = struct.unpack_from('QQ', info.raw, 120)
    return (uid, birth, str(Path(os.fsdecode(path.value)).resolve()))


def stage_app(app):
    source = app.parents[2]
    digest = hashlib.sha256(app.read_bytes()).hexdigest()
    base = Path.home()/'.cache/maru-shared-restore-app'
    base.mkdir(parents=True, exist_ok=True, mode=0o700)
    target = base/digest/source.name
    if not target.exists():
        target.parent.mkdir(mode=0o700, exist_ok=True)
        shutil.copytree(source, target, symlinks=True)
    binary = target/'Contents/MacOS'/app.name
    if hashlib.sha256(binary.read_bytes()).hexdigest() != digest:
        raise RuntimeError('staged app differs from supplied app')
    subprocess.run(['codesign','--verify','--deep','--strict',str(target)], check=True, capture_output=True, timeout=30)
    return binary


class GUIApp:
    """Expose waiter status separately from the actual application's PID and lifetime."""
    def __init__(self, app, env, output):
        self.output = output
        self.executable = stage_app(app)
        self.label = 'dev.maru.test.candidate.'+uuid.uuid4().hex
        self.domain = f'gui/{os.getuid()}/{self.label}'
        self.returncode = None
        self._pid = None
        self._identity = None
        self._loaded = False
        command = ['/usr/bin/open','-n','-W','--stdout',str(output/'app.stdout.txt'),
                   '--stderr',str(output/'app.stderr.txt')]
        for key,value in env.items():
            if key.startswith(('MARU_','XDG_')) or key in ('HOME','CFFIXED_USER_HOME','PATH','LANG','LC_ALL','TMPDIR'):
                command += ['--env',key+'='+value]
        command += [str(self.executable.parents[2])]
        job = dict(Label=self.label, ProgramArguments=command, RunAtLoad=True, KeepAlive=False,
                   ProcessType='Interactive', WorkingDirectory=str(output),
                   StandardOutPath=str(output/'launcher.stdout.txt'), StandardErrorPath=str(output/'launcher.stderr.txt'))
        plist = output/'gui-job.plist'
        plist.write_bytes(plistlib.dumps(job))
        plist.chmod(0o600)
        subprocess.run(['launchctl','bootstrap',f'gui/{os.getuid()}',str(plist)],check=True,capture_output=True,timeout=15)
        self._loaded = True

    def _observe_pid(self):
        path = self.output/'app.stderr.txt'
        if not path.exists(): return
        with path.open('rb') as log: text = log.read(4096).decode('utf-8',errors='replace')
        match = re.search(r'^warning\(app\): maru build:.*pid=(\d+)',text,re.M)
        if not match: return
        pid = int(match.group(1))
        if self._pid is not None and pid != self._pid: raise RuntimeError('GUI app PID changed')
        self._pid = pid
        identity = process_identity(pid)
        if identity is not None:
            if identity[0] != os.getuid() or identity[2] != str(self.executable.resolve()):
                raise RuntimeError('GUI app executable/owner mismatch')
            if self._identity is not None and identity != self._identity: raise RuntimeError('GUI app PID reused')
            self._identity = identity

    @property
    def pid(self):
        self._observe_pid()
        if self._pid is None: raise RuntimeError('GUI app has no startup PID')
        return self._pid

    def poll(self):
        if self.returncode is not None: return self.returncode
        self._observe_pid()
        result = subprocess.run(['launchctl','print',self.domain],capture_output=True,text=True,timeout=5)
        if result.returncode: raise RuntimeError('owned GUI launcher missing')
        if re.search(r'\n\s+pid = \d+',result.stdout): return None
        match = re.search(r'last exit code = (-?\d+)',result.stdout)
        if match:
            if self._identity is not None and process_identity(self._pid) == self._identity: return None
            self.returncode = int(match.group(1))
            if self.returncode == 0 and self._pid is None: raise RuntimeError('launcher completed without application startup')
        return self.returncode

    def wait(self, timeout=None):
        deadline = time.monotonic()+(timeout if timeout is not None else 15)
        while self.poll() is None:
            if time.monotonic() >= deadline: raise subprocess.TimeoutExpired('GUI app waiter',timeout)
            time.sleep(.05)
        return self.returncode

    def kill(self):
        self._observe_pid()
        # No process-group inference: a LaunchServices app is not the caller's child.
        if self._identity is not None and process_identity(self._pid) == self._identity:
            os.kill(self._pid,signal.SIGKILL)
        if self._loaded:
            subprocess.run(['launchctl','kill','SIGKILL',self.domain],capture_output=True,timeout=10)

    def close(self):
        if not self._loaded: return
        result = subprocess.run(['launchctl','bootout',self.domain],capture_output=True,timeout=10)
        self._loaded = False
        remaining = subprocess.run(['launchctl','print',self.domain],capture_output=True,timeout=5)
        if remaining.returncode == 0 or result.returncode != 0: raise RuntimeError('owned GUI job cleanup failed')
