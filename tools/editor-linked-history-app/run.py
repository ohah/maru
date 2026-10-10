#!/usr/bin/env python3
"""격리한 실제 macOS 앱에서 연결 이력 Undo·Redo·선택과 Metal 화면을 검증한다."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError(f"Expected one injection anchor: {old!r}")
    return text.replace(old, new)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--app", type=Path, help="이 하네스로 빌드한 앱을 재사용한다")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    root = (args.output or Path(tempfile.mkdtemp(prefix="maru-editor-linked-history-app-"))).resolve()
    if root == repo or repo in root.parents or (root.exists() and any(root.iterdir())):
        parser.error("Output must be a new, empty directory outside the repository")
    root.mkdir(parents=True, exist_ok=True)
    names = ("src/platform/macos/app_session.zig", "src/platform/macos/app_session/editor/mod.zig",
             "src/platform/macos/app_session/editor/history.zig", "src/platform/macos/MaruAppHost.swift",
             "src/platform/macos/app_session/debug_fixtures.zig", "src/platform/macos/maru_metal_renderer.m",
             "src/session/editor/history/forward.zig", "src/session/editor/history/step.zig",
             "src/session/editor/history/links.zig", "src/session/editor/document_registry.zig",
             "src/platform/macos/app_session/editor/shared_edit.zig", "src/i18n.zig")
    print(root, flush=True)
    if args.app:
        app = args.app.resolve()
        if app.name != "maru-macos-app":
            parser.error("Expected the GUI maru-macos-app binary")
        source = app.parents[4]
        hashes = {name: sha(source / name) for name in names}
        command = None
    else:
        source = root / "source"
        subprocess.run(["rsync", "-a", "--exclude=.git", "--exclude=.zig-cache", "--exclude=zig-out",
                        "--exclude=node_modules", "--exclude=references", "--exclude=.env*",
                        str(repo) + "/", str(source) + "/"], check=True, timeout=120)
        for name in ("node_modules", "web/node_modules"):
            if (repo / name).exists():
                (source / name).symlink_to(repo / name, target_is_directory=True)
        hashes = {name: sha(source / name) for name in names}
        if hashes != {name: sha(repo / name) for name in names}:
            raise RuntimeError("Source changed during copying")
        session = source / names[0]
        session.write_text(replace_once(session.read_text(), "        debug_fixtures.maybeDebugOpenNativeEditor(self);",
            "        debug_fixtures.maybeDebugOpenNativeEditor(self);\n        debug_fixtures.editorLinkedHistoryObserve(self);"))
        observer = source / names[4]
        observer.write_text(observer.read_text() + "\n" + (repo / "tools/editor-linked-history-app/fixture.zig.inc").read_text())
        host = source / names[3]
        host.write_text(replace_once(host.read_text(), "        maybeRunEditorIMESmoke()\n",
            "        maybeRunEditorIMESmoke()\n        maybeRunEditorLinkedHistory()\n") + "\n" +
            (repo / "tools/editor-linked-history-app/driver.swift.inc").read_text())
        renderer = source / names[5]
        renderer.write_text(replace_once(renderer.read_text(), "    static const char *const gates[] = {",
            '    static const char *const gates[] = {\n        "MARU_EDITOR_LINKED_HISTORY_CAPTURE",'))
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
    (root / "config").write_text("session.keep-alive-after-quit = false\n")
    document = root / "first.txt"
    document.write_text("first original\n")
    second = root / "second.txt"
    second.write_text("second original\n")
    original = document.read_bytes()
    env = {key: value for key, value in os.environ.items() if not key.startswith("MARU_")}
    env.update(HOME=str(root / "home"), CFFIXED_USER_HOME=str(root / "home"),
        XDG_CONFIG_HOME=str(root / "home/.config"), XDG_CACHE_HOME=str(root / "cache"), XDG_STATE_HOME=str(root / "state"),
        MARU_CONFIG=str(root / "config"), MARU_SESSION_HOST_ROOT=str(root / "host"), MARU_EDITOR_BACKUP_ROOT=str(root / "backups"),
        MARU_EDITOR_RECOVERY_CHECKPOINT_TEST="maru-test-only-v1", MARU_MACOS_APP_SMOKE_MS="45000",
        MARU_NATIVE_EDITOR=str(document), MARU_EDITOR_LINKED_HISTORY_SECOND=str(second), MARU_FT_WINDOW_SIZE="960x600", MARU_EDITOR_LINKED_HISTORY_CAPTURE="1",
        MARU_EDITOR_LINKED_HISTORY_OUTPUT=str(artifacts), MARU_APP_SUMMARY_PATH=str(root / "summary.txt"))
    with (root / "app.log").open("wb") as log:
        child = subprocess.Popen([str(app)], env=env, stdout=log, stderr=log, start_new_session=True)
        try:
            code = child.wait(timeout=60)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
            raise
    transcript = (root / "app.log").read_text()
    if (code != 0 or "EDITOR_LINKED_HISTORY_FINISH passed=true" not in transcript or document.read_bytes() != original or second.read_text() != "second original\n"):
        raise RuntimeError("Product verification failed; inspect app.log")
    expected = ("edited", "undo-confirm", "cancelled", "undone", "redo-confirm", "redone", "current-confirm", "current-only")
    for label in expected:
        ppm = artifacts / (label + ".ppm")
        if not ppm.exists() or ppm.stat().st_size < 1000:
            raise RuntimeError(f"Missing product capture: {label}")
        subprocess.run(["sips", "-s", "format", "png", str(ppm), "--out", str(ppm.with_suffix(".png"))],
                       check=True, stdout=subprocess.DEVNULL, timeout=30)
    report = dict(scope="Internal linked forward API, real AppKit Cmd Z Shift Cmd Z and confirmation mouse events, product Metal readback",
        limits="No physical Korean HID or VoiceOver proof", source_sha256=hashes, binary_sha256=sha(app), command=command,
        product_passed=True, harness_sha256={name: sha(Path(__file__).parent / name) for name in ("run.py", "fixture.zig.inc", "driver.swift.inc")}, artifacts={p.name: sha(p) for p in artifacts.glob("*.png")})
    (root / "manifest.json").write_text(json.dumps(report, indent=2) + "\n")
    print(root / "manifest.json", flush=True)


if __name__ == "__main__":
    main()
