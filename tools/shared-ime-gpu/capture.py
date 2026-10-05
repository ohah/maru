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
    "src/session/editor/find.zig",
    "src/session/editor/line_index.zig",
    "src/regex.zig",
    "src/search_case_fold.zig",
    "src/chrome/components/editor_view/frame.zig",
    "src/platform/macos/app_session.zig",
    "src/platform/macos/app_session/editor/mod.zig",
    "src/platform/macos/app_session/editor/shared_edit.zig",
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
    parser.add_argument("--scenario", choices=("ime", "find", "anchors", "regex"), default="ime")
    parser.add_argument("--output", type=Path, help="New or empty evidence directory")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Requires macOS CoreText and Metal")
    repo = Path(__file__).resolve().parents[2]
    output = (args.output or Path(tempfile.mkdtemp(prefix="maru-shared-ime-gpu-"))).resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Output directory must be empty to prevent stale capture evidence")
    # rsync는 zig-out을 제외하므로 이 안의 격리 사본은 원본을 재귀 복사하지 않는다.
    # 다른 저장소 내부 경로는 제품 소스와 섞이지 않도록 계속 거부한다.
    if (output == repo or repo in output.parents) and not (repo / "zig-out") in output.parents:
        parser.error("Output must be outside the repository or inside ignored zig-out")
    output.mkdir(parents=True, exist_ok=True)
    snapshot = output / "snapshot"
    artifacts = output / "artifacts"
    snapshot.mkdir()
    artifacts.mkdir()
    fixture_path = {"ime": "tools/shared-ime-gpu/fixture.zig.inc", "find": "tools/shared-ime-gpu/find-fixture.zig.inc", "anchors": "tools/shared-ime-gpu/anchors-fixture.zig.inc", "regex": "tools/shared-ime-gpu/regex-fixture.zig.inc"}[args.scenario]
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
    phases = {"ime": ("before", "marked", "cancelled", "committed"), "find": ("before", "search", "edited", "closed"), "anchors": ("before", "edited", "undo", "redo"), "regex": ("before", "search", "edited", "closed")}[args.scenario]
    revisions = {phase: int(phase == "committed") if args.scenario == "ime" else int(phase in ("edited", "closed")) for phase in phases}
    if args.scenario == "anchors":
        revisions = {"before": 0, "edited": 1, "undo": 2, "redo": 3}
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
    pixel_checks = []
    if args.scenario == "regex":
        # 현재 선택만 보이는 거짓 통과를 막기 위해 비현재 매치 두 줄도 실제 픽셀로 대조한다.
        def pixel(path, x, y):
            header = path.read_bytes().split(b"\n", 3)
            if len(header) != 4 or header[0] != b"P6" or header[2] != b"255":
                raise RuntimeError("Unexpected PPM header")
            width, height = map(int, header[1].split())
            if len(header[3]) != width * height * 3 or not (0 <= x < width and 0 <= y < height):
                raise RuntimeError("Invalid PPM pixel bounds")
            at = (y * width + x) * 3
            return list(header[3][at:at + 3])
        for role, y in (("current-start", 61), ("current-end", 77), ("other-start", 109), ("other-end", 125)):
            before = pixel(artifacts / "before-owner.ppm", 77, y)
            after = pixel(artifacts / "search-owner.ppm", 77, y)
            if before == after:
                raise RuntimeError(f"Regex highlight did not change actual pixels: {role}")
            pixel_checks.append({"role": role, "x": 77, "y": y, "before": before, "after": after})
    manifest = {
        "scope": "Real AppSession shared views -> appendPaneFrame -> CoreText -> product Metal offscreen readback",
        "limits": "Separate per-view frames. No OS/HID callback or simultaneous multi-pane window evidence.",
        "scenario": args.scenario,
        "pixel_checks": pixel_checks,
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
