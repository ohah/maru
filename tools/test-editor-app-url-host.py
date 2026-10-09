#!/usr/bin/env python3
"""Execute the actual Swift URL drain body with controlled OS/ABI boundaries.

Checks target scoping, denied IME admission, burst budget, startup/quit/reentry.
This is host effect coverage; it does not claim real LaunchServices delivery.
"""
from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    source = (root/'src/platform/macos/MaruAppHost.swift').read_text()
    start = source.index('    private func drainEditorURLs() {')
    end = source.index('\n    }', start)+len('\n    }')
    body = source[start:end]
    stubs = r'''
var queue = 0
var ready = true
var scope: Int? = nil
var calls: [(Int?, UInt8)] = []
func maru_macos_editor_url_pending() -> UInt32 { ready ? UInt32(queue) : 0 }
func maru_macos_editor_url_drain(_ session: Int?, _ admitted: UInt8) -> UInt32 {
    precondition(queue > 0)
    queue -= 1
    calls.append((session, admitted))
    return admitted == 1 && session != nil ? 1 : 2
}
final class App {
    func activate(ignoringOtherApps: Bool) {}
}
let NSApp = App()
final class Window {
    var isKeyWindow = false
    func makeKeyAndOrderFront(_ sender: Any?) {}
    func makeFirstResponder(_ view: View) {}
}
final class View {
    let owner: Int
    var allowed = true
    var onCommit: (() -> Void)?
    init(_ owner: Int) { self.owner = owner }
    func commitMarkedTextIfComposing() -> Bool {
        precondition(scope == owner, "wrong session for composition admission")
        onCommit?()
        return allowed
    }
}
final class Surface {
    let window: Window? = Window()
    let view: View?
    let appSession: Int?
    init(_ id: Int) { appSession = id; view = View(id) }
}
final class Controller {
    var windows: [Surface] = []
    var primary: Surface? { windows.first }
    var drainingEditorURLs = false
    var quitConfirmPending = false
    var workspaceFinalQuitApproved = false
    func withSurface(_ surface: Surface?, _ body: () -> Void) {
        let previous = scope; scope = surface?.appSession
        defer { scope = previous }
        body()
    }
    func run() { drainEditorURLs() }
'''
    checks = r'''
}
let a = Surface(10), b = Surface(20)
let controller = Controller(); controller.windows = [a,b]
b.window!.isKeyWindow = true
queue = 6; controller.run()
precondition(calls.count == 4 && queue == 2)
precondition(calls.allSatisfy { $0.0 == 20 && $0.1 == 1 })
precondition(scope == nil)
controller.run(); precondition(queue == 0 && calls.count == 6)
calls = []; queue = 1; b.window!.isKeyWindow = false; a.view!.allowed = false
controller.run(); precondition(queue == 0 && calls.count == 1)
precondition(calls[0].0 == 10 && calls[0].1 == 0)
calls = []; queue = 1; controller.quitConfirmPending = true
controller.run(); precondition(queue == 1 && calls.isEmpty)
controller.quitConfirmPending = false; ready = false
controller.run(); precondition(queue == 1 && calls.isEmpty)
ready = true; a.view!.allowed = true
a.view!.onCommit = { controller.run() }
controller.run(); precondition(queue == 0 && calls.count == 1)
calls = []; queue = 1; controller.windows = []
controller.run(); precondition(queue == 0 && calls.count == 1 && calls[0].0 == nil && calls[0].1 == 0)
print("editor_url_host_effects=passed")
'''
    with tempfile.TemporaryDirectory(prefix='maru-url-host-') as temporary:
        temp = Path(temporary)
        swift = temp/'host.swift'
        swift.write_text(stubs+body+checks)
        subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(temp/'module-cache'),
                        str(swift), '-o', str(temp/'host')], check=True, timeout=60)
        subprocess.run([str(temp/'host')], check=True, timeout=15)


if __name__ == '__main__':
    main()
