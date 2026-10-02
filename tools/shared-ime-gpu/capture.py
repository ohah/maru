#!/usr/bin/env python3
"""Capture real shared IME and find editor frames through the product Metal readback.

macOS only. Creates an isolated source snapshot and compiles a focused fixture there.
No installed app, GUI input, input source, TCC, or repository build graph is changed.
The captures are separate per-view frames, not one simultaneous two-pane window.
Each phase/view executes in a fresh process because the product screenshot hook
retains its initial environment path for the lifetime of that process.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile

SOURCE_FILES = (
    "build.zig",
    "src/platform/macos/app_session.zig",
    "src/platform/macos/app_session/editor/mod.zig",
    "src/platform/macos/app_session/editor_ime.zig",
    "src/platform/macos/app_session/find.zig",
    "src/platform/macos/app_session/term.zig",
    "src/platform/macos/app_session/pane.zig",
    "src/platform/macos/app_session/tab.zig",
    "src/platform/macos/chrome_lab_smoke.m",
    "src/platform/macos/maru_metal_renderer.m",
    "src/platform/macos/coretext_frame_builder.zig",
    "src/platform/macos/coretext_smoke.m",
    "tools/shared-ime-gpu/fixture.zig.inc",
    "tools/shared-ime-gpu/capture.py",
)
ANCHOR = "    const shared_editor_tests = addProjectTest(b, .{"
FILTER = '.filters = &.{"shared editor"},'
LINK = '''    editor_test_module.addIncludePath(b.path("src/platform/macos"));
    inline for (.{"chrome_lab_smoke.m", "maru_metal_renderer.m"}) |file|
        editor_test_module.addCSourceFile(.{
            .file = b.path("src/platform/macos/" ++ file),
            .flags = &.{"-fobjc-arc", "-fno-sanitize=undefined"},
        });
'''


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def unique_replace(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise RuntimeError(f"Expected one snapshot build anchor: {old!r}")
    return text.replace(old, new)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenario", choices=("ime", "find"), default="ime")
    parser.add_argument("--output", type=Path, help="New or empty evidence directory")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Requires macOS CoreText and Metal")
    repo = Path(__file__).resolve().parents[2]
    output = (args.output or Path(tempfile.mkdtemp(prefix="maru-shared-ime-gpu-"))).resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Output directory must be empty to prevent stale capture evidence")
    if output == repo or repo in output.parents:
        parser.error("Output must be outside the repository")
    output.mkdir(parents=True, exist_ok=True)
    snapshot = output / "snapshot"
    artifacts = output / "artifacts"
    snapshot.mkdir()
    artifacts.mkdir()
    fixture_path = "tools/shared-ime-gpu/fixture.zig.inc" if args.scenario == "ime" else "tools/shared-ime-gpu/find-fixture.zig.inc"
    source_files = tuple(name for name in SOURCE_FILES if name != "tools/shared-ime-gpu/fixture.zig.inc") + (fixture_path,)
    source_hashes = {name: digest(repo / name) for name in source_files}
    subprocess.run(
        ["rsync", "-a", "--exclude=.git", "--exclude=.zig-cache", "--exclude=zig-out",
         "--exclude=node_modules", "--exclude=.env*", f"{repo}/", f"{snapshot}/"],
        check=True, timeout=120,
    )
    # Hash the snapshot rather than trusting that no source changed during copying.
    if any(digest(snapshot / name) != sha for name, sha in source_hashes.items()):
        raise RuntimeError("Source changed while copying; rerun with a new output directory")
    build_path = snapshot / "build.zig"
    build = unique_replace(build_path.read_text(), ANCHOR, LINK + ANCHOR)
    build = unique_replace(build, FILTER, '.filters = &.{"shared editor GPU capture"},')
    # Cached compilation is reusable; the test execution must happen every time.
    build = unique_replace(build, "    const run_shared_editor_tests = b.addRunArtifact(shared_editor_tests);",
                           "    const run_shared_editor_tests = b.addRunArtifact(shared_editor_tests);\n"
                           "    run_shared_editor_tests.has_side_effects = true;")
    build_path.write_text(build)
    fixture = (snapshot / fixture_path).read_text()
    # Escape only the inside of the fixture's Zig string literals.
    fixture = fixture.replace("__ARTIFACT_DIR__", json.dumps(str(artifacts))[1:-1])
    mod_path = snapshot / "src/platform/macos/app_session/editor/mod.zig"
    with mod_path.open("a") as stream:
        stream.write("\n\n" + fixture)
    command = ["mise", "exec", "--", "zig", "build", "test-editor-shared", "-j2"]
    log = output / "capture.log"
    phases = ("before", "marked", "cancelled", "committed") if args.scenario == "ime" else ("before", "search", "edited", "closed")
    revisions = {phase: int(phase == "committed") if args.scenario == "ime" else int(phase in ("edited", "closed")) for phase in phases}
    executions = []
    process_ids = set()
    with log.open("w") as combined:
        for phase in phases:
            for view in ("owner", "peer"):
                selectors = {"MARU_SHARED_IME_CAPTURE_PHASE": phase,
                             "MARU_SHARED_IME_CAPTURE_VIEW": view}
                run_log = output / f"capture-{phase}-{view}.log"
                with run_log.open("w") as stream:
                    subprocess.run(command, cwd=snapshot, env={**os.environ, **selectors},
                                   stdout=stream, stderr=subprocess.STDOUT,
                                   check=True, timeout=600)
                transcript = run_log.read_text()
                combined.write(transcript)
                combined.flush()
                captures = re.findall(r"GPU (\w+)/(\w+) pid=(\d+) status=0 draw=1 png=1 revision=(\d+)", transcript)
                if len(captures) != 1 or captures[0][:2] != (phase, view):
                    raise RuntimeError(f"Expected exactly one acknowledged frame: {phase}/{view}")
                pid = int(captures[0][2])
                if pid in process_ids:
                    raise RuntimeError("Capture process was reused across scenarios")
                process_ids.add(pid)
                if int(captures[0][3]) != revisions[phase]:
                    raise RuntimeError("Captured canonical revision disagrees with the phase")
                executions.append({"argv": command, "env": selectors, "cwd": str(snapshot),
                                   "log": str(run_log), "capture_process_pid": pid})
    images = [artifacts / f"{phase}-{view}.{ext}" for phase in phases
              for view in ("owner", "peer") for ext in ("png", "ppm")]
    for image in images:
        if not image.is_file() or image.stat().st_size == 0:
            raise RuntimeError(f"Missing capture: {image}")
        if image.suffix == ".png" and image.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
            raise RuntimeError(f"Invalid PNG: {image}")
    manifest = {
        "scope": "Real AppSession shared views -> appendPaneFrame -> CoreText -> product Metal offscreen readback",
        "limits": "Separate per-view frames. No OS/HID callback or simultaneous multi-pane window evidence.",
        "scenario": args.scenario,
        "source_sha256": source_hashes,
        "snapshot_mod_sha256": digest(mod_path),
        "snapshot_build_sha256": digest(build_path),
        "command": command,
        "fresh_process_commands": executions,
        "log": str(log),
        "phases": {phase: {"canonical_revision": revisions[phase]} for phase in phases},
        "artifact_sha256": {str(image.relative_to(output)): digest(image) for image in images},
    }
    if args.scenario == "ime":
        manifest["cancelled_operation"] = "ime.marked with empty string; not an observed OS cancellation"
        for phase in phases:
            manifest["phases"][phase]["peer_preedit_bytes"] = 0
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(output / "manifest.json")


if __name__ == "__main__":
    main()
