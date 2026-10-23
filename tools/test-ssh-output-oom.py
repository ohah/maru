#!/usr/bin/env python3
"""Run five output allocation-failure sweeps and healthy controls on macOS."""
import pathlib
import subprocess
import sys
import os
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
fake_directory = tempfile.TemporaryDirectory(prefix="maru-ssh-oom-")
fake_ssh = pathlib.Path(fake_directory.name) / "ssh"
fake_ssh.write_text("#!/bin/sh\nprintf 0123456789abcdef\n")
fake_ssh.chmod(0o700)
environment = dict(os.environ, PATH=fake_directory.name)
for mode in ("Debug", "ReleaseFast"):
    command = [
        str(pathlib.Path(subprocess.check_output(["which", "zig"], text=True).strip())), "test", "-lc", "-O", mode,
        "--dep", "ssh_upload", "-Mroot=tests/ssh_output_oom.zig",
        "--dep", "maru", "-Mssh_upload=src/platform/macos/ssh_upload.zig",
        "--dep", "maru_terminfo", "-Mmaru=src/maru.zig",
        "-Mmaru_terminfo=terminfo/maru.terminfo",
    ]
    result = subprocess.run(command, cwd=root, env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(f"=== {mode} ===\n{result.stdout}", flush=True)
    if result.returncode or "All 5 tests passed." not in result.stdout:
        sys.exit(result.returncode or 1)
