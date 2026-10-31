"""Exercise actual Windows OSC 52 reads through a private, copied Maru app.

Default cases only read the existing clipboard. --large requires an empty
clipboard, installs generated text, and restores empty only while the exact
fixture and its last observed sequence remain unchanged. All app processes,
profiles, logs and child receipts belong to a new directory under .zig-cache.
Large cases resize only the owned app window to produce independent in-band
resize reports during a multi-tick reply. No foreground input, existing app
shutdown, or clipboard payload logging occurs.
"""
import argparse
import base64
import ctypes as c
from ctypes import wintypes as w
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--exe', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--large', action='store_true')
p.add_argument('--case', choices=['deny-c', 'allow-c', 'allow-empty', 'allow-p', 'allow-s0'])
args = p.parse_args()
if not __debug__ or os.name != 'nt':
    p.error('Windows and enabled Python assertions are required')
repo = Path(__file__).resolve().parents[2]
cache = (repo / '.zig-cache').resolve()
exe = args.exe.resolve()
root = args.output.resolve()
if not exe.is_file() or not exe.is_relative_to(cache) or not root.is_relative_to(cache) or root == cache:
    p.error('Use a private executable and a new output directory under this repository .zig-cache')
root.mkdir(parents=True, exist_ok=False)
u = c.WinDLL('user32', use_last_error=True)
k = c.WinDLL('kernel32', use_last_error=True)
u.OpenClipboard.argtypes = [w.HWND]
u.GetClipboardData.argtypes = [w.UINT]
u.GetClipboardData.restype = w.HANDLE
u.SetClipboardData.argtypes = [w.UINT, w.HANDLE]
u.SetClipboardData.restype = w.HANDLE
u.GetClipboardSequenceNumber.restype = w.DWORD
u.GetClipboardOwner.restype = w.HWND
u.GetWindowThreadProcessId.argtypes = [w.HWND, c.POINTER(w.DWORD)]
u.GetClassNameW.argtypes = [w.HWND, w.LPWSTR, c.c_int]
u.ShowWindow.argtypes = [w.HWND, c.c_int]
u.PostMessageW.argtypes = [w.HWND, w.UINT, c.c_size_t, c.c_ssize_t]
u.SetWindowPos.argtypes = [w.HWND, w.HWND, c.c_int, c.c_int, c.c_int, c.c_int, w.UINT]
u.CreateWindowExW.argtypes = [w.DWORD, w.LPCWSTR, w.LPCWSTR, w.DWORD, c.c_int, c.c_int, c.c_int, c.c_int, w.HWND, w.HMENU, w.HINSTANCE, c.c_void_p]
u.CreateWindowExW.restype = w.HWND
u.DestroyWindow.argtypes = [w.HWND]
k.GlobalAlloc.argtypes = [w.UINT, c.c_size_t]
k.GlobalAlloc.restype = w.HANDLE
k.GlobalFree.argtypes = [w.HANDLE]
k.GlobalLock.argtypes = [w.HANDLE]
k.GlobalLock.restype = c.c_void_p
k.GlobalUnlock.argtypes = [w.HANDLE]
k.GlobalSize.argtypes = [w.HANDLE]
k.GlobalSize.restype = c.c_size_t
CALLBACK = c.WINFUNCTYPE(w.BOOL, w.HWND, c.c_ssize_t)
u.EnumWindows.argtypes = [CALLBACK, c.c_ssize_t]


def locked_text():
    if not u.IsClipboardFormatAvailable(13):
        return b''
    handle = u.GetClipboardData(13)
    pointer = k.GlobalLock(handle)
    if not pointer:
        raise RuntimeError('Could not lock clipboard text')
    try:
        size = k.GlobalSize(handle)
        if not 0 < size <= 64 * 1024 * 1024:
            raise RuntimeError('Clipboard storage exceeds fixture read bounds')
        raw = c.string_at(pointer, size)
        end = next((i for i in range(0, len(raw) - 1, 2) if raw[i:i + 2] == b'\0\0'), None)
        if end is None:
            raise RuntimeError('Unterminated clipboard storage')
        return raw[:end].decode('utf-16-le').encode('utf-8')
    finally:
        k.GlobalUnlock(handle)


