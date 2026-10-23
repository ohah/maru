#!/usr/bin/env python3
"""Run five resource-exhaustion attacks and a healthy local command on macOS."""
import pathlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]
for mode in ("Debug", "ReleaseFast"):
    command = [
        "zig", "test", "-lc", "-O", mode,
        "--dep", "ssh_upload", "-Mroot=tests/ssh_pipe_cleanup.zig",
        "--dep", "maru", "-Mssh_upload=src/platform/macos/ssh_upload.zig",
        "--dep", "maru_terminfo", "-Mmaru=src/maru.zig",
        "-Mmaru_terminfo=terminfo/maru.terminfo",
    ]
    result = subprocess.run(command, cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(f"=== {mode} ===\n{result.stdout}", flush=True)
    if result.returncode or "All 6 tests passed." not in result.stdout:
        sys.exit(result.returncode or 1)
