#!/usr/bin/env python3
"""Run the actual Swift quit/close/reopen methods against isolated host stubs.

Covers how the app-level quit paths combine: the zero-window Dock app (LW1 —
`window.quit-after-last-window-closed = false`), downloads keeping the app alive
(W10c/W10e) and page dialogs held for exit (W6k). These were written on two
branches and merged by hand (2026-10-11 rebase onto main); the adversarial review
found the merge dropped or crossed rules that no single-branch test saw.

This is not an AppKit test: windows, sessions, the checkpoint state machine and
ABI calls are stubs. It proves only what these Swift bodies decide. Bodies are
extracted from the repository's current Swift source (never copied); a missing or
duplicated declaration fails before compilation. `--source` runs an explicit
snapshot (a mutation or an older revision) without editing product files.
"""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

METHODS = [
    "    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {",
    "    private func closeWindowOrQuit(",
    "    private func cancelFinalWorkspaceCheckpoint() {",
    "    private func holdOsrDialogsForExit() {",
    "    private func releaseQuitConfirmHeld(by surface: TerminalSurface) {",
    "    func applicationShouldHandleReopen(",
    "    private func openWindowIfNoneOpen() -> Bool {",
    "    private func enterOpenWithoutWindows() {",
]


def extract(source, marker):
    count = source.count(marker)
    if count != 1:
        raise SystemExit(f"FAIL: expected one «{marker.strip()}», found {count}")
    start = source.index(marker)
    end = source.index("\n    }\n", start) + len("\n    }\n")
    # 시험 본문이 부를 수 있게 접근 제한만 뗀다(본문은 그대로).
    return source[start:end].replace("    private func ", "    func ", 1)


