"""Reap the driver and revoke its session's live workers, including reparented groups."""
import ctypes
import os
import signal
import subprocess
import time

LIBC = ctypes.CDLL(None)
LIBC.getsid.argtypes = [ctypes.c_int]
LIBC.getsid.restype = ctypes.c_int


def live_session(leader):
    result = {}
    for line in subprocess.check_output(["ps", "-axo", "pid=,ppid=,state="]).decode().splitlines():
        pid, parent, state = line.split()
        pid, parent = int(pid), int(parent)
        if not state.startswith("Z") and LIBC.getsid(pid) == leader:
            result[pid] = parent
    return result


def send(pid, sig):
    try:
        os.kill(pid, sig)
    except ProcessLookupError:
        pass


def cleanup(leader):
    owned = live_session(leader)
    # Freeze known actors before enumerating again; PID numeric order is not ancestry order.
    for _ in range(4):
        for pid in owned:
            if LIBC.getsid(pid) == leader:
                send(pid, signal.SIGSTOP)
        latest = live_session(leader)
        if set(latest) <= set(owned):
            break
        owned.update(latest)
    def depth(pid):
        seen = set()
        while pid in owned and pid not in seen:
            seen.add(pid)
            pid = owned[pid]
        return len(seen)
    for pid in sorted(owned, key=depth, reverse=True):
        if LIBC.getsid(pid) == leader:
            send(pid, signal.SIGKILL)
    deadline = time.monotonic() + 1
    remaining = live_session(leader)
    while remaining and time.monotonic() < deadline:
        owned.update(remaining)
        for pid in remaining:
            if LIBC.getsid(pid) == leader:
                send(pid, signal.SIGSTOP)
        for pid in sorted(remaining, key=depth, reverse=True):
            if LIBC.getsid(pid) == leader:
                send(pid, signal.SIGKILL)
        time.sleep(0.01)
        remaining = live_session(leader)
    if remaining:
        raise RuntimeError("owned workers survived cleanup")
    return sorted(owned)
