#!/usr/bin/env python3
"""고정 헤더의 실제 AppKit·Metal 화면을 사용자 프로필과 분리해 캡처한다."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError(f"Injection anchor is not unique: {old!r}")
    return text.replace(old, new)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    repo = args.source.resolve()
    harness = Path(__file__).resolve().parent
    root = (args.output or Path(tempfile.mkdtemp(prefix="maru-sticky-capture-"))).resolve()
    if root == repo or repo in root.parents or (root.exists() and any(root.iterdir())):
        parser.error("Output must be an empty directory outside the source repository")
    root.mkdir(parents=True, exist_ok=True)
    source = root / "source"
    subprocess.run(["rsync", "-a", "--exclude=.git", "--exclude=.zig-cache", "--exclude=zig-out",
                    "--exclude=node_modules", "--exclude=zig-pkg", "--exclude=references", "--exclude=.env*",
                    str(repo) + "/", str(source) + "/"], check=True, timeout=120)
    for name in ("node_modules", "web/node_modules", "zig-pkg"):
        if (repo / name).exists():
            (source / name).symlink_to(repo / name, target_is_directory=True)
    names = ("src/syntax/tree_sitter.zig", "src/platform/macos/app_session/editor/sticky.zig",
             "src/session/editor/sticky.zig", "src/platform/macos/app_session/editor/mod.zig")
    hashes = {name: sha(source / name) for name in names}
    session = source / "src/platform/macos/app_session.zig"
    session.write_text(replace_once(session.read_text(), "        debug_fixtures.maybeDebugOpenNativeEditor(self);",
        "        debug_fixtures.maybeDebugOpenNativeEditor(self);\n        debug_fixtures.stickyAncestorObserve(self);"))
    observer = source / "src/platform/macos/app_session/debug_fixtures.zig"
    observer.write_text(observer.read_text() + "\n" + (harness / "fixture.zig.inc").read_text())
    host = source / "src/platform/macos/MaruAppHost.swift"
    host.write_text(replace_once(host.read_text(), "        maybeRunEditorIMESmoke()\n",
        "        maybeRunEditorIMESmoke()\n        maybeRunStickyAncestorCapture()\n") + "\n" + (harness / "driver.swift.inc").read_text())
    renderer = source / "src/platform/macos/maru_metal_renderer.m"
    renderer.write_text(replace_once(renderer.read_text(), "    static const char *const gates[] = {",
        '    static const char *const gates[] = {\n        "MARU_EDITOR_STICKY_CAPTURE",'))
    command = ["mise", "exec", "--", "zig", "build", "macos-app-bundle", "-j2"]
    print(root, flush=True)
    with (root / "build.log").open("wb") as log:
        subprocess.run(command, cwd=source, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=1200)
    app = source / "zig-out/Maru.app/Contents/MacOS/maru-macos-app"
    if not app.exists():
        apps = list((source / "zig-out").glob("**/Maru.app/Contents/MacOS/maru-macos-app"))
        if len(apps) != 1:
            raise RuntimeError("Expected one app bundle")
        app = apps[0]
    artifacts = root / "artifacts"
    artifacts.mkdir()
    (root / "home").mkdir()
    (root / "config").write_text("session.keep-alive-after-quit = false\nlsp.enabled = false\neditor.wrap = true\n")
    document = root / "sticky.zig"
    document.write_text("pub fn previous() void {\n    _ = 1;\n    // " + "x" * 4000 + "\n}\n\n" +
                        "// tail\n" * 4 + "const A = struct {\n pub fn active() void {\n" + "    _ = 1;\n" * 100 + " }\n};\n" + "// tail\n" * 80)
    original = document.read_bytes()
    env = {k: v for k, v in os.environ.items() if not k.startswith("MARU_")}
    env.update(HOME=str(root / "home"), CFFIXED_USER_HOME=str(root / "home"),
        XDG_CONFIG_HOME=str(root / "home/.config"), XDG_CACHE_HOME=str(root / "cache"), XDG_STATE_HOME=str(root / "state"),
        MARU_CONFIG=str(root / "config"), MARU_SESSION_HOST_ROOT=str(root / "host"), MARU_EDITOR_BACKUP_ROOT=str(root / "backups"),
        MARU_EDITOR_RECOVERY_CHECKPOINT_TEST="maru-test-only-v1", MARU_MACOS_APP_SMOKE_MS="45000",
        MARU_NATIVE_EDITOR=str(document), MARU_FT_WINDOW_SIZE="960x600", MARU_EDITOR_STICKY_CAPTURE="1",
        MARU_EDITOR_STICKY_OUTPUT=str(artifacts))
    with (root / "app.log").open("wb") as log:
        child = subprocess.Popen([str(app)], env=env, stdout=log, stderr=log, start_new_session=True)
        try:
            code = child.wait(timeout=60)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
            raise
    if code != 0 or "STICKY_CAPTURE_FINISH" not in (root / "app.log").read_text() or document.read_bytes() != original:
        raise RuntimeError("App capture failed; inspect app.log")
    for name in ("past-wrapped-body", "active-nested-body"):
        ppm = artifacts / (name + ".ppm")
        if not ppm.exists() or ppm.stat().st_size < 1000:
            raise RuntimeError(f"Missing capture: {name}")
        subprocess.run(["sips", "-s", "format", "png", str(ppm), "--out", str(ppm.with_suffix(".png"))], check=True, stdout=subprocess.DEVNULL)
    report = dict(scope="Isolated AppKit app and product Metal readback; fixture sets viewport", source_sha256=hashes,
                  binary_sha256=sha(app), command=command, captures={p.name: sha(p) for p in artifacts.glob("*.png")})
    (root / "manifest.json").write_text(json.dumps(report, indent=2) + "\n")
    print(root / "manifest.json", flush=True)


if __name__ == "__main__":
    main()
