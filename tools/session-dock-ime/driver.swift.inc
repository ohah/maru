// Appended to the private MaruAppHost.swift copy. Input uses normal NSView/TSM routes;
// the Zig witness only reads state and cannot activate a search or edit a query.
import CryptoKit

@_silgen_name("maru_session_dock_ime_witness")
private func dockIMEWitness(_ field: UInt32) -> UInt64

@MainActor
private enum DockIMECallbackWitness { static var committed: UInt64 = 0 }

@MainActor
private enum DockIMERun {
    static var step = 0
    static var next = 0.0
    static let started = ProcessInfo.processInfo.systemUptime
    static var finished = false
    static var baselineBytes: UInt64 = 0
    static var baselineCards: UInt64 = 0
    static var terminalAnchor = NSRect.zero
    static var emptyAnchor = NSRect.zero
    static var observations: [[String: Any]] = []
    static var geometries: [[String: Double]] = []
    static var originalGlobal: String?
    static var originalView: String?
    static var candidateBefore: SessionHostIMECandidateObservation.Snapshot?
    static var candidateOpened: SessionHostIMECandidateObservation.Snapshot?
    static let candidateObserver = SessionHostIMECandidateObservation()
    static var candidateCount = 0
    static var candidateDeadline = 0.0
    static var liveKey = 0
}