class Clipboard:
    def __init__(self):
        self.hwnd = None
        self.owned = False
        self.sequence = None
        self.payload = None
        self.restoration = 'unchanged; read-only fixture'

    def install(self):
        self.hwnd = u.CreateWindowExW(0, 'STATIC', 'Maru OSC52 owned fixture', 0, 0, 0, 0, 0, None, None, None, None)
        if not self.hwnd or not u.OpenClipboard(self.hwnd):
            raise RuntimeError('Could not open owned clipboard fixture')
        try:
            if u.CountClipboardFormats() != 0:
                raise RuntimeError('Large test requires an empty clipboard; existing content preserved')
            text = 'A\r\n한글\nq\u0307\rZ' * 350000
            self.payload = text.encode('utf-8')
            raw = (text + '\0').encode('utf-16-le')
            handle = k.GlobalAlloc(2, len(raw))
            if not handle:
                raise RuntimeError('Could not allocate clipboard fixture')
            transferred = False
            try:
                pointer = k.GlobalLock(handle)
                if not pointer:
                    raise RuntimeError('Could not lock clipboard fixture')
                c.memmove(pointer, raw, len(raw))
                k.GlobalUnlock(handle)
                if not u.EmptyClipboard():
                    raise RuntimeError('Could not initialize empty clipboard fixture')
                self.owned = True
                if not u.SetClipboardData(13, handle):
                    raise RuntimeError('Could not transfer clipboard fixture')
                transferred = True
                self.sequence = u.GetClipboardSequenceNumber()
            finally:
                if not transferred:
                    k.GlobalFree(handle)
        finally:
            u.CloseClipboard()

    def snapshot(self):
        if not u.OpenClipboard(None):
            raise RuntimeError('Clipboard unavailable')
        try:
            payload = locked_text()
            if self.owned and payload != self.payload:
                raise RuntimeError('External clipboard change preserved')
            # Windows may materialize text formats on first read. Only adopt
            # this sequence after checking the complete generated fixture.
            self.sequence = u.GetClipboardSequenceNumber()
            return payload, self.sequence
        finally:
            u.CloseClipboard()

    def restore(self):
        try:
            if not self.owned:
                return
            if not u.OpenClipboard(self.hwnd):
                raise RuntimeError('Could not verify fixture cleanup')
            try:
                observed = u.GetClipboardSequenceNumber()
                payload = locked_text()
                formats, current = [], 0
                while True:
                    current = u.EnumClipboardFormats(current)
                    if not current:
                        break
                    formats.append(current)
                if observed != self.sequence or payload != self.payload or not set(formats) <= {1, 7, 13, 16}:
                    self.restoration = 'external clipboard change preserved'
                    raise RuntimeError(self.restoration)
                if not u.EmptyClipboard() or u.CountClipboardFormats() != 0:
                    raise RuntimeError('Could not restore original empty clipboard')
                self.restoration = 'original empty clipboard restored; exact fixture and sequence verified'
            finally:
                u.CloseClipboard()
        finally:
            if self.hwnd:
                u.DestroyWindow(self.hwnd)


def windows(pid):
    found = []

    @CALLBACK
    def visit(hwnd, _):
        owner = w.DWORD()
        u.GetWindowThreadProcessId(hwnd, c.byref(owner))
        if owner.value == pid:
            name = c.create_unicode_buffer(128)
            u.GetClassNameW(hwnd, name, len(name))
            if name.value == 'MaruWindowClass':
                found.append(hwnd)
        return True

    u.EnumWindows(visit, 0)
    return found