STUBS = r'''
import Foundation
final class NSApplication {
    enum TerminateReply { case terminateCancel, terminateNow, terminateLater }
    var replies: [Bool] = []
    var terminates = 0
    func reply(toApplicationShouldTerminate value: Bool) { replies.append(value) }
    func terminate(_ sender: Any?) { terminates += 1 }
    func activate(ignoringOtherApps flag: Bool) {}
}
let NSApp = NSApplication()
final class Window {
    var isVisible = true
    var isKeyWindow = true
    var delegate: AnyObject?
    var closed = 0
    var ordered = 0
    func close() { closed += 1 }
    func orderOut(_ sender: Any?) { ordered += 1 }
}
final class TerminalSurface {
    var window: Window? = Window()
    var appSession: UnsafeMutableRawPointer? = UnsafeMutableRawPointer(bitPattern: 8)
    var token = 1
}
final class Timer { func invalidate() {} }
var downloadsMoving: UInt32 = 0
var quitRequests = 0
var quitCancels = 0
func maru_macos_downloads_keep_alive() -> UInt32 { downloadsMoving }
func maru_macos_app_session_request_app_quit(_ session: UnsafeMutableRawPointer) { quitRequests += 1 }
func maru_macos_app_session_cancel_app_quit(_ session: UnsafeMutableRawPointer) { quitCancels += 1 }

final class Host {
    var osrQuitRequested = false
    var smokeMode = false
    var appLaunchFirstDrawableArmed = false
    var workspaceFinalQuitPending = false
    var workspaceFinalQuitWasDeferred = false
    var workspaceFinalQuitAllowsFailure = false
    var workspaceFinalQuitApproved = false
    var workspaceFinalQuitSurface: TerminalSurface?
    var workspaceCheckpointArmed = true
    var quitConfirmPending = false
    weak var quitConfirmSurface: TerminalSurface?
    var bypassQuitConfirm = false
    var osrDialogsHeldForExit = false
    var windows: [TerminalSurface] = []
    var keepAliveSurfaces: [TerminalSurface] = []
    var keepAliveZeroSince: Double? = 1
    var openWithoutWindows = false
    var quick: TerminalSurface?
    var activeSurface: TerminalSurface? { windows.first }
    var tickTimer: Timer? = Timer()
    var smokeTimer: Timer?
    var quitsAfterLast = true
    // 관찰
    var sheetsDismissed = 0
    var finalBegins: [TerminalSurface?] = []
    var finalFinishes = 0
    var created: [TerminalSurface] = []
    var torn: [TerminalSurface] = []
    var keepAliveActivity = 0

    func finishProjectSearchBeforeTermination() -> NSApplication.TerminateReply { .terminateNow }
    func dismissOsrSheetsForQuit() { sheetsDismissed += 1 }
    func beginFinalWorkspaceCheckpoint(surface: TerminalSurface?, deferredAppKitQuit: Bool) {
        finalBegins.append(surface)
        workspaceFinalQuitPending = true
        workspaceFinalQuitSurface = surface
        workspaceFinalQuitWasDeferred = deferredAppKitQuit
    }
    func finishFinalWorkspaceCheckpoint() { finalFinishes += 1; workspaceFinalQuitPending = false }
    func bringSurfaceForward(_ surface: TerminalSurface) {}
    func protectedFilePanelSurface() -> TerminalSurface? { nil }
    func createTerminalWindow(applyingWorkspace: Any?) -> TerminalSurface? {
        let s = TerminalSurface()
        created.append(s)
        windows.append(s)
        return s
    }
    func withSurface(_ surface: TerminalSurface, _ body: () -> Void) { body() }
    func reconcileWebFocus() {}
    func holdProtectedSurfaceAfterTickFailure(_ surface: TerminalSurface) -> Bool { false }
    func quitsAfterLastWindowClosed(_ surface: TerminalSurface) -> Bool { quitsAfterLast }
    func blockGlobalTerminationForProtectedFilePanels() -> Bool { false }
    // 실제 teardown 의 첫 줄과 끝(`releaseQuitConfirmHeld` → … → `windows` 에서 뺀다)만 흉내 낸다.
    func teardownWindowSurface(_ surface: TerminalSurface, checkpointRemovalAlreadyCovered: Bool = false) {
        releaseQuitConfirmHeld(by: surface)
        torn.append(surface)
        windows.removeAll { $0 === surface }
    }
    func beginKeepAliveActivity() { keepAliveActivity += 1 }
    func loadQuickTerminalConfig() -> Bool { true }
@@METHODS@@
}

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if !condition() { fputs("FAIL: " + name + "\n", stderr); exit(1) }
    checks += 1
}
func reset() { NSApp.replies = []; NSApp.terminates = 0; downloadsMoving = 0; quitRequests = 0; quitCancels = 0 }

// ① 이미 정해진 마지막 저장에 ⌘Q 가 합류한 뒤 그 저장이 취소되면(keep-alive 종료의 저장 실패 — allowsFailure=false) 종료를 그만둔다.
//    그때 페이지 대화상자를 영영 보류하면 안 된다(보류는 되돌리지 않는다 — 대화상자가 다시는 뜨지 않았다).
do {
    reset()
    let h = Host(); let s = TerminalSurface(); h.windows = [s]
    h.beginFinalWorkspaceCheckpoint(surface: s, deferredAppKitQuit: false) // 인앱 확인 수락으로 시작된 마지막 저장
    check(h.applicationShouldTerminate(NSApp) == .terminateLater, "joined quit waits")
    check(h.quitConfirmPending && h.workspaceFinalQuitWasDeferred, "joined quit is the deferred reply")
    check(h.sheetsDismissed >= 1, "joined quit clears open page dialogs")
    h.workspaceFinalQuitAllowsFailure = false
    h.cancelFinalWorkspaceCheckpoint()
    check(NSApp.replies == [false] && !h.quitConfirmPending, "a cancelled save answers the joined quit with no")
    check(!h.osrDialogsHeldForExit, "a cancelled quit does not hold page dialogs forever")
}
// ② 확인 모달이 떠 있는 마지막 창의 셸이 끝나고 받는 중이면 창을 숨겨 쥔다 — 그 모달의 종료 보류에 답해야 한다(숨긴 세션은 tick 이 없다).
do {
    reset()
    let h = Host(); let s = TerminalSurface(); h.windows = [s]
    check(h.applicationShouldTerminate(NSApp) == .terminateLater && h.quitConfirmPending && h.quitConfirmSurface === s, "quit asks in the window")
    downloadsMoving = 1
    h.closeWindowOrQuit(s, faulted: false, sessionEnded: true)
    check(h.keepAliveSurfaces.count == 1 && h.windows.isEmpty && s.window!.ordered == 1, "downloads keep the hidden window")
    check(!h.quitConfirmPending && NSApp.replies == [false], "the hidden window's quit confirmation is answered, not left pending")
    check(quitCancels == 1, "the hidden session's accepted-quit flags are cancelled in Zig too (its tick no longer runs)")
    check(NSApp.terminates == 0, "the app stays while downloading")
}
// ③ 창 0 개로 Dock 에 남은 앱(LW1)의 ⌘Q — 받는 중이면 확인 없이 끝내지 않고 새 창에서 묻는다(받던 것이 말없이 취소됐다).
do {
    reset()
    let h = Host(); h.openWithoutWindows = true; downloadsMoving = 2
    check(h.applicationShouldTerminate(NSApp) == .terminateLater, "zero-window quit waits")
    check(h.created.count == 1 && h.quitConfirmSurface === h.created.first && quitRequests == 1, "downloading: a new window asks before quitting")
    check(h.finalBegins.isEmpty, "downloading: no confirmation-free final save")
    reset()
    let idle = Host(); idle.openWithoutWindows = true
    check(idle.applicationShouldTerminate(NSApp) == .terminateLater, "idle zero-window quit waits for the final save")
    check(idle.created.isEmpty && idle.finalBegins.count == 1 && idle.finalBegins[0] == nil && quitRequests == 0, "idle: quits without asking (only the final save)")
    reset()
    let kept = Host(); kept.keepAliveSurfaces = [TerminalSurface()]; downloadsMoving = 1
    check(kept.applicationShouldTerminate(NSApp) == .terminateLater && kept.created.count == 1 && quitRequests == 1, "W10e hidden window: a new window asks")
}
// ④ Dock 클릭 — 창 0 개 앱(LW1)은 새 창, 받느라 남은 앱(W10e)도 새 창, 창이 있으면 AppKit 기본.
do {
    reset()
    let h = Host(); h.openWithoutWindows = true
    check(h.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true) == false && h.created.count == 1, "zero-window app: Dock click opens a window")
    let k = Host(); k.keepAliveSurfaces = [TerminalSurface()]
    check(k.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false) == false && k.created.count == 1, "kept alive for downloads: Dock click opens a window")
    // 전역 단축키(show/toggle_window)는 `openWindowIfNoneOpen` 만 본다 — Dock 과 같은 판정이어야 한다.
    let g = Host(); g.keepAliveSurfaces = [TerminalSurface()]
    check(g.openWindowIfNoneOpen() && g.created.count == 1, "kept alive for downloads: the global hotkey path opens a window")
    let w = Host(); w.windows = [TerminalSurface()]
    check(w.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true) == true && w.created.isEmpty, "with a window: AppKit default")
}
print("quit_host_checks=\(checks) passed")
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, help="Swift source snapshot (default: the repository's MaruAppHost.swift)")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    path = args.source or root / "src/platform/macos/MaruAppHost.swift"
    source = path.read_text(encoding="utf-8")
    methods = "\n".join(extract(source, m) for m in METHODS)
    program = STUBS.replace("@@METHODS@@", methods)
    with tempfile.TemporaryDirectory(prefix="maru-quit-host-") as temporary:
        temp = Path(temporary)
        swift = temp / "host.swift"
        swift.write_text(program, encoding="utf-8")
        subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(temp / "module-cache"), str(swift), "-o", str(temp / "host")], check=True, timeout=120)
        result = subprocess.run([str(temp / "host")], timeout=15)
        sys.exit(result.returncode)


if __name__ == "__main__":
    main()