extension MaruAppHostController {
    private var dockIMERoot: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MARU_AGENT_SESSION_ARCHIVE_SMOKE_ARTIFACT_DIR"]!)
    }
    private func dockIMERequire(_ condition: Bool, _ reason: String) throws {
        if !condition { throw NSError(domain: "SessionDockIME", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
    }
    private func dockIMEHash(_ text: String) -> UInt64 {
        let bytes = Array(SHA256.hash(data: Data(text.utf8)))
        return bytes.prefix(8).enumerated().reduce(0) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
    }
    private func dockIMEState(_ name: String, view: MaruMetalTerminalView, window: NSWindow) {
        DockIMERun.observations.append([
            "name": name, "step": DockIMERun.step, "first_responder": window.firstResponder === view,
            "search_active": dockIMEWitness(1), "dock_focus": dockIMEWitness(2), "search_owner": dockIMEWitness(3),
            "query_bytes": dockIMEWitness(4), "query_hash": String(dockIMEWitness(5)),
            "preedit_bytes": dockIMEWitness(6), "preedit_hash": String(dockIMEWitness(7)),
            "cards": dockIMEWitness(8), "terminal_bytes": dockIMEWitness(9),
            "has_marked": view.hasMarkedText()
        ])
    }
    private func dockIMEText(query: String, preedit: String) throws {
        try dockIMERequire(dockIMEWitness(4) == query.utf8.count && dockIMEWitness(5) == dockIMEHash(query), "committed_query")
        try dockIMERequire(dockIMEWitness(6) == preedit.utf8.count && dockIMEWitness(7) == dockIMEHash(preedit), "preedit")
    }
    private func dockIMEProbe(_ target: UInt32, session: OpaquePointer) -> MaruAppHostAgentSessionArchiveSmokeProbe? {
        var value = MaruAppHostAgentSessionArchiveSmokeProbe()
        guard maru_macos_app_session_agent_session_archive_smoke_probe(session, target, &value) == Self.statusOK,
              value.present != 0, value.enabled != 0 else { return nil }
        return value
    }
    private func dockIMEKey(_ code: UInt16, _ chars: String, view: MaruMetalTerminalView, window: NSWindow) throws {
        try dockIMERequire(dispatchSessionHostInputKey(keyCode: code, characters: chars, modifiers: [], view: view, window: window), "NSView_key")
    }
    private func dockIMEHID(_ code: UInt16, view: MaruMetalTerminalView, window: NSWindow, flags: CGEventFlags = []) throws {
        try dockIMERequire(CGPreflightPostEventAccess(), "event_permission")
        try dockIMERequire(NSApp.isActive && window.firstResponder === view &&
            NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), "HID_keyboard_owner")
        try dockIMERequire(SessionHostInputSourcePolicy.currentSourceID() == SessionHostInputSourcePolicy.korean2SetSourceID &&
            view.inputContext?.selectedKeyboardInputSource == SessionHostInputSourcePolicy.korean2SetSourceID, "HID_input_source")
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw NSError(domain: "HID_creation", code: 1)
        }
        down.flags = flags; up.flags = flags
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
    private func dockIMEClickTerminal(view: MaruMetalTerminalView, window: NSWindow) throws {
        let anchor = DockIMERun.terminalAnchor
        let point = window.convertPoint(fromScreen: NSPoint(x: anchor.midX, y: anchor.midY))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { throw NSError(domain: "pointer", code: 1) }
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
    }
    private func dockIMEAnchor(view: MaruMetalTerminalView, window: NSWindow, session: OpaquePointer) throws -> NSRect {
        guard let probe = dockIMEProbe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_SEARCH, session: session) else { throw NSError(domain: "search_rect", code: 1) }
        let scale = archiveSmokeRenderScale(window)
        let local = NSRect(x: CGFloat(probe.x_px) / scale,
            y: view.bounds.height - CGFloat(probe.y_px + probe.height_px) / scale,
            width: CGFloat(probe.width_px) / scale, height: CGFloat(probe.height_px) / scale)
        let field = window.convertToScreen(view.convert(local, to: nil))
        let anchor = view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil)
        DockIMERun.geometries.append(["step": Double(DockIMERun.step), "x": anchor.minX, "y": anchor.minY,
            "w": anchor.width, "h": anchor.height, "field_x": field.minX, "field_y": field.minY,
            "field_w": field.width, "field_h": field.height])
        try dockIMERequire(anchor.width > 0 && anchor.height > 0 && field.insetBy(dx: -1, dy: -1).contains(anchor), "caret_outside_published_search")
        return anchor
    }
    private func dockIMECapture(_ name: String, surface: TerminalSurface) throws {
        guard let renderer = surface.metalRenderer else { throw NSError(domain: "renderer", code: 1) }
        let path = dockIMERoot.appendingPathComponent("captures/\(name).ppm")
        try dockIMERequire(!FileManager.default.fileExists(atPath: path.path) && maru_metal_renderer_request_test_capture(renderer, path.path), "capture_request")
        metalNeedsRedraw = true
        _ = renderTick()
        try dockIMERequire(FileManager.default.fileExists(atPath: path.path), "capture_missing")
    }
    private func dockIMEFinish(_ failure: String?, view: MaruMetalTerminalView?) {
        guard !DockIMERun.finished else { return }
        DockIMERun.finished = true
        var failures = failure.map { [$0] } ?? []
        if let original = DockIMERun.originalGlobal {
            let current = SessionHostInputSourcePolicy.currentSourceID()
            let currentView = view?.inputContext?.selectedKeyboardInputSource
            if SessionHostInputSourcePolicy.permitsViewRestoration(currentGlobal: current, originalGlobal: original,
                currentView: currentView, originalView: DockIMERun.originalView) {
                if let context = view?.inputContext, let source = DockIMERun.originalView {
                    context.deactivate(); context.selectedKeyboardInputSource = source; context.activate()
                }
                let result = SessionHostInputSourcePolicy.restore(recordURL: dockIMERoot.appendingPathComponent("input-source.json"))
                if result != .restored { failures.append("input_source_restore_\(result)") }
            } else {
                // Revoke disk restoration too; a concurrent user source change owns the keyboard.
                try? FileManager.default.removeItem(at: dockIMERoot.appendingPathComponent("input-source.json"))
                failures.append("input_source_superseded")
            }
        }
        let report: [String: Any] = ["schema": "maru.session-dock-ime.v1", "mode": ProcessInfo.processInfo.environment["MARU_SESSION_DOCK_IME"]!,
            "passed": failures.isEmpty, "failures": failures, "step": DockIMERun.step,
            "observations": DockIMERun.observations, "geometry": DockIMERun.geometries, "candidate_count": DockIMERun.candidateCount]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: dockIMERoot.appendingPathComponent("result.json"), options: .atomic)
        } catch { failures.append("report_write") }
        if !failures.isEmpty { exitCode = 1; fputs("SESSION_DOCK_IME failed: \(failures)\n", stderr) }
        bypassQuitConfirm = true
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
    private func tickSessionDockIME() {
        guard !DockIMERun.finished, let surface = primary, let session = surface.appSession,
              let view = surface.view, let window = surface.window else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - DockIMERun.started < 100 else { dockIMEFinish("timeout_\(DockIMERun.step)", view: view); return }
        guard now >= DockIMERun.next else { return }
        DockIMERun.next = now + 0.2
        withSurface(surface) {
            do {
                try dockIMERequire(dockIMEWitness(0) == 1, "witness_missing")
                switch DockIMERun.step {
                case 0:
                    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                    guard NSApp.isActive && window.firstResponder === view else { return }
                    DockIMERun.terminalAnchor = view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil)
                    guard let p = dockIMEProbe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_DOCK_LAUNCHER, session: session) else { return }
                    try dockIMERequire(dispatchArchiveSmokeClick(p, in: view, window: window), "open_dock")
                    DockIMERun.step = 1
                case 1:
                    guard let p = dockIMEProbe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_DOCK_AGENT_SESSIONS, session: session) else { return }
                    try dockIMERequire(dispatchArchiveSmokeClick(p, in: view, window: window), "open_sessions")
                    DockIMERun.step = 2
                case 2:
                    guard dockIMEProbe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_DOCK_CARD, session: session) != nil else { return }
                    try dockIMERequire(dockIMEWitness(1) == 0 && dockIMEWitness(2) == 0, "view_switch_must_not_own_search")
                    DockIMERun.terminalAnchor = view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil)
                    DockIMERun.baselineBytes = dockIMEWitness(9)
                    DockIMERun.baselineCards = dockIMEWitness(8)
                    dockIMEState("view_switch", view: view, window: window)
                    // Direct committed callback is a routing control, not a physical-key claim.
                    view.insertText("/", replacementRange: NSRange(location: NSNotFound, length: 0))
                    DockIMERun.step = 3
                case 3:
                    try dockIMEText(query: "", preedit: "")
                    try dockIMERequire(dockIMEWitness(9) == DockIMERun.baselineBytes + 1, "terminal_slash_control")
                    guard let p = dockIMEProbe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_SEARCH, session: session) else { return }
                    try dockIMERequire(dispatchArchiveSmokeClick(p, in: view, window: window), "search_click")
                    DockIMERun.baselineBytes = dockIMEWitness(9)
                    DockIMERun.step = 4
                case 4:
                    try dockIMERequire(window.firstResponder === view && dockIMEWitness(1) == 1 && dockIMEWitness(3) == 1, "search_focus")
                    DockIMERun.emptyAnchor = try dockIMEAnchor(view: view, window: window, session: session)
                    dockIMEState("search_focus", view: view, window: window)
                    if ProcessInfo.processInfo.environment["MARU_SESSION_DOCK_IME"] == "live" {
                        try dockIMERequire(CGPreflightPostEventAccess(), "event_permission")
                        try dockIMERequire(CGPreflightScreenCaptureAccess(), "screen_capture_permission")
                        guard let context = view.inputContext else { throw NSError(domain: "input_context", code: 1) }
                        DockIMERun.originalView = context.selectedKeyboardInputSource
                        DockIMERun.originalGlobal = try SessionHostInputSourcePolicy.prepareKoreanSelection(recordURL: dockIMERoot.appendingPathComponent("input-source.json"))
                        context.deactivate(); context.selectedKeyboardInputSource = SessionHostInputSourcePolicy.korean2SetSourceID; context.activate()
                        DockIMERun.step = 50
                    } else {
                        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                        DockIMERun.step = 5
                    }
                case 5:
                    try dockIMEText(query: "", preedit: "한")
                    try dockIMERequire(dockIMEWitness(8) == DockIMERun.baselineCards && dockIMEWitness(9) == DockIMERun.baselineBytes, "preedit_filtered_or_leaked")
                    let anchor = try dockIMEAnchor(view: view, window: window, session: session)
                    try dockIMERequire(anchor.minX > DockIMERun.emptyAnchor.minX, "marked_caret_did_not_move")
                    dockIMEState("marked", view: view, window: window)
                    try dockIMECapture("marked", surface: surface)
                    view.insertText("한", replacementRange: NSRange(location: NSNotFound, length: 0))
                    DockIMERun.step = 6
                case 6:
                    try dockIMEText(query: "한", preedit: "")
                    try dockIMERequire(dockIMEWitness(8) == 0 && dockIMEWitness(9) == DockIMERun.baselineBytes, "commit_filter_or_terminal_leak")
                    dockIMEState("committed", view: view, window: window)
                    try dockIMECapture("committed", surface: surface)
                    try dockIMEKey(53, "\u{1b}", view: view, window: window)
                    DockIMERun.step = 7
                case 7:
                    try dockIMEText(query: "", preedit: "")
                    try dockIMERequire(dockIMEWitness(1) == 0 && dockIMEWitness(8) == DockIMERun.baselineCards, "escape_did_not_clear")
                    try dockIMEKey(44, "/", view: view, window: window)
                    DockIMERun.step = 8
                case 8:
                    try dockIMERequire(dockIMEWitness(1) == 1 && window.firstResponder === view, "owned_slash_did_not_focus_search")
                    try dockIMEText(query: "", preedit: "")
                    view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                    DockIMERun.step = 9
                case 9:
                    try dockIMEText(query: "", preedit: "한")
                    try dockIMEClickTerminal(view: view, window: window)
                    DockIMERun.step = 10
                case 10:
                    try dockIMEText(query: "한", preedit: "")
                    try dockIMERequire(dockIMEWitness(1) == 0 && dockIMEWitness(2) == 0 && dockIMEWitness(3) == 0, "search_retained_after_blur")
                    try dockIMERequire(dockIMEWitness(9) == DockIMERun.baselineBytes, "blur_committed_to_terminal")
                    view.insertText("z", replacementRange: NSRange(location: NSNotFound, length: 0))
                    DockIMERun.step = 11
                case 11:
                    try dockIMEText(query: "한", preedit: "")
                    try dockIMERequire(dockIMEWitness(9) == DockIMERun.baselineBytes + 1, "terminal_input_not_restored")
                    dockIMEState("terminal_restored", view: view, window: window)
                    try dockIMECapture("terminal-restored", surface: surface)
                    dockIMEFinish(nil, view: view)
                default:
                    try tickLiveSessionDockIME(view: view, window: window, surface: surface, session: session, now: now)
                }
                metalNeedsRedraw = true
                _ = renderTick()
            } catch {
                dockIMEState("failure", view: view, window: window)
                dockIMEFinish(error.localizedDescription, view: view)
            }
        }
    }
}