def run_case(policy, target, clipboard):
    work = root / (policy + '-' + (target or 'empty'))
    work.mkdir()
    local, profile = work / 'local', work / 'profile'
    local.mkdir()
    profile.mkdir()
    payload, before = clipboard.snapshot()
    if len(payload) > 16_000_000:
        raise RuntimeError('Clipboard text exceeds OSC52 fixture payload bounds')
    expected = b'\x1b]52;' + (target or 'c').encode() + b';' + base64.b64encode(payload) + b'\x1b\\'
    del payload
    interleave = args.large and policy == 'allow'
    shutil.copyfile(Path(__file__).with_name('osc52_read_child.py'), work / 'maru_osc52_child.py')
    (work / 'case.json').write_text(json.dumps({'target': target, 'interleave': interleave, 'expected_length': len(expected), 'timeout': 8 if policy == 'allow' else 4}))
    config = work / 'config'
    # -m resolves the copied child from cwd without relying on quoted args;
    # the current config contract splits shell.args on whitespace only.
    config.write_text('ui.language = en\nosc52.read = ' + policy + '\nshell.command = ' + Path(sys.executable).as_posix() + '\nshell.args = -u -m maru_osc52_child\n', encoding='utf-8')
    env = os.environ.copy()
    env.update(HOME=str(profile), USERPROFILE=str(profile), LOCALAPPDATA=str(local), MARU_CONFIG=str(config))
    env.pop('MARU_TRACE', None)
    env.pop('MARU_DEBUG', None)
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = 0
    with (work / 'app.log').open('wb') as out, (work / 'errors.log').open('wb') as err:
        proc = subprocess.Popen([str(exe), 'win32-terminal'], cwd=work, env=env, stdout=out, stderr=err, startupinfo=startup, creationflags=subprocess.CREATE_NO_WINDOW)
        resize_events = 0
        deadline = time.monotonic() + 18
        while time.monotonic() < deadline and proc.poll() is None and not (work / 'child-result.json').is_file():
            for hwnd in windows(proc.pid):
                u.ShowWindow(hwnd, 0)
                if interleave and (work / 'query-sent.json').exists():
                    if u.SetWindowPos(hwnd, None, 0, 0, 1000 + (resize_events % 2) * 32, 640 + (resize_events % 2) * 32, 0x14):
                        resize_events += 1
            time.sleep(.005)
        child = json.loads((work / 'child-result.json').read_text()) if (work / 'child-result.json').is_file() else None
        time.sleep(.5)
        if proc.poll() is None:
            for hwnd in windows(proc.pid):
                u.PostMessageW(hwnd, 0x0010, 0, 0)
        try:
            code = proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            code = None  # Record a live owned test; never kill another app.
    same = u.GetClipboardSequenceNumber() == before
    valid = child is not None and child['console_mode'] and same and code == 0
    if valid:
        valid = not child['received'] if policy == 'deny' else child['length'] == len(expected) and child['sha256'] == hashlib.sha256(expected).hexdigest()
    if valid and interleave:
        valid = resize_events > 0 and child['resize_after_frame'] and child['prefix_resize_only']
    return {'policy': policy, 'target': target, 'child': child, 'exit': code, 'clipboard_unchanged': same, 'valid': bool(valid), 'root': str(work), 'pid': proc.pid, 'resize_events': resize_events}


receipt = {'exe': str(exe), 'sha256': hashlib.sha256(exe.read_bytes()).hexdigest(), 'root': str(root), 'cases': [], 'large': args.large, 'valid': False}
clipboard = Clipboard()
failure = None
try:
    if args.large:
        clipboard.install()
    for policy, target in [('deny', 'c'), ('allow', 'c'), ('allow', ''), ('allow', 'p'), ('allow', 's0')]:
        name = policy + '-' + (target or 'empty')
        if args.case and name != args.case:
            continue
        case = run_case(policy, target, clipboard)
        receipt['cases'].append(case)
        print(name, case['valid'], 'exit=' + str(case['exit']), flush=True)
        if not case['valid']:
            raise RuntimeError('Actual app contract failed: ' + name)
    receipt['valid'] = len(receipt['cases']) == (1 if args.case else 5)
except Exception as error:
    failure = str(error)
finally:
    try:
        clipboard.restore()
    except Exception as error:
        failure = (failure + '; ' if failure else '') + str(error)
    receipt.update(failure=failure, clipboard_modified=clipboard.owned, restoration=clipboard.restoration)
    receipt['valid'] = receipt['valid'] and failure is None
    (root / 'result.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')
if not receipt['valid']:
    raise SystemExit(failure or 'Incomplete app fixture')
