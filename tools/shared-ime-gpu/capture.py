#!/usr/bin/env python3
"""Capture real shared IME editor frames through the product Metal readback.

macOS only. Creates an isolated source snapshot and compiles a focused fixture there.
No installed app, GUI input, input source, TCC, or repository build graph is changed.
The captures are separate per-view frames, not one simultaneous two-pane window.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

SOURCE_FILES = (
    "build.zig",
    "src/platform/macos/app_session.zig",
    "src/platform/macos/app_session/editor/mod.zig",
    "src/platform/macos/app_session/editor_ime.zig",
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
    source_hashes = {name: digest(repo / name) for name in SOURCE_FILES}
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
    build_path.write_text(build)
    fixture = (snapshot / "tools/shared-ime-gpu/fixture.zig.inc").read_text()
    # Escape only the inside of the fixture's Zig string literals.
    fixture = fixture.replace("__ARTIFACT_DIR__", json.dumps(str(artifacts))[1:-1])
    mod_path = snapshot / "src/platform/macos/app_session/editor/mod.zig"
    with mod_path.open("a") as stream:
        stream.write("\n\n" + fixture)
    command = ["mise", "exec", "--", "zig", "build", "test-editor-shared", "-j2"]
    log = output / "capture.log"
    with log.open("w") as stream:
        subprocess.run(command, cwd=snapshot, stdout=stream, stderr=subprocess.STDOUT,
                       check=True, timeout=600)
    phases = ("before", "marked", "cancelled", "committed")
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
        "cancelled_operation": "ime.marked with empty string; not an observed OS cancellation",
        "source_sha256": source_hashes,
        "snapshot_mod_sha256": digest(mod_path),
        "snapshot_build_sha256": digest(build_path),
        "command": command,
        "log": str(log),
        "phases": {phase: {"canonical_revision": int(phase == "committed"),
                           "peer_preedit_bytes": 0} for phase in phases},
        "artifact_sha256": {str(image.relative_to(output)): digest(image) for image in images},
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(output / "manifest.json")


if __name__ == "__main__":
    main()
