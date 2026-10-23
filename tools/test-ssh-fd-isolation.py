#!/usr/bin/env python3
"""Run five descriptor attacks across seven launch paths and a healthy control on macOS/Linux."""
import pathlib
import subprocess
import sys
import os
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
fake_directory = tempfile.TemporaryDirectory(prefix="maru-ssh-fd-")
fake_ssh = pathlib.Path(fake_directory.name) / "ssh"
fake_ssh.write_text("#!/bin/sh\nfor fd in $MARU_SSH_TEST_FDS; do if [ -e /dev/fd/$fd ]; then printf inherited; exit 7; fi; done; if [ \"$MARU_SSH_TEST_WATCH\" = 1 ]; then payload=$(/bin/cat); [ \"$payload\" = watch ] || exit 9; elif [ -e /dev/fd/0 ]; then /bin/cat >/dev/null; fi; printf closed\n")
fake_ssh.chmod(0o700)
environment = dict(os.environ, PATH=fake_directory.name + os.pathsep + os.environ.get("PATH", ""))
for mode in ("Debug", "ReleaseFast"):
    command = [
        str(pathlib.Path(subprocess.check_output(["which", "zig"], text=True).strip())), "test", "-lc", "-O", mode,
        "--dep", "ssh_upload", "-Mroot=tests/ssh_fd_isolation.zig",
        "--dep", "maru", "-Mssh_upload=src/platform/macos/ssh_upload.zig",
        "--dep", "maru_terminfo", "-Mmaru=src/maru.zig",
        "-Mmaru_terminfo=terminfo/maru.terminfo",
    ]
    result = subprocess.run(command, cwd=root, env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    print(f"=== {mode} ===\n{result.stdout}", flush=True)
    if result.returncode or "All 6 tests passed." not in result.stdout:
        sys.exit(result.returncode or 1)
