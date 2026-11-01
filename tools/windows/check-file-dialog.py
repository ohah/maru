"""Probe Windows native picker options and, with --show, owned modal cancellation.

The two visible dialogs belong to isolated probe processes, not a running Maru.
Artifacts stay in the Windows temp cache; no user clipboard/config is modified.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", default=shutil.which("zig"))
    parser.add_argument("--show", action="store_true", help="Show and cancel two isolated native dialogs")
    parser.add_argument("--optimize", choices=["O0", "O3"], default="O0")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not __debug__:
        parser.error("Run without Python optimization; source and fixture guards must remain active")
    if os.name != "nt":
        parser.error("Windows is required")
    if not args.zig:
        parser.error("Pass --zig or add the project Zig toolchain to PATH")
    if args.output.exists():
        parser.error("Output receipt already exists; choose a new path")
    repo = Path(__file__).resolve().parents[2]
    expected = re.search(r'(?m)^zig\s*=\s*"([^"]+)"', (repo / ".mise.toml").read_text(encoding="utf-8"))
    if expected is None:
        parser.error("Project Zig version is missing")
    actual = subprocess.check_output([args.zig, "version"], text=True).strip()
    if actual != expected[1]:
        parser.error(f"Expected Zig {expected[1]}, got {actual}")
    sources = [repo / name for name in [
        "src/platform/windows/file_dialog/native.c",
        "src/platform/windows/file_dialog/native.h",
        "tests/windows/file_dialog/probe.c",
        "tests/windows/file_dialog/live.c",
        "tools/windows/check-file-dialog.py",
    ]]
    hashes = {str(path): sha(path) for path in sources}
    cache = Path(tempfile.gettempdir()).resolve() / ".zig-cache"
    cache.mkdir(exist_ok=True)
    artifacts = Path(tempfile.mkdtemp(prefix="maru-file-dialog-", dir=cache)).resolve()
    assert artifacts.is_relative_to(cache.resolve())
    results = []
    failure = None
    no_show_passed = False
    native = repo / "src/platform/windows/file_dialog/native.c"
    include = native.parent
    try:
        for name in ["probe"] + (["live"] if args.show else []):
            exe = artifacts / (name + ".exe")
            command = [args.zig, "cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-" + args.optimize, "-I", str(include), str(native), str(repo / "tests/windows/file_dialog" / (name + ".c")), "-o", str(exe), "-luser32", "-lshell32", "-lole32"]
            if name == "live":
                command.append("-municode")
            with (artifacts / (name + "-build.log")).open("wb") as log:
                built = subprocess.run(command, cwd=repo, stdout=log, stderr=subprocess.STDOUT, timeout=120)
            if built.returncode != 0:
                raise RuntimeError(f"{name} compilation failed; see {artifacts}")
            exe_hash = sha(exe)
            for mode in ([None] if name == "probe" else [1, 2]):
                assert sha(exe) == exe_hash
                run_args = [str(exe)]
                if mode is not None:
                    fixture = artifacts / (f"mode-{mode}-private-공백")
                    fixture.mkdir()
                    assert fixture.resolve().is_relative_to(artifacts)
                    run_args += [str(mode), str(fixture)]
                label = f"{name}-{mode}" if mode is not None else name
                with (artifacts / (label + ".log")).open("wb") as log, (artifacts / (label + "-stderr.log")).open("wb") as errors:
                    # run() owns this exact probe PID and kills only it on timeout.
                    run = subprocess.run(run_args, cwd=repo, stdout=log, stderr=errors, timeout=35)
                entry = {"name": label, "exit": run.returncode, "exe": str(exe), "exe_sha256": exe_hash}
                if name == "live" and run.returncode == 0:
                    data = json.loads((artifacts / (label + ".log")).read_text(encoding="utf-8"))
                    assert data["valid"] and data["mode"] == mode
                    entry["native"] = data
                results.append(entry)
                if run.returncode != 0:
                    raise RuntimeError(f"{label} failed; see {artifacts}")
                if name == "probe":
                    no_show_passed = True
    except Exception as error:
        failure = repr(error)
    unchanged = all(sha(Path(path)) == digest for path, digest in hashes.items())
    valid = failure is None and unchanged and no_show_passed
    receipt = {"valid": valid, "failure": failure, "artifacts": str(artifacts), "sources": hashes, "source_unchanged": unchanged, "no_show_passed": no_show_passed, "optimization": args.optimize, "live_requested": args.show, "live_verified": valid and args.show, "results": results, "limitations": ["Native adapter only; no app menu routing or file acceptance proof.", "Probe dialogs are owned processes; existing Maru windows are not targeted."]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(json.dumps(receipt, indent=2).encode())
    print(json.dumps({"valid": valid, "live_verified": receipt["live_verified"], "output": str(args.output), "artifacts": str(artifacts)}, ensure_ascii=False), flush=True)
    return 0 if valid else 1


if __name__ == "__main__":
    raise SystemExit(main())
