#!/usr/bin/env python3
"""격리한 실제 macOS 앱에서 프로젝트 검색 입력·클릭과 Metal 화면을 검증한다."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import re


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError(f"Expected one injection anchor: {old!r}")
    return text.replace(old, new)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--unicode-field", action="store_true")
    parser.add_argument("--count", type=int, default=60)
    parser.add_argument("--disk-files", type=int, default=0)
    parser.add_argument("--app", type=Path, help="이 하네스로 빌드한 앱을 재사용한다")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    root = (args.output or Path(tempfile.mkdtemp(prefix="maru-editor-project-search-app-"))).resolve()
    if root == repo or repo in root.parents or (root.exists() and any(root.iterdir())):
        parser.error("Output must be a new, empty directory outside the repository")
    root.mkdir(parents=True, exist_ok=True)
    names = ("src/platform/macos/app_session.zig", "src/platform/macos/app_session/editor/mod.zig",
             "src/platform/macos/app_session/editor/search/dock.zig", "src/platform/macos/MaruAppHost.swift",
             "src/platform/macos/app_session/debug_fixtures.zig", "src/platform/macos/maru_metal_renderer.m",
             "src/platform/macos/app_session/editor/search/dock/render.zig", "src/session/editor/search/results.zig",
             "src/chrome/components/project_search/build.zig", "src/chrome/components/project_search/view.zig",
             "src/platform/macos/app_session/accessibility.zig", "src/chrome/components/project_search/types.zig", "src/platform/macos/coretext_smoke.m",
             "src/platform/macos/app_session/input.zig", "src/platform/macos/app_session/editor/search/navigation.zig",
             "src/platform/macos/app_session/editor/search/verify.zig", "src/platform/macos/app_session/editor/search/coordinator.zig",
             "src/platform/macos/app_session/editor/search/backend.zig", "src/session/editor/search/query.zig")
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
            "        debug_fixtures.maybeDebugOpenNativeEditor(self);\n        debug_fixtures.editorProjectSearchObserve(self);"))
        session.write_text(replace_once(session.read_text(),
            '            @import("app_session/editor/search/owner.zig").poll(self);\n            project_search_ops.pump(self);',
            '            debug_fixtures.editorProjectSearchTick(self);'))
        observer = source / names[4]
        observer.write_text(observer.read_text() + "\n" + (repo / "tools/editor-project-search-app/fixture.zig.inc").read_text())
        host = source / names[3]
        host.write_text(replace_once(host.read_text(), "        maybeRunEditorIMESmoke()\n",
            "        maybeRunEditorIMESmoke()\n        maybeRunEditorProjectSearch()\n") + "\n" +
            (repo / "tools/editor-project-search-app/driver.swift.inc").read_text())
        renderer = source / names[5]
        renderer.write_text(replace_once(renderer.read_text(), "    static const char *const gates[] = {",
            '    static const char *const gates[] = {\n        "MARU_EDITOR_PROJECT_SEARCH_CAPTURE",'))
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
    project = root / "project"
    project.mkdir()
    document = project / "symbols.zig"
    document.write_text("pub const Widget = struct {\n    pub fn first() void {}\n    pub fn second() void {}\n};\n\n" + "".join(f"pub fn sample{i:02}() void {{\n    const value = {i};\n    _ = value;\n}}\n\n" for i in range(args.count)))
    for index in range(args.disk_files):
        (project / f"disk{index:04}.txt").write_text("sample disk\n" + "padding text\n" * 5000)
    if args.unicode_field:
        document.write_text("// 한글🙂x\n" + document.read_text())
    original = document.read_bytes()
    env = {key: value for key, value in os.environ.items() if not key.startswith("MARU_")}
    env.update(HOME=str(root / "home"), CFFIXED_USER_HOME=str(root / "home"),
        XDG_CONFIG_HOME=str(root / "home/.config"), XDG_CACHE_HOME=str(root / "cache"), XDG_STATE_HOME=str(root / "state"),
        MARU_CONFIG=str(root / "config"), MARU_SESSION_HOST_ROOT=str(root / "host"), MARU_EDITOR_BACKUP_ROOT=str(root / "backups"),
        MARU_EDITOR_RECOVERY_CHECKPOINT_TEST="maru-test-only-v1", MARU_MACOS_APP_SMOKE_MS="45000",
        MARU_NATIVE_EDITOR=str(document), MARU_FT_WINDOW_SIZE="960x600", MARU_EDITOR_PROJECT_SEARCH_CAPTURE="1",
        MARU_EDITOR_PROJECT_SEARCH_OUTPUT=str(artifacts), MARU_EDITOR_PROJECT_SEARCH_DISK_FILES=str(args.disk_files), MARU_EDITOR_PROJECT_SEARCH_UNICODE="1" if args.unicode_field else "0", MARU_EDITOR_PROJECT_SEARCH_EXPECTED=str(1 if args.unicode_field else args.count + args.disk_files), MARU_APP_SUMMARY_PATH=str(root / "summary.txt"))
    with (root / "app.log").open("wb") as log:
        child = subprocess.Popen([str(app)], env=env, stdout=log, stderr=log, start_new_session=True)
        try:
            samples = []
            deadline = time.monotonic() + 60
            while child.poll() is None:
                if time.monotonic() > deadline:
                    raise subprocess.TimeoutExpired(str(app), 60)
                measurement = subprocess.run(["ps", "-o", "rss=", "-p", str(child.pid)], capture_output=True, text=True)
                if measurement.stdout.strip().isdigit():
                    samples.append(dict(seconds=time.monotonic(), rss_bytes=int(measurement.stdout.strip()) * 1024))
                time.sleep(0.05)
            code = child.returncode
            (root / "rss.json").write_text(json.dumps(samples, indent=2) + "\n")
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
            raise
    transcript = (root / "app.log").read_text()
    if (code != 0 or "EDITOR_PROJECT_SEARCH_FINISH passed=true" not in transcript or
document.read_bytes() != original):
        raise RuntimeError("Product verification failed; inspect app.log")
    expected = ("before", "query", "results", "query-selection", "navigated", "bottom-scrolled", "cancelled")
    if args.disk_files:
        expected += ("disk-navigated",)
    for label in expected:
        ppm = artifacts / (label + ".ppm")
        if not ppm.exists() or ppm.stat().st_size < 1000:
            raise RuntimeError(f"Missing product capture: {label}")
        subprocess.run(["sips", "-s", "format", "png", str(ppm), "--out", str(ppm.with_suffix(".png"))],
                       check=True, stdout=subprocess.DEVNULL, timeout=30)
    match = re.search(r"SEARCH_METRICS first_ns=(\d+) complete_ns=(\d+) tick_max_ns=(\d+) cancel_call_ns=(\d+) cancel_retire_ns=(\d+)", transcript)
    if match is None or not samples:
        raise RuntimeError("Missing product timing/RSS evidence")
    metrics = dict(zip(("first_result_ns", "completion_ns", "main_search_tick_max_ns", "cancel_call_ns", "cancel_retire_ns"), map(int, match.groups())))
    metrics["peak_rss_bytes"] = max(sample["rss_bytes"] for sample in samples)
    report = dict(scope="Real AppKit search input, result click, navigation, bottom dock scrolling, cancellation and Metal readback",
        limits="No physical Korean HID or VoiceOver proof", source_sha256=hashes, binary_sha256=sha(app), command=command,
        product_passed=True, metrics=metrics, unicode_field=args.unicode_field, matches=1 if args.unicode_field else args.count + args.disk_files, harness_sha256={name: sha(Path(__file__).parent / name) for name in ("run.py", "fixture.zig.inc", "driver.swift.inc")}, artifacts={p.name: sha(p) for p in artifacts.glob("*.png")})
    (root / "manifest.json").write_text(json.dumps(report, indent=2) + "\n")
    print(root / "manifest.json", flush=True)


if __name__ == "__main__":
    main()