extension MaruAppHostController {
    private func dockIMECandidateSnapshot(view: MaruMetalTerminalView) throws -> SessionHostIMECandidateObservation.Snapshot {
        try DockIMERun.candidateObserver.capture(counters: .init(pty_input_bytes: dockIMEWitness(9),
            committed_text_callbacks: DockIMECallbackWitness.committed, base_screen_generation: dockIMEWitness(11)),
            anchor: view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil))
    }
    private func tickLiveSessionDockIME(view: MaruMetalTerminalView, window: NSWindow,
                                        surface: TerminalSurface, session: OpaquePointer, now: Double) throws {
        switch DockIMERun.step {
        case 50:
            guard SessionHostInputSourcePolicy.currentSourceID() == SessionHostInputSourcePolicy.korean2SetSourceID &&
                view.inputContext?.selectedKeyboardInputSource == SessionHostInputSourcePolicy.korean2SetSourceID else { return }
            try dockIMEText(query: "", preedit: "")
            try dockIMEHID(5, view: view, window: window)
            DockIMERun.step = 51
        case 51:
            try dockIMEText(query: "", preedit: "ㅎ")
            try dockIMEHID(40, view: view, window: window)
            DockIMERun.step = 52
        case 52:
            try dockIMEText(query: "", preedit: "하")
            try dockIMEHID(1, view: view, window: window)
            DockIMERun.step = 53
        case 53:
            try dockIMEText(query: "", preedit: "한")
            try dockIMERequire(dockIMEWitness(9) == DockIMERun.baselineBytes && dockIMEWitness(8) == DockIMERun.baselineCards, "live_preedit_leak_or_filter")
            _ = try dockIMEAnchor(view: view, window: window, session: session)
            dockIMEState("live_han_\(DockIMERun.candidateCount)", view: view, window: window)
            DockIMERun.candidateBefore = try dockIMECandidateSnapshot(view: view)
            try dockIMEHID(36, view: view, window: window, flags: .maskAlternate)
            DockIMERun.candidateDeadline = now + 4
            DockIMERun.step = 54
        case 54:
            guard let before = DockIMERun.candidateBefore else { throw NSError(domain: "candidate_before", code: 1) }
            let opened = try dockIMECandidateSnapshot(view: view)
            let oldIDs = Set(before.windows.map { $0.id })
            if opened.windows.allSatisfy({ oldIDs.contains($0.id) }) {
                try dockIMERequire(now < DockIMERun.candidateDeadline, "candidate_not_opened")
                return
            }
            let proven = try DockIMERun.candidateObserver.captureAppCandidate(before: before, opened: opened)
            // The shared reducer, not this driver, decides ownership, ambiguity and geometry.
            DockIMERun.candidateOpened = proven
            try dockIMEHID(53, view: view, window: window)
            DockIMERun.step = 55
        case 55:
            guard let before = DockIMERun.candidateBefore, let opened = DockIMERun.candidateOpened else { throw NSError(domain: "candidate_opened", code: 1) }
            let closed = try dockIMECandidateSnapshot(view: view)
            try DockIMERun.candidateObserver.append(before: before, opened: opened, closed: closed)
            DockIMERun.candidateCount += 1
            if DockIMERun.candidateCount == 5 {
                try DockIMERun.candidateObserver.publish(sourceID: SessionHostInputSourcePolicy.korean2SetSourceID,
                    outputURL: dockIMERoot.appendingPathComponent("candidate.json"))
                try dockIMEHID(36, view: view, window: window)
                DockIMERun.step = 58
            } else {
                try dockIMEHID(53, view: view, window: window)
                DockIMERun.step = 56
            }
        case 56:
            // Escape first cancels composition; a following Escape belongs to the search owner.
            try dockIMEHID(53, view: view, window: window)
            DockIMERun.step = 57
        case 57:
            try dockIMEText(query: "", preedit: "")
            guard let search = dockIMEProbe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_SEARCH, session: session) else { throw NSError(domain: "search_missing", code: 1) }
            try dockIMERequire(dispatchArchiveSmokeClick(search, in: view, window: window), "repeat_search_click")
            DockIMERun.step = 50
        case 58:
            try dockIMEText(query: "한", preedit: "")
            try dockIMERequire(dockIMEWitness(9) == DockIMERun.baselineBytes && dockIMEWitness(8) == 0, "live_commit_leak_or_filter")
            dockIMEState("live_committed", view: view, window: window)
            try dockIMECapture("live-committed", surface: surface)
            try dockIMEHID(53, view: view, window: window)
            DockIMERun.step = 59
        case 59:
            try dockIMEText(query: "", preedit: "")
            guard let search = dockIMEProbe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_SEARCH, session: session) else { throw NSError(domain: "search_missing", code: 1) }
            try dockIMERequire(dispatchArchiveSmokeClick(search, in: view, window: window), "blur_search_click")
            DockIMERun.step = 60
        case 60:
            try dockIMEHID(5, view: view, window: window); DockIMERun.step = 61
        case 61:
            try dockIMEHID(40, view: view, window: window); DockIMERun.step = 62
        case 62:
            try dockIMEHID(1, view: view, window: window); DockIMERun.step = 63
        case 63:
            try dockIMEText(query: "", preedit: "한")
            try dockIMEClickTerminal(view: view, window: window)
            DockIMERun.step = 64
        case 64:
            try dockIMEText(query: "한", preedit: "")
            try dockIMERequire(dockIMEWitness(1) == 0 && dockIMEWitness(2) == 0 && dockIMEWitness(9) == DockIMERun.baselineBytes, "live_blur_target")
            try dockIMEHID(44, view: view, window: window)
            DockIMERun.step = 65
        case 65:
            try dockIMEText(query: "한", preedit: "")
            try dockIMERequire(dockIMEWitness(9) == DockIMERun.baselineBytes + 1, "live_terminal_not_restored")
            dockIMEState("live_terminal_restored", view: view, window: window)
            try dockIMECapture("live-terminal-restored", surface: surface)
            dockIMEFinish(nil, view: view)
        default: throw NSError(domain: "unknown_live_step", code: DockIMERun.step)
        }
    }
}
