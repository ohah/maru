#!/usr/bin/env python3
"""Build an isolated capture app without changing the working product sources.

The normal deferred startup can encounter the native-editor debug hook before a
live Surface is initialized. Controlled smoke initializes it first, but its demo
keys would edit the sample. The sole private patch skips those demo keys and
keeps the normal window-size setup. LSP, parsing, themes and paint are unchanged.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

from run import REPO


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", type=Path, required=True, help="New directory outside the repository")
    args = parser.parse_args()
    snapshot = args.snapshot.resolve()
    if snapshot == REPO or REPO in snapshot.parents or snapshot.exists():
        parser.error("Snapshot must be a new directory outside the repository")
    snapshot.mkdir(parents=True)
    subprocess.run(["rsync", "-a", "--exclude=.git", "--exclude=.zig-cache", "--exclude=zig-out",
                    "--exclude=node_modules", "--exclude=references", "--exclude=.env*",
                    str(REPO) + "/", str(snapshot) + "/"], check=True, timeout=120)
    for name in ("node_modules", "web/node_modules"):
        if (REPO / name).exists():
            (snapshot / name).symlink_to(REPO / name, target_is_directory=True)
    host = snapshot / "src/platform/macos/MaruAppHost.swift"
    before = host.read_bytes()
    old = "            if filePanelHookEnabled {\n                // FP11f cold helper"
    new = ('            if ProcessInfo.processInfo.environment["MARU_EDITOR_THEME_GALLERY"] == "1" {\n'
           '                resizeAppSessionFromWindow()\n'
           '            } else if filePanelHookEnabled {\n                // FP11f cold helper')
    text = before.decode()
    if text.count(old) != 1:
        raise RuntimeError("Private fixture injection anchor changed; inspect the new startup code")
    host.write_text(text.replace(old, new))
    manifest = dict(source_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip(),
                    patch="skip controlled-smoke demo keys and retain product resize for MARU_EDITOR_THEME_GALLERY=1",
                    source_sha256=hashlib.sha256(before).hexdigest(), fixture_sha256=hashlib.sha256(host.read_bytes()).hexdigest())
    (snapshot / "theme-gallery-fixture.json").write_text(json.dumps(manifest, indent=2) + "\n")
    with (snapshot / "theme-gallery-build.log").open("wb") as log:
        subprocess.run(["mise", "exec", "--", "zig", "build", "macos-app-build", "-j2"], cwd=snapshot, stdout=log, stderr=log, check=True)
    app = snapshot / "zig-out/Maru.app/Contents/MacOS/maru-macos-app"
    manifest["app_sha256"] = hashlib.sha256(app.read_bytes()).hexdigest()
    (snapshot / "theme-gallery-fixture.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(app)


if __name__ == "__main__":
    main()
