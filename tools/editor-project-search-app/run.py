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


from untitled_oracle import parse_metrics, parse_build_mode


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def native_session_state():
    result = subprocess.run(["swift", "-e",
        'import CoreGraphics; if let session = CGSessionCopyCurrentDictionary() as? [String: Any] { print(session["CGSSessionScreenIsLocked"] as? Int == 1 ? "locked" : "unlocked") } else { print("unavailable") }'],
        check=True, capture_output=True, text=True, timeout=30)
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--unicode-field", action="store_true")
    parser.add_argument("--physical-ime", action="store_true")
    parser.add_argument("--matrix", action="store_true")
    parser.add_argument("--native-close-save", action="store_true")
    parser.add_argument("--untitled-save-benchmark", action="store_true")
    parser.add_argument("--untitled-bytes", type=int, default=65536)
    parser.add_argument("--untitled-delay-ms", type=int, default=0)
    parser.add_argument("--save-as-command", action="store_true")
    parser.add_argument("--save-as-physical-ime", action="store_true")
    parser.add_argument("--save-as-scenario", choices=("save", "cancel", "edit-during-write"), default="save")
    parser.add_argument("--native-panel-capture-app", type=Path,
                        help="화면 기록이 허용된 native-window-capture.swift.inc 앱 번들")
    parser.add_argument("--replace-batch", action="store_true")
    parser.add_argument("--replace-batch-save-retry", action="store_true")
    parser.add_argument("--batch-open-files", type=int, default=2)
    parser.add_argument("--batch-peer-bytes", type=int, default=0)
    parser.add_argument("--disk-padding-lines", type=int, default=5000)
    parser.add_argument("--batch-save-delay-ms", type=int, default=0)
    parser.add_argument("--timeout-seconds", type=int, default=60)
    parser.add_argument("--replace-preview", action="store_true")
    parser.add_argument("--replace-apply", action="store_true")
    parser.add_argument("--replace-disk-apply", action="store_true")
    parser.add_argument("--replace-ime-refuse", action="store_true")
    parser.add_argument("--conflict-markers", action="store_true")
    parser.add_argument("--narrow-hidden", action="store_true")
    parser.add_argument("--window-size", default="960x600")
    parser.add_argument("--render-scale", type=int, choices=(1000, 2000), default=1000)
    parser.add_argument("--count", type=int, default=60)
    parser.add_argument("--disk-files", type=int, default=0)
    parser.add_argument("--optimize", choices=("Debug", "ReleaseFast"), default="Debug")
    parser.add_argument("--app", type=Path, help="이 하네스로 빌드한 앱을 재사용한다")
    args = parser.parse_args()
    if args.untitled_save_benchmark and (args.save_as_command or args.native_close_save or args.matrix or args.physical_ime or args.replace_preview or args.unicode_field):
        parser.error("Untitled benchmark must run without other GUI scenarios")
    if not args.untitled_save_benchmark and (args.untitled_bytes != 65536 or args.untitled_delay_ms != 0):
        parser.error("Untitled size/delay options need --untitled-save-benchmark")
    if not 2 <= args.untitled_bytes <= 8 * 1024 * 1024 or not 0 <= args.untitled_delay_ms <= 2000:
        parser.error("Untitled benchmark needs 2..8388608 bytes and 0..2000 ms")
    if args.save_as_physical_ime and (not args.save_as_command or not args.native_panel_capture_app or args.physical_ime or args.save_as_scenario != "save"):
        parser.error("Save As physical IME needs native capture, --save-as-command and the save scenario without --physical-ime")
    if args.save_as_scenario != "save" and (not args.save_as_command or not args.native_panel_capture_app):
        parser.error("Save As lifecycle scenarios need --save-as-command and --native-panel-capture-app")
    if args.native_panel_capture_app and (not args.save_as_command or not args.native_panel_capture_app.is_dir()):
        parser.error("Native panel capture needs --save-as-command and an existing capture app bundle")
    if not 2 <= args.batch_open_files <= 64:
        parser.error("Batch open-file measurement is bounded to 2..64")
    if not 0 <= args.batch_peer_bytes <= 1048576 or not 0 <= args.disk_padding_lines <= 400000 or not 0 <= args.batch_save_delay_ms <= 50 or not 60 <= args.timeout_seconds <= 300:
        parser.error("Measurement bounds: peer <=1MiB, disk padding <=400000 lines, delay <=50ms, timeout 60..300s")
    if args.replace_batch_save_retry:
        args.replace_batch = True
    if args.replace_batch:
        args.replace_apply = True
        if args.disk_files != 2:
            parser.error("Batch fixture needs exactly two closed disk files")
    if args.replace_ime_refuse:
        args.replace_disk_apply = True
    if args.replace_disk_apply:
        args.replace_apply = True
        if args.disk_files < 2:
            parser.error("Disk apply requires at least two disk files")
    if args.conflict_markers and not args.replace_apply:
        parser.error("Conflict marker warning requires replace apply")
    if args.replace_apply:
        args.replace_preview = True
    if (args.physical_ime and (args.matrix or args.unicode_field or args.disk_files)) or (args.matrix and (args.unicode_field or args.disk_files)):
        parser.error("Physical IME and matrix use separate fixtures")
    if args.replace_preview and (args.matrix or args.unicode_field or args.physical_ime):
        parser.error("Replacement preview uses a separate fixture")
    if re.fullmatch(r"[1-9][0-9]{2,3}x[1-9][0-9]{2,3}", args.window_size) is None:
        parser.error("Expected a bounded WIDTHxHEIGHT")
    repo = Path(__file__).resolve().parents[2]
    if args.save_as_command and args.output is None:
        # NSSavePanel은 /private/tmp를 링크 경로 /tmp로 돌려줄 수 있다.
        # 부모 링크를 거절하는 제품 저장 계약에 맞춰 기본 fixture는 홈 캐시에 둔다.
        cache = Path.home() / "Library/Caches/maru-verification"
        cache.mkdir(parents=True, exist_ok=True)
        args.output = Path(tempfile.mkdtemp(prefix="maru-save-as-app-", dir=cache))
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
             "src/platform/macos/app_session/editor/search/verify.zig", "src/platform/macos/app_session/editor/search/disk_apply.zig", "src/platform/macos/app_session/editor/search/preview.zig", "src/session/editor/search/preview.zig", "src/platform/macos/app_session/editor/search/coordinator.zig",
             "src/platform/macos/app_session/editor/search/backend.zig", "src/session/editor/search/query.zig",
             "src/platform/macos/app_session/editor/search/report.zig", "src/platform/macos/app_session/editor/search/owner.zig", "src/platform/macos/app_session/tab.zig", "src/i18n.zig", "src/icons.zig", "src/renderer/icon_coverage_data.zig", "src/platform/macos/icon_codepoints.h", "src/platform/macos/app_session/editor/search/batch.zig", "src/platform/macos/app_session/editor/search/batch/ui.zig", "src/platform/macos/app_session/editor/search/batch/worker.zig", "src/platform/macos/app_session/editor/search/batch/mixed_worker.zig", "src/platform/macos/app_session/editor/search/batch/collect.zig", "src/platform/macos/app_session/editor/search/batch/coordinator.zig", "src/platform/macos/app_session/editor/search/batch/load.zig", "src/platform/macos/app_session/editor/local_save.zig", "src/platform/macos/app_session/editor/save/dispatch.zig", "src/platform/macos/app_session/editor/save/owner.zig", "src/session/editor/ops/save_receipt.zig", "src/session/editor/search/batch.zig", "src/editor_save_notice.zig")
    if args.untitled_save_benchmark:
        names += ("src/platform/macos/app_session/editor/untitled_save.zig",)
    if args.save_as_command:
        names += ("src/platform/macos/app_session/editor/save/as.zig", "src/platform/macos/app_session/editor/save/queue.zig", "src/platform/macos/app_session/editor/save/destination.zig", "src/platform/macos/app_session/editor/lsp.zig", "src/config/action.zig", "src/config/keybinding.zig", "src/platform/macos/app_host_abi.h", "src/platform/macos/app_host_abi.zig", "tools/editor-project-search-app/save-as.swift.inc", "tools/editor-project-search-app/save-as.zig.inc")
    if args.native_close_save:
        names += ("src/platform/macos/app_session/editor/save/close.zig", "src/platform/macos/app_session/editor/format.zig")
    print(root, flush=True)
    if args.app:
        app = args.app.resolve()
        if app.name != "maru-macos-app":
            parser.error("Expected the GUI maru-macos-app binary")
        source = app.parents[4]
        if args.save_as_scenario == "edit-during-write" and "fn saveAsWriteGate(" not in (source / "src/platform/macos/app_session/editor/local_save.zig").read_text():
            parser.error("This app lacks the writer gate; build a new Save As verification app")
        if args.save_as_physical_ime and "SAVE_AS_IME marked=true" not in (source / "src/platform/macos/MaruAppHost.swift").read_text():
            parser.error("This app lacks the Korean Save As driver; build a new verification app")
        if args.untitled_save_benchmark:
            if "maru_untitled_benchmark_probe" not in (source / "src/platform/macos/MaruAppHost.swift").read_text() or "UNTITLED_SERIALIZE" not in (source / "src/platform/macos/app_session/editor/untitled_save.zig").read_text():
                parser.error("This app lacks the untitled benchmark driver and delay hook")
        hashes = {name: sha(source / name) for name in names}
        command = None
    else:
        source = root / "source"
        subprocess.run(["rsync", "-a", "--exclude=.git", "--exclude=.zig-cache", "--exclude=zig-out",
                        "--exclude=node_modules", "--exclude=references", "--exclude=.env*", "--exclude=.codex-worktrees",
                        str(repo) + "/", str(source) + "/"], check=True, timeout=120)
        # 격리 사본은 checkout의 설치 상태나 공유 node_modules에 의존하지 않는다.
        with (root / "dependencies.log").open("wb") as log:
            subprocess.run(["mise", "exec", "--", "bun", "install", "--frozen-lockfile"],
                           cwd=source / "web", stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=300)
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
        observer.write_text(observer.read_text() + "\n" + (source / "tools/editor-project-search-app/fixture.zig.inc").read_text() + "\n" + (source / "tools/editor-project-search-app/batch.zig.inc").read_text() + ("\n" + (source / "tools/editor-project-search-app/native-close.zig.inc").read_text() if args.native_close_save else ""))
        driver = (source / "tools/editor-project-search-app/driver.swift.inc").read_text()
        if args.native_close_save:
            driver = replace_once(driver, "        let now = ProcessInfo.processInfo.systemUptime\n        guard now >= EditorProjectSearchRun.next", "        if EditorProjectSearchRun.stage == 80 { maybeRunNativeCloseSave(); return }\n        let now = ProcessInfo.processInfo.systemUptime\n        guard now >= EditorProjectSearchRun.next")
            driver = replace_once(driver, "            if !matrix { finish(true); return }", "            if ProcessInfo.processInfo.environment[\"MARU_EDITOR_NATIVE_CLOSE_SAVE\"] == \"1\" { EditorProjectSearchRun.stage = 80; return }\n            if !matrix { finish(true); return }")
            driver += "\n" + (source / "tools/editor-project-search-app/native-close.swift.inc").read_text()
        if args.save_as_command:
            observer.write_text(observer.read_text() + "\n" + (source / "tools/editor-project-search-app/save-as.zig.inc").read_text())
            driver = replace_once(driver, "        let now = ProcessInfo.processInfo.systemUptime\n        guard now >= EditorProjectSearchRun.next", "        if EditorProjectSearchRun.stage == 81 { maybeRunSaveAsCommand(); return }\n        let now = ProcessInfo.processInfo.systemUptime\n        guard now >= EditorProjectSearchRun.next")
            driver = replace_once(driver, "            if !matrix { finish(true); return }", "            if ProcessInfo.processInfo.environment[\"MARU_EDITOR_SAVE_AS_COMMAND\"] == \"1\" { EditorProjectSearchRun.stage = 81; return }\n            if !matrix { finish(true); return }")
            driver += "\n" + (source / "tools/editor-project-search-app/save-as.swift.inc").read_text()
        if args.untitled_save_benchmark:
            observer.write_text(observer.read_text() + "\n" + (source / "tools/editor-project-search-app/untitled-save.zig.inc").read_text())
            driver = replace_once(driver, "        let now = ProcessInfo.processInfo.systemUptime\n        guard now >= EditorProjectSearchRun.next", "        if EditorProjectSearchRun.stage == 82 { maybeRunUntitledBenchmark(); return }\n        let now = ProcessInfo.processInfo.systemUptime\n        guard now >= EditorProjectSearchRun.next")
            driver = replace_once(driver, "            if !matrix { finish(true); return }", "            if ProcessInfo.processInfo.environment[\"MARU_UNTITLED_BENCHMARK\"] == \"1\" { EditorProjectSearchRun.stage = 82; return }\n            if !matrix { finish(true); return }")
            driver += "\n" + (source / "tools/editor-project-search-app/untitled-save.swift.inc").read_text()
            untitled = source / "src/platform/macos/app_session/editor/untitled_save.zig"
            untitled.write_text(replace_once(untitled.read_text(), "fn writeAndAdopt(self: *AppSession, term: *Term, abs: []const u8, overwriting: bool) void {", "fn writeAndAdopt(self: *AppSession, term: *Term, abs: []const u8, overwriting: bool) void {\n    const benchmark_started = std.Io.Clock.awake.now(self.io).nanoseconds;"))
            untitled.write_text(replace_once(untitled.read_text(), "    const saved_content = doc.file.content;", "    const saved_content = doc.file.content;\n    std.debug.print(\"UNTITLED_SERIALIZE ns={d}\\n\", .{std.Io.Clock.awake.now(self.io).nanoseconds - benchmark_started});\n    const benchmark_delay = std.fmt.parseInt(u32, std.mem.span(std.c.getenv(\"MARU_UNTITLED_DELAY_MS\") orelse \"0\"), 10) catch 0;\n    if (benchmark_delay > 0) std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(benchmark_delay), .awake) catch {};"))
            untitled.write_text(replace_once(untitled.read_text(), "    // **새 파일과 덮어쓰기는 다른 함수다.**", "    const benchmark_io_started = std.Io.Clock.awake.now(self.io).nanoseconds;\n    // **새 파일과 덮어쓰기는 다른 함수다.**"))
            untitled.write_text(replace_once(untitled.read_text(), "    // **여기부터 실패해도 파일은 이미 있다**", "    std.debug.print(\"UNTITLED_IO ns={d}\\n\", .{std.Io.Clock.awake.now(self.io).nanoseconds - benchmark_io_started});\n    // **여기부터 실패해도 파일은 이미 있다**"))
        host = source / names[3]
        host.write_text(replace_once(host.read_text(), "        maybeRunEditorIMESmoke()\n",
            "        maybeRunEditorIMESmoke()\n        maybeRunEditorProjectSearch()\n") + "\n" +
            driver)
        host.write_text(replace_once(host.read_text(), "    let physical = window?.backingScaleFactor ?? 1.0",
            '    let physical = window?.backingScaleFactor ?? 1.0\n    if let raw = ProcessInfo.processInfo.environment["MARU_EDITOR_PROJECT_SEARCH_SCALE"], let value = UInt32(raw), value == 1000 || value == 2000 { return CGFloat(value) / 1000.0 }'))
        renderer = source / names[5]
        renderer.write_text(replace_once(renderer.read_text(), "    static const char *const gates[] = {",
            '    static const char *const gates[] = {\n        "MARU_EDITOR_PROJECT_SEARCH_CAPTURE",'))
        report_source = source / "src/platform/macos/app_session/editor/search/report.zig"
        report_source.write_text(replace_once(report_source.read_text(), "pub fn open(self: *host.AppSession) !*host.Term {",
            'pub fn open(self: *host.AppSession) !*host.Term {\n    const capture_start = std.Io.Clock.awake.now(self.io).nanoseconds;\n    defer std.debug.print("SEARCH_PANE_BUILD elapsed_ns={d}\\n", .{std.Io.Clock.awake.now(self.io).nanoseconds - capture_start});'))
        batch_source = source / "src/platform/macos/app_session/editor/search/batch/ui.zig"
        batch_source.write_text(replace_once(batch_source.read_text(), "pub fn start(self: *host.AppSession) !void {",
            'var batch_prepare_start_ns: ?i128 = null;\npub fn start(self: *host.AppSession) !void {\n    const measured_start = std.Io.Clock.awake.now(self.io).nanoseconds;\n    batch_prepare_start_ns = measured_start;\n    defer std.debug.print("BATCH_CAPTURE elapsed_ns={d}\\n", .{std.Io.Clock.awake.now(self.io).nanoseconds - measured_start});'))
        batch_source.write_text(replace_once(batch_source.read_text(), "    st.batch.phase = .ready;",
            '    st.batch.phase = .ready;\n    std.debug.print("BATCH_PREPARE elapsed_ns={d}\\n", .{std.Io.Clock.awake.now(self.io).nanoseconds - (batch_prepare_start_ns orelse 0)});'))
        batch_source.write_text(replace_once(batch_source.read_text(), "pub fn apply(self: *host.AppSession) !void {",
            'pub var batch_apply_start_ns: ?i128 = null;\npub fn apply(self: *host.AppSession) !void {\n    const measured_start = std.Io.Clock.awake.now(self.io).nanoseconds;\n    batch_apply_start_ns = measured_start;\n    defer std.debug.print("BATCH_APPLY elapsed_ns={d}\\n", .{std.Io.Clock.awake.now(self.io).nanoseconds - measured_start});'))
        if "fn pollSaveResults(" in batch_source.read_text():
            batch_source.write_text(replace_once(batch_source.read_text(), "        updateSaveCounts(st);\n        self.editor_search.invalidate();",
                '        updateSaveCounts(st);\n        if (st.result.saving == 0) std.debug.print("BATCH_SETTLED elapsed_ns={d}\\n", .{std.Io.Clock.awake.now(self.io).nanoseconds - (batch_apply_start_ns orelse 0)});\n        self.editor_search.invalidate();'))
        else:
            batch_source.write_text(replace_once(batch_source.read_text(), '    defer std.debug.print("BATCH_APPLY elapsed_ns={d}\\n", .{std.Io.Clock.awake.now(self.io).nanoseconds - measured_start});',
                '    defer std.debug.print("BATCH_APPLY elapsed_ns={d}\\n", .{std.Io.Clock.awake.now(self.io).nanoseconds - measured_start});\n    defer std.debug.print("BATCH_SETTLED elapsed_ns={d}\\n", .{std.Io.Clock.awake.now(self.io).nanoseconds - measured_start});'))
        save_source = source / "src/platform/macos/app_session/editor/search/batch.zig"
        save_source.write_text(replace_once(save_source.read_text(), "    var result = initial;",
            '    const save_start = std.Io.Clock.awake.now(session.io).nanoseconds;\n    defer std.debug.print("BATCH_SAVE elapsed_ns={d}\\n", .{std.Io.Clock.awake.now(session.io).nanoseconds - save_start});\n    var result = initial;'))
        # 같은 지연을 실제 writer에 넣어 동기/worker 경로를 같은 조건으로 비교한다.
        local_source = source / "src/platform/macos/app_session/editor/local_save.zig"
        local_source.write_text(replace_once(local_source.read_text(), "    pub fn write(self: *Prepared, io: std.Io) editor.SaveError!void {",
            '    pub fn write(self: *Prepared, io: std.Io) editor.SaveError!void {\n        const delay = std.fmt.parseInt(u32, std.mem.span(std.c.getenv("MARU_EDITOR_PROJECT_BATCH_SAVE_DELAY_MS") orelse "0"), 10) catch 0;\n        if (delay > 0) std.Io.sleep(io, std.Io.Duration.fromMilliseconds(delay), .awake) catch {};\n        if (std.c.getenv("MARU_EDITOR_NATIVE_CLOSE_SAVE") != null) std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1000), .awake) catch {};'))
        if args.save_as_command:
            local_source.write_text(replace_once(local_source.read_text(),
                "    pub fn write(self: *Prepared, io: std.Io) editor.SaveError!void {",
                "    pub fn write(self: *Prepared, io: std.Io) editor.SaveError!void {\n        try saveAsWriteGate(self, io);") +
                "\n" + (source / "tools/editor-project-search-app/save-as-write-gate.zig.inc").read_text())
        command = ["mise", "exec", "--", "zig", "build", "macos-app-bundle", "-j2", "-Doptimize=" + args.optimize]
        print(root, flush=True)
        with (root / "build.log").open("wb") as log:
            subprocess.run(command, cwd=source, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=1200)
        app = source / "zig-out/Maru.app/Contents/MacOS/maru-macos-app"
        if not app.exists():
            apps = list((source / "zig-out").glob("**/Maru.app/Contents/MacOS/maru-macos-app"))
            if len(apps) != 1:
                raise RuntimeError("Expected one app bundle")
            app = apps[0]
    # 예전 계측 앱에는 새 저장 잎이 없다. 존재하는 앱에서는 그 잎까지 source 증거에 묶는다.
    for name in ("src/platform/macos/app_session/editor/local_save.zig", "src/session/editor/ops/save_ops.zig"):
        if (source / name).exists():
            hashes[name] = sha(source / name)
    artifacts = root / "artifacts"
    artifacts.mkdir()
    (root / "home").mkdir()
    (root / "config").write_text("session.keep-alive-after-quit = false\n")
    project = root / "project"
    project.mkdir()
    document = project / "symbols.zig"
    document.write_text("pub const Widget = struct {\n    pub fn first() void {}\n    pub fn second() void {}\n};\n\n" + "".join(f"pub fn sample{i:02}() void {{\n    const value = {i};\n    _ = value;\n}}\n\n" for i in range(args.count)))
    for index in range(args.disk_files):
        (project / f"disk{index:04}.txt").write_text("sample disk\n" + "padding text\n" * args.disk_padding_lines)
    if args.physical_ime:
        document.write_text("// 한글\n" + document.read_text())
    if args.unicode_field:
        document.write_text("// 한글🙂x\n" + document.read_text())
    if args.conflict_markers:
        document.write_text(document.read_text() + "\n<<<<<<< ours\na\n=======\nb\n>>>>>>> theirs\n")
    peers = [project / ("peer.zig" if i == 1 else f"peer{i}.zig") for i in range(1, args.batch_open_files)] if args.replace_batch else []
    peer_original = b"pub fn sample_peer() void {}\n" + (b"//" + b"x" * args.batch_peer_bytes + b"\n" if args.batch_peer_bytes else b"")
    original = document.read_bytes()
    disk_originals = {p: p.read_bytes() for p in project.glob("disk*.txt")}
    other = root / "other-project"
    other.mkdir()
    (other / "fresh.txt").write_text("sample fresh\n")
    env = {key: value for key, value in os.environ.items() if not key.startswith("MARU_")}
    env.update(HOME=str(root / "home"), CFFIXED_USER_HOME=str(root / "home"),
        XDG_CONFIG_HOME=str(root / "home/.config"), XDG_CACHE_HOME=str(root / "cache"), XDG_STATE_HOME=str(root / "state"),
        MARU_CONFIG=str(root / "config"), MARU_SESSION_HOST_ROOT=str(root / "host"), MARU_EDITOR_BACKUP_ROOT=str(root / "backups"),
        MARU_EDITOR_RECOVERY_CHECKPOINT_TEST="maru-test-only-v1", MARU_MACOS_APP_SMOKE_MS="45000",
        MARU_NATIVE_EDITOR=str(document), MARU_FT_WINDOW_SIZE=args.window_size, MARU_EDITOR_PROJECT_SEARCH_SCALE=str(args.render_scale), MARU_EDITOR_PROJECT_SEARCH_MATRIX="1" if args.matrix else "0", MARU_EDITOR_PROJECT_REPLACE_PREVIEW="1" if args.replace_preview else "0", MARU_EDITOR_PROJECT_REPLACE_APPLY="1" if args.replace_apply else "0", MARU_EDITOR_PROJECT_REPLACE_DISK_APPLY="1" if args.replace_disk_apply else "0", MARU_EDITOR_PROJECT_REPLACE_IME_REFUSE="1" if args.replace_ime_refuse else "0", MARU_EDITOR_PROJECT_REPLACE_MARKERS="1" if args.conflict_markers else "0", MARU_EDITOR_PROJECT_SEARCH_TINY="1" if args.narrow_hidden else "0", MARU_EDITOR_PROJECT_SEARCH_OTHER_ROOT=str(other), MARU_EDITOR_PROJECT_SEARCH_CAPTURE="1",
        MARU_EDITOR_PROJECT_SEARCH_OUTPUT=str(artifacts), MARU_EDITOR_PROJECT_SEARCH_DISK_FILES=str(args.disk_files), MARU_EDITOR_PROJECT_SEARCH_UNICODE="1" if args.unicode_field else "0", MARU_EDITOR_PROJECT_SEARCH_PHYSICAL="1" if args.physical_ime else "0", MARU_EDITOR_PROJECT_SEARCH_MODEL_MATCHES=str(args.count), MARU_EDITOR_PROJECT_SEARCH_EXPECTED=str(1 if args.unicode_field or args.physical_ime else args.count + args.disk_files), MARU_APP_SUMMARY_PATH=str(root / "summary.txt"))
    env["MARU_EDITOR_PROJECT_BATCH_OPEN_FILES"] = str(args.batch_open_files)
    env["MARU_EDITOR_PROJECT_BATCH_PEER_BYTES"] = str(args.batch_peer_bytes)
    env["MARU_EDITOR_PROJECT_BATCH_SAVE_DELAY_MS"] = str(args.batch_save_delay_ms)
    if args.untitled_save_benchmark:
        env["MARU_UNTITLED_BENCHMARK"] = "1"
        env["MARU_UNTITLED_BYTES"] = str(args.untitled_bytes)
        env["MARU_UNTITLED_DELAY_MS"] = str(args.untitled_delay_ms)
    if args.native_close_save: env["MARU_EDITOR_NATIVE_CLOSE_SAVE"] = "1"
    if args.save_as_command: env["MARU_EDITOR_SAVE_AS_COMMAND"] = "1"
    env["MARU_EDITOR_SAVE_AS_SCENARIO"] = args.save_as_scenario
    if args.save_as_physical_ime: env["MARU_EDITOR_SAVE_AS_PHYSICAL_IME"] = "1"
    if args.native_panel_capture_app: env["MARU_NATIVE_PANEL_CAPTURE_EXTERNAL"] = "1"
    env["MARU_EDITOR_PROJECT_BATCH_SAVE_RETRY"] = "1" if args.replace_batch_save_retry else "0"
    env["MARU_EDITOR_PROJECT_REPLACE_BATCH"] = "1" if args.replace_batch else "0"
    if args.physical_ime or args.save_as_physical_ime:
        main = root / "main.swift"
        main.write_text((repo / "src/platform/macos/SessionHostInputSourcePolicy.swift").read_text() + "\n" +
                        (source / "tools/editor-project-search-app/hid.swift.inc").read_text())
        subprocess.run(["swiftc", str(main), "-o", str(root / "hid")], check=True, timeout=60)
    if args.native_panel_capture_app:
        state = native_session_state()
        (root / "session-state.json").write_text(json.dumps({"state": state}) + "\n")
        if state != "unlocked":
            raise RuntimeError("Native Save As GUI needs an unlocked macOS session; observed " + state)
    with (root / "app.log").open("wb") as log:
        child = subprocess.Popen([str(app)], env=env, stdout=log, stderr=log, start_new_session=True)
        hid = None
        hid_log = None
        try:
            if args.physical_ime or args.save_as_physical_ime:
                hid_log = (root / "hid.log").open("wb")
                hid = subprocess.Popen([str(root / "hid"), str(child.pid), str(artifacts)], env=env, stdout=hid_log, stderr=hid_log)
            samples = []
            panel_captured = False
            panel_capture_attempts = 0
            panel_confirmed = False
            deadline = time.monotonic() + args.timeout_seconds
            while child.poll() is None:
                request = artifacts / "save-as-panel-request.json"
                if args.native_panel_capture_app and not panel_captured and request.exists():
                    target = json.loads(request.read_text())
                    window_id = target.get("panel_id", target["window_id"])
                    if not isinstance(window_id, int) or not 0 < window_id <= 0xffffffff:
                        raise RuntimeError("Invalid native panel window ID")
                    pending = artifacts / "save-as-panel-pending.png"
                    # 빠르게 끝난 앱은 open -W가 kevent 등록 전에 종료될 수 있다.
                    # 실행기 종료 코드 대신 실제 PNG 게시를 아래에서 확인한다.
                    subprocess.run(["open", "-W", "-n", "-a", str(args.native_panel_capture_app.resolve()),
                                    "--args", str(window_id), str(pending)], timeout=30)
                    panel_capture_attempts += 1
                    if not pending.exists():
                        if panel_capture_attempts >= 10:
                            raise RuntimeError("Native panel capture failed; inspect /tmp/maru-screen-capture-status.json")
                    else:
                        pending.replace(artifacts / "save-as-panel.png")
                        panel_captured = True
                if args.native_panel_capture_app and not panel_confirmed and (artifacts / "save-as-confirm-request").exists():
                    # 대상 프로세스의 실제 sheet 필드와 Save 버튼만 접근성 API로 조작한다.
                    script = '''on run arguments
tell application "System Events"
set targetProcess to first process whose unix id is (item 1 of arguments as integer)
set frontmost of targetProcess to true
repeat 50 times
if exists window 1 of targetProcess then
if exists sheet 1 of window 1 of targetProcess then exit repeat
end if
delay 0.1
end repeat
set paneGroup to splitter group 1 of sheet 1 of window 1 of targetProcess
if value of text field 1 of paneGroup is not "save-as-source.txt" then error "Unexpected Save As filename"
if item 2 of arguments is "cancel" then
click button "Cancel" of paneGroup
else
set value of text field 1 of paneGroup to "save-as-destination.txt"
click button "Save" of paneGroup
end if
end tell
end run'''
                    subprocess.run(["osascript", "-e", script, str(child.pid), args.save_as_scenario], check=True, timeout=15)
                    (artifacts / "save-as-confirm-sent").write_text("native-accessibility\n")
                    panel_confirmed = True
                if hid is not None and hid.poll() not in (None, 0):
                    raise RuntimeError("Physical IME driver failed; inspect hid.log")
                if time.monotonic() > deadline:
                    raise subprocess.TimeoutExpired(str(app), args.timeout_seconds)
                measurement = subprocess.run(["ps", "-o", "rss=", "-p", str(child.pid)], capture_output=True, text=True)
                if measurement.stdout.strip().isdigit():
                    samples.append(dict(seconds=time.monotonic(), rss_bytes=int(measurement.stdout.strip()) * 1024))
                time.sleep(0.05)
            code = child.returncode
            (root / "rss.json").write_text(json.dumps(samples, indent=2) + "\n")
            if hid is not None and hid.wait(timeout=30) != 0:
                raise RuntimeError("Physical IME driver failed; inspect hid.log")
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
            # HID의 실패·앱 종료도 자기 복원 defer까지 기다린다. 전역 입력기 기록은 강제 삭제하지 않는다.
            if hid is not None:
                hid.wait(timeout=30)
            if hid_log is not None:
                hid_log.close()
    transcript = (root / "app.log").read_text()
    # 재시도 시나리오는 치환된 본문을 저장한 채 종료한다. 기대값은 Plan 대신 fixture 원문에서 계산한다.
    expected_bytes = lambda data: data.replace(b"sample", b"renamed") if args.replace_batch_save_retry else data
    if (code != 0 or "EDITOR_PROJECT_SEARCH_FINISH passed=true" not in transcript or
        any(peer.read_bytes() != expected_bytes(peer_original) for peer in peers) or document.read_bytes() != expected_bytes(original) or any(p.read_bytes() != expected_bytes(data) for p, data in disk_originals.items())):
        raise RuntimeError("Product verification failed; inspect app.log")
    expected = ("before", "query", "results", "query-selection", "navigated", "bottom-scrolled", "cancelled")
    if args.disk_files:
        expected += ("disk-navigated",)
    if args.physical_ime:
        expected += ("ime-marked",)
    if args.narrow_hidden:
        expected += ("geometry-hidden",)
    if args.replace_preview:
        expected += ("replace-input", "replace-results", "replace-file", "replace-conflict", "replace-single", "replace-disk", "right-replace-disk", "right-replace-file", "right-replace-conflict", "search-pane", "search-pane-navigated", "pane-preview-results", "pane-preview-ready", "preview-pane")
    if args.replace_ime_refuse:
        expected += ("replace-verifying", "replace-ime-conflict")
    elif args.replace_apply:
        expected += ("replace-applied-saved", "replace-undo", "replace-undo-saved")
    if args.replace_batch_save_retry:
        expected += ("right-save-failed", "bottom-save-failed", "bottom-retry-saved", "right-retry-saved")
    if args.replace_batch:
        expected += ("batch-results", "right-batch-preview", "bottom-batch-preview")
        if not args.replace_batch_save_retry:
            expected += ("bottom-batch-saved", "right-batch-saved", "batch-undo", "batch-undo-saved")
    if args.matrix:
        expected += ("shared", "independent", "zero-override", "root-changed", "stale-release")
    if args.untitled_save_benchmark:
        expected += ("untitled-saved",)
        data = bytes(ord("x") if i % 2 == 0 else 10 for i in range(args.untitled_bytes))
        if (project / "untitled-benchmark.txt").read_bytes() != data:
            raise RuntimeError("Untitled first-save disk bytes differ")
        untitled_metrics = parse_metrics(transcript, args.untitled_bytes, args.untitled_delay_ms)
        if parse_build_mode(transcript) != args.optimize:
            raise RuntimeError("Actual untitled app build mode differs from --optimize")
    if args.native_close_save:
        expected += ("native-close-confirm", "native-close-saving", "native-close-saved", "native-close-edit-kept", "native-close-conflict-kept")
        for name, data in (("saved", b"foo!"), ("kept", b"foo!"), ("conflict", b"outside")):
            if (project / ("native-close-" + name + ".txt")).read_bytes() != data:
                raise RuntimeError("Native close disk bytes differ: " + name)
    if args.save_as_command:
        expected += ("save-as-before", "save-as-after")
        if args.save_as_scenario != "save" and "SAVE_AS_HISTORY undo=true redo=true" not in transcript:
            raise RuntimeError("Save As lifecycle scenario did not verify Undo/Redo")
        saved = "foo한".encode() if args.save_as_physical_ime else b"foo!"
        wanted = (("source", b"foo"),) if args.save_as_scenario == "cancel" else (("source", b"foo"), ("destination", saved))
        if args.save_as_physical_ime:
            expected += ("save-as-ime-marked",)
            if "SAVE_AS_IME marked=true" not in transcript or "source_restore=restored original=" not in (root / "hid.log").read_text():
                raise RuntimeError("Missing real marked-text or input source restoration evidence")
        for name, data in wanted:
            if (project / ("save-as-" + name + ".txt")).read_bytes() != data:
                raise RuntimeError("Save As disk bytes differ: " + name)
        if args.save_as_scenario == "cancel" and (project / "save-as-destination.txt").exists():
            raise RuntimeError("Cancelled Save As created a destination")
        if args.save_as_scenario == "edit-during-write":
            if (artifacts / "save-as-writer-entered").read_bytes() != b"foo!":
                raise RuntimeError("Writer did not freeze the expected pre-edit snapshot")
            expected += ("save-as-edit-pending",)
        if not (artifacts / "save-as-panel.png").exists():
            raise RuntimeError("Missing native NSSavePanel capture")
    for label in expected:
        ppm = artifacts / (label + ".ppm")
        if not ppm.exists() or ppm.stat().st_size < 1000:
            raise RuntimeError(f"Missing product capture: {label}")
        subprocess.run(["sips", "-s", "format", "png", str(ppm), "--out", str(ppm.with_suffix(".png"))],
                       check=True, stdout=subprocess.DEVNULL, timeout=30)
    for label in ("bottom-batch-saving", "right-batch-saving"):
        ppm = artifacts / (label + ".ppm")
        if ppm.exists():
            subprocess.run(["sips", "-s", "format", "png", str(ppm), "--out", str(ppm.with_suffix(".png"))], check=True, stdout=subprocess.DEVNULL, timeout=30)
    match = re.search(r"SEARCH_METRICS first_ns=(\d+) complete_ns=(\d+) tick_max_ns=(\d+) cancel_call_ns=(\d+) cancel_retire_ns=(\d+)", transcript)
    if match is None or not samples:
        raise RuntimeError("Missing product timing/RSS evidence")
    metrics = dict(zip(("first_result_ns", "completion_ns", "main_search_tick_max_ns", "cancel_call_ns", "cancel_retire_ns"), map(int, match.groups())))
    metrics["peak_rss_bytes"] = max(sample["rss_bytes"] for sample in samples)
    metrics["pane_build_ns"] = [int(value) for value in re.findall(r"SEARCH_PANE_BUILD elapsed_ns=(\d+)", transcript)]
    for label in ("CAPTURE", "PREPARE", "APPLY", "SAVE"):
        metrics["batch_" + label.lower() + "_ns"] = [int(value) for value in re.findall(r"BATCH_" + label + r" elapsed_ns=(\d+)", transcript)]
    metrics["batch_settled_ns"] = [int(value) for value in re.findall(r"BATCH_SETTLED elapsed_ns=(\d+)", transcript)]
    metrics["batch_main_queue_ns"] = [int(value) for value in re.findall(r"BATCH_MAIN_QUEUE elapsed_ns=(\d+)", transcript)]
    metrics["batch_plans"] = [dict(zip(("files", "matches", "closed", "input_bytes", "output_bytes", "plan_rows"), map(int, values))) for values in re.findall(r"BATCH_READY files=(\d+) matches=(\d+) closed=(\d+) input_bytes=(\d+) output_bytes=(\d+) plan_rows=(\d+)", transcript)]
    if args.replace_batch and (not metrics["batch_apply_ns"] or not metrics["batch_plans"]):
        raise RuntimeError("Missing actual batch timing evidence")
    report = dict(scope="Real AppKit search input, result click, navigation, bottom dock scrolling, cancellation and Metal readback",
        limits="Korean CGEvent typing and Save As composition commit verified; shortcut is AppKit NSEvent; no VoiceOver proof" if args.save_as_physical_ime else "Physical Korean HID and Enter verified; no VoiceOver or OS candidate screenshot proof" if args.physical_ime else "No physical Korean HID or VoiceOver proof", source_sha256=hashes, binary_sha256=sha(app), command=command,
        product_passed=True, native_close_save=args.native_close_save, metrics=metrics, unicode_field=args.unicode_field, physical_ime=args.physical_ime, matrix=args.matrix, batch_open_files=args.batch_open_files, batch_peer_bytes=args.batch_peer_bytes, optimize=args.optimize, disk_padding_lines=args.disk_padding_lines, batch_save_delay_ms=args.batch_save_delay_ms, replace_batch_save_retry=args.replace_batch_save_retry, replace_batch=args.replace_batch, replace_preview=args.replace_preview, replace_apply=args.replace_apply, replace_disk_apply=args.replace_disk_apply, replace_ime_refuse=args.replace_ime_refuse, conflict_markers=args.conflict_markers, narrow_hidden=args.narrow_hidden, window_size=args.window_size, render_scale=args.render_scale, matches=1 if args.unicode_field or args.physical_ime else args.count + args.disk_files, harness_sha256={name: sha(source / "tools/editor-project-search-app" / name) for name in ("run.py", "fixture.zig.inc", "driver.swift.inc", "hid.swift.inc", "batch.zig.inc", "native-close.zig.inc", "native-close.swift.inc")}, artifacts={p.name: sha(p) for p in artifacts.glob("*.png")})
    if args.untitled_save_benchmark:
        report["untitled_save_benchmark"] = untitled_metrics
        report["untitled_oracle_sha256"] = sha(Path(__file__).with_name("untitled_oracle.py"))
        report["untitled_prepared_source_sha256"] = {name: sha(source / name) for name in names}
        report["scope"] = "Synchronous untitled first-save naming commit in the actual AppKit main queue; disk bytes and model adoption"
        for name in ("untitled-save.swift.inc", "untitled-save.zig.inc"):
            report["harness_sha256"][name] = sha(source / "tools/editor-project-search-app" / name)
    report["runner_sha256"] = sha(Path(__file__))
    report["save_as_command"] = args.save_as_command
    report["save_as_scenario"] = args.save_as_scenario
    report["save_as_physical_ime"] = args.save_as_physical_ime
    if args.save_as_command:
        report["scope"] = "AppKit Save As shortcut, native sheet capture and accessibility confirmation; model path and original/destination disk bytes"
        if args.save_as_physical_ime:
            report["scope"] += "; Korean input source CGEvent composition, marked text before Save As, source restoration"
        for name in ("save-as.swift.inc", "save-as.zig.inc"):
            report["harness_sha256"][name] = sha(source / "tools/editor-project-search-app" / name)
        gate = source / "tools/editor-project-search-app/save-as-write-gate.zig.inc"
        if gate.exists(): report["harness_sha256"][gate.name] = sha(gate)
        if args.save_as_scenario == "edit-during-write":
            report["writer_snapshot_sha256"] = sha(artifacts / "save-as-writer-entered")
        if args.native_panel_capture_app:
            report["native_panel_capture"] = {
                "method": "ScreenCaptureKit",
                "confirmation": "native-accessibility",
                "binary_sha256": sha(args.native_panel_capture_app / "Contents/MacOS/capture"),
                "request": json.loads((artifacts / "save-as-panel-request.json").read_text()),
            }
    (root / "manifest.json").write_text(json.dumps(report, indent=2) + "\n")
    print(root / "manifest.json", flush=True)


if __name__ == "__main__":
    main()
