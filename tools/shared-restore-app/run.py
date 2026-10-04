#!/usr/bin/env python3
"""두 공유 pane의 실제 AppKit 종료/복원/리사이즈와 선택적 OS IME 검증.

제품 소스 사본에 관측 및 초기 상태 준비만 주입한다. checkpoint writer/reader,
편집/렌더/입력/종료 구현은 그대로 실행하며 사용자 데이터는 격리한다.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import tempfile


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError(f"주입 지점은 정확히 하나여야 합니다: {old!r}")
    return text.replace(old, new)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def compare_states(name, scenarios):
    """프로세스 성공과 복원 계약의 성공을 분리한다. 차이는 artifact에 남긴다."""
    seed = next(s for s in scenarios if s["phase"] in ("seed", "ime"))
    restored = next(s for s in scenarios if s["phase"] == "restore")
    expected = {v["view"]: v for v in seed["states"]}
    issues = []
    labels = {(str(label), str(view)) for label in range(20, 24) for view in range(2)}
    observed = {(v["label"], v["view"]) for v in restored["states"]}
    if len(seed["states"]) != 2 or set(expected) != {"0", "1"} or len(restored["states"]) != 8 or observed != labels:
        return [dict(scenario=name, field="observations", expected="2 seed + 8 restore states", actual="missing")]
    fields = ("hash", "bytes", "dirty", "anchor", "focus", "wrap", "folded", "doc_line", "piece", "col")
    for actual in restored["states"]:
        before = expected[actual["view"]]
        for key in fields:
            if actual[key] != before[key]:
                issues.append(dict(scenario=name, label=actual["label"], view=actual["view"],
                                   field=key, expected=before[key], actual=actual[key]))
        if actual["shared"] != "true" or int(actual["hit_rows"]) == 0:
            issues.append(dict(scenario=name, field="shared_visible_frame", actual=actual))
    return issues


def prepare(repo, snapshot):
    subprocess.run(["rsync", "-a", "--exclude=.git", "--exclude=.zig-cache", "--exclude=zig-out",
                    "--exclude=node_modules", "--exclude=references", "--exclude=.env*",
                    str(repo) + "/", str(snapshot) + "/"], check=True, timeout=120)
    # 웹 번들 빌드는 이미 설치된 개발 의존성만 읽는다. 사본마다 재설치하지 않는다.
    for name in ("node_modules", "web/node_modules"):
        source = repo / name
        if source.exists():
            (snapshot / name).symlink_to(source, target_is_directory=True)
    debug = snapshot / "src/platform/macos/app_session/debug_fixtures.zig"
    debug.write_text(debug.read_text() + "\n" + (repo / "tools/shared-restore-app/fixture.zig.inc").read_text())
    session = snapshot / "src/platform/macos/app_session.zig"
    session.write_text(replace_once(session.read_text(),
        "        debug_fixtures.maybeDebugOpenNativeEditor(self);",
        "        debug_fixtures.maybeDebugOpenNativeEditor(self);\n        debug_fixtures.sharedRestoreObserve(self);"))
    host = snapshot / "src/platform/macos/MaruAppHost.swift"
    text = replace_once(host.read_text(), "        maybeRunEditorIMESmoke()\n",
                        "        maybeRunEditorIMESmoke()\n        maybeRunSharedRestore()\n")
    text = replace_once(text, '        smokeMode && ProcessInfo.processInfo.environment["MARU_EDITOR_IME_SMOKE"] == "1"',
                        '        (smokeMode || isEditorRecoveryCheckpointTest) && ProcessInfo.processInfo.environment["MARU_EDITOR_IME_SMOKE"] == "1"')
    text = replace_once(text, "        if driver.finished {\n            if !driver.failures.isEmpty { exitCode = 1 }",
                        "        if driver.finished {\n            bypassQuitConfirm = true\n            _ = sharedRestoreFixtureStep(30)\n            if !captureSharedRestore(\"ime-committed\") { exitCode = 1 }\n            if !driver.failures.isEmpty { exitCode = 1 }")
    host.write_text(text + "\n" + (repo / "tools/shared-restore-app/driver.swift.inc").read_text())
    renderer = snapshot / "src/platform/macos/maru_metal_renderer.m"
    renderer.write_text(replace_once(renderer.read_text(), "    static const char *const gates[] = {",
        '    static const char *const gates[] = {\n        "MARU_SHARED_RESTORE_CAPTURE",'))
    # 기존 실제 두벌식 드라이버를 같은 pane의 탭 대신 좌우 pane에서 실행한다.
    text = replace_once(debug.read_text(), "const peer = editor_ops.openSharedViewInActivePane(self, source) catch return;",
                        "const peer = pane_ops.splitSharedEditorPane(self, .horizontal, false) catch return;")
    start = text.index("            const pane = pane_ops.activePane(self);", text.index('getenv("MARU_EDITOR_IME_LATE_FOCUS")'))
    end = text.index('            std.debug.print("[IME_FIXTURE]', start)
    text = text[:start] + "            _ = self.activateSurfaceById(source.surfaceId());\n" + text[end:]
    debug.write_text(text)
    ime = snapshot / "src/platform/macos/EditorIMESmokeDriver.swift"
    text = replace_once(ime.read_text(), "beginLateSwitch(code: 30,", "beginLateSwitch(code: 124,")
    text = replace_once(text, "beginLateSwitch(code: 33,", "beginLateSwitch(code: 123,")
    ime.write_text(text)


def run(app, root, phase, document, *, first=False, ime=False, callbacks=False, wait_lsp=False):
    output = root / phase
    output.mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith("MARU_")}
    env.update(HOME=str(root / "home"), CFFIXED_USER_HOME=str(root / "home"),
        XDG_CONFIG_HOME=str(root / "home/.config"), XDG_CACHE_HOME=str(root / "cache"),
        XDG_STATE_HOME=str(root / "state"), MARU_CONFIG=str(root / "config"),
        MARU_SESSION_HOST_ROOT=str(root / "host"), MARU_EDITOR_BACKUP_ROOT=str(root / "backups"),
        MARU_EDITOR_RECOVERY_CHECKPOINT_TEST="maru-test-only-v1", MARU_MACOS_APP_SMOKE_MS="45000",
        MARU_SHARED_RESTORE_PHASE="ime" if ime or callbacks else phase, MARU_SHARED_RESTORE_OUTPUT=str(output),
        MARU_SHARED_RESTORE_CAPTURE="1", MARU_FT_WINDOW_SIZE="960x600",
        MARU_APP_SUMMARY_PATH=str(output / "summary.txt"))
    if phase == "seed" or ime or callbacks:
        env["MARU_NATIVE_EDITOR"] = str(document)
    if first:
        env["MARU_SCREENSHOT"] = str(output / "first.ppm")
    if wait_lsp:
        env["MARU_SHARED_RESTORE_WAIT_LSP"] = "1"
    if ime or callbacks:
        env.update(MARU_IME_DEBUG="1", MARU_EDITOR_IME_SMOKE="1", MARU_EDITOR_IME_SMOKE_LIVE="1" if ime else "0",
            MARU_EDITOR_IME_LATE_FOCUS="1", MARU_EDITOR_IME_SMOKE_OUT=str(output / "ime.txt"),
            MARU_SESSION_HOST_CR6C_ARTIFACT_ROOT=str(output))
    restorer = None
    if ime:
        # 앱이 강제 종료돼도 입력 소스의 원래 소유권을 정산한다. 사용자가 다른 소스로
        # 바꾼 경우에는 기존 정책 helper가 그 선택을 덮지 않는다.
        restorer = output / "restore-input-source"
        source = app.parents[4] / "src/platform/macos"
        subprocess.run(["xcrun", "swiftc", str(source / "SessionHostInputSourcePolicy.swift"),
                        str(source / "SessionHostInputSourceRestore.swift"), "-o", str(restorer)],
                       check=True, timeout=60)
    with (output / "app.stderr.txt").open("wb") as log:
        child = subprocess.Popen([str(app)], env=env, stdout=log, stderr=log, start_new_session=True)
        try:
            code = child.wait(timeout=65)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
            raise
        finally:
            if restorer:
                subprocess.run([str(restorer), str(output / "input-source.json")],
                               stdout=log, stderr=log, check=True, timeout=15)
    transcript = (output / "app.stderr.txt").read_text()
    assert code == 0 and "SHARED_RESTORE_ERROR" not in transcript, (phase, code, str(output))
    if not first and not ime and not callbacks:
        assert "SHARED_RESTORE_FINISH success=true" in transcript, str(output)
    if ime or callbacks:
        assert "failure_count=0\n" in (output / "ime.txt").read_text(), str(output)
        assert document.read_bytes() == ("L가 R나" if ime else "cat cat").encode()
    images = []
    for ppm in output.glob("*.ppm"):
        png = ppm.with_suffix(".png")
        subprocess.run(["sips", "-s", "format", "png", str(ppm), "--out", str(png)], check=True, capture_output=True)
        images.append(dict(path=str(png), sha256=sha(png)))
    assert images, str(output)
    states = [dict(re.findall(r"(\w+)=(\S+)", line.split("SHARED_RESTORE ", 1)[1]))
              for line in transcript.splitlines() if "SHARED_RESTORE label=" in line]
    result = dict(phase=phase, pid=child.pid, exit_code=code, states=states, images=images)
    (output / "result.json").write_text(json.dumps(result, indent=2, ensure_ascii=False))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--app", type=Path, help="이미 빌드한 이 하네스의 실행 파일")
    parser.add_argument("--live-ime", action="store_true")
    parser.add_argument("--only-ime", action="store_true", help="작은/큰 파일 검증을 생략하고 실제 IME와 재시작만 실행")
    parser.add_argument("--callback-ime", action="store_true", help="OS 입력기 대신 실제 NSTextInputClient 콜백만 주입해 재시작 확인")
    parser.add_argument("--clangd", type=Path, help="실제 clangd 실행 파일로 C 문서 복원 검사. 서버 시작을 1초 늦춘다")
    args = parser.parse_args()
    if args.clangd and (args.live_ime or args.only_ime or args.callback_ime):
        parser.error("clangd와 IME 시나리오는 별도로 실행합니다")
    repo = Path(__file__).resolve().parents[2]
    output = (args.output or Path(tempfile.mkdtemp(prefix="maru-shared-restore-app-"))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("새 빈 디렉터리가 필요합니다")
    print(output, flush=True)
    if args.app:
        app = args.app.resolve()
    else:
        snapshot = output / "snapshot"
        prepare(repo, snapshot)
        with (output / "build.log").open("w") as log:
            subprocess.run(["mise", "exec", "--", "zig", "build", "macos-app-bundle", "-j2"],
                           cwd=snapshot, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=900)
        app = snapshot / "zig-out/Maru.app/Contents/MacOS/maru-macos-app"
    source = app.parents[4]
    names = ("src/platform/macos/app_session/editor/mod.zig", "src/platform/macos/app_session/editor/restore.zig",
             "src/platform/macos/app_session/debug_fixtures.zig", "src/platform/macos/MaruAppHost.swift",
             "src/platform/macos/EditorIMESmokeDriver.swift", "src/platform/macos/maru_metal_renderer.m")
    report = dict(app=str(app), app_sha256=sha(app), runner_sha256=sha(Path(__file__)),
                  source_sha256={n: sha(source / n) for n in names}, scenarios=[], issues=[],
                  scope="실제 AppKit 프로세스와 제품 workspace/Metal 경로. 초기 상태와 관측기는 소스 사본에만 주입.")
    if args.clangd:
        server = args.clangd.resolve()
        version = subprocess.check_output([str(server), "--version"], text=True, timeout=10)
        shim = output / "bin"
        shim.mkdir()
        launcher = shim / "clangd"
        # 시작 시각만 늦춘다. initialize/문서/접힘의 요청·응답은 실제 서버가 처리한다.
        launcher.write_text("#!/bin/sh\nsleep 1\nexec " + shlex.quote(str(server)) +
                            " --log=verbose --compile-commands-dir=" + shlex.quote(str(output)) +
                            ' "$@" 2>>' + shlex.quote(str(output / "clangd.log")) + "\n")
        launcher.chmod(0o700)
        os.environ["PATH"] = str(shim) + os.pathsep + os.environ["PATH"]
        report["language_server"] = dict(path=str(server), version=version, sha256=sha(server),
                                         startup_delay_ms=1000, launcher_sha256=sha(launcher))
    scenes = (("clangd", 100),) if args.clangd else (("small", 100), ("large", 2000))
    for name, blocks in (() if args.only_ime or args.callback_ime else scenes):
        root = output / name
        root.mkdir()
        (root / "home").mkdir()
        (root / "backups").mkdir(mode=0o700)
        (root / "config").write_text("session.keep-alive-after-quit = false\n")
        if args.clangd:
            # 생성한 C 문서 디렉터리만 격리 config의 신뢰 목록에 넣는다.
            (root / "lsp-trust").write_text(f"allow\t{root}\n")
        document = root / ("sample.c" if args.clangd else "sample.zig")
        document.write_text("".join(f"// marker-{i:05d} " + "abcdefghij" * 52 +
            (f"\nint sample{i}(void) {{\n    int value = {i};\n    return value;\n}}\n" if args.clangd else
             f"\npub fn sample{i}() void {{\n    const value = {i};\n    _ = value;\n}}\n") for i in range(blocks)))
        original = document.read_bytes()
        for phase in ("seed", "first", "restore"):
            report["scenarios"].append(dict(name=name, **run(app, root, phase, document,
                first=phase == "first", wait_lsp=args.clangd is not None)))
        report["issues"].extend(compare_states(name, [s for s in report["scenarios"] if s["name"] == name]))
        assert document.read_bytes() == original
        assert len(list((root / "backups").glob("*.bak"))) == 1
    if args.live_ime or args.only_ime or args.callback_ime:
        name = "callbacks" if args.callback_ime else "korean"
        root = output / name
        root.mkdir()
        (root / "home").mkdir()
        (root / "backups").mkdir(mode=0o700)
        (root / "config").write_text("session.keep-alive-after-quit = false\n")
        document = root / "document.txt"
        document.write_text("ab😀한cd" if args.callback_ime else "L R")
        report["scenarios"].append(dict(name=name, **run(app, root, "ime", document, ime=not args.callback_ime, callbacks=args.callback_ime)))
        report["scenarios"].append(dict(name=name, **run(app, root, "restore", document)))
        report["issues"].extend(compare_states(name, [s for s in report["scenarios"] if s["name"] == name]))
        report["ime_input"] = "native-callback-injection" if args.callback_ime else "OS-Korean-HID"
    report["view_restore_gate_passed"] = not report["issues"]
    (output / "manifest.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(output / "manifest.json", flush=True)
    if report["issues"]:
        print(json.dumps(report["issues"], indent=2, ensure_ascii=False))
        sys.exit(1)


if __name__ == "__main__":
    main()
