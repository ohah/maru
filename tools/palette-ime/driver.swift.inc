// Private-copy driver. All editing uses ordinary NSView shortcuts or guarded HID;
// the Zig witness only observes state. Candidate authority remains in the shared reducer.
import CryptoKit

@_silgen_name("maru_palette_ime_witness") private func paletteIMEWitness(_ field: UInt32) -> UInt64
@MainActor private enum PaletteIMEWitness { static var committed: UInt64 = 0 }
@MainActor private enum PaletteIMERun {
    static var step = 0
    static var next = 0.0
    static let started = ProcessInfo.processInfo.systemUptime
    static var finished = false
    static var baselineBytes: UInt64 = 0
    static var originalGlobal: String?
    static var originalView: String?
    static var observations: [[String: Any]] = []
    static var composition: [[String: Any]] = []
    static var geometry: [[String: Double]] = []
    static let observer = SessionHostIMECandidateObservation()
    static var before: SessionHostIMECandidateObservation.Snapshot?
    static var opened: SessionHostIMECandidateObservation.Snapshot?
    static var candidateCount = 0
    static var deadline = 0.0
    static var requestID = 0
    static var requestedAt = 0.0
    static var selectedID: UInt32?
}
extension MaruAppHostController {
    private var paletteIMERoot: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["MARU_PALETTE_IME"]!) }
    private var paletteIMEDiagnostic: Bool { ProcessInfo.processInfo.environment["MARU_PALETTE_IME_MODE"] == "diagnostic" }
    private func paletteIMERequire(_ value: Bool, _ reason: String) throws {
        if !value { throw NSError(domain: "PaletteIME", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
    }
    private func paletteIMEHash(_ text: String) -> UInt64 {
        Array(SHA256.hash(data: Data(text.utf8))).prefix(8).enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
    }
    private func paletteIMEText(_ query: String, _ preedit: String) throws {
        try paletteIMERequire(paletteIMEWitness(4) == query.utf8.count && paletteIMEWitness(5) == paletteIMEHash(query), "query")
        try paletteIMERequire(paletteIMEWitness(6) == preedit.utf8.count && paletteIMEWitness(7) == paletteIMEHash(preedit), "preedit")
    }
    private func paletteIMECompositionText(_ syllable: String) throws {
        let marked = paletteIMEWitness(4) == 0 && paletteIMEWitness(5) == paletteIMEHash("") && paletteIMEWitness(6) == syllable.utf8.count && paletteIMEWitness(7) == paletteIMEHash(syllable)
        let committed = paletteIMEWitness(4) == syllable.utf8.count && paletteIMEWitness(5) == paletteIMEHash(syllable) && paletteIMEWitness(6) == 0 && paletteIMEWitness(7) == paletteIMEHash("")
        try paletteIMERequire(marked || committed, "composition_\(syllable)")
    }
    private func paletteIMEState(_ name: String, view: MaruMetalTerminalView, window: NSWindow, composition: Bool = false) {
        let row: [String: Any] = ["name": name, "first_responder": window.firstResponder === view,
            "open": paletteIMEWitness(1), "palette_owner": paletteIMEWitness(2), "owner_generation": String(paletteIMEWitness(3)),
            "query_bytes": paletteIMEWitness(4), "query_hash": String(paletteIMEWitness(5)),
            "preedit_bytes": paletteIMEWitness(6), "preedit_hash": String(paletteIMEWitness(7)),
            "results": paletteIMEWitness(8), "terminal_bytes": paletteIMEWitness(9), "has_marked": view.hasMarkedText(), "committed_callbacks": PaletteIMEWitness.committed]
        if composition { PaletteIMERun.composition.append(row) } else { PaletteIMERun.observations.append(row) }
    }
    private func paletteIMEKeyboardState(view: MaruMetalTerminalView, window: NSWindow) throws {
        let data = try JSONSerialization.data(withJSONObject: ["pid": getpid(), "first_responder": window.firstResponder === view,
            "generation": String(paletteIMEWitness(3)), "view_source": view.inputContext?.selectedKeyboardInputSource ?? "",
            "time": ProcessInfo.processInfo.systemUptime], options: [.sortedKeys])
        try data.write(to: paletteIMERoot.appendingPathComponent("keyboard-state.json"), options: .atomic)
    }
    private func paletteIMEHID(_ code: UInt16, view: MaruMetalTerminalView, window: NSWindow, flags: UInt64 = 0, korean: Bool = true) throws {
        try paletteIMERequire(NSApp.isActive && window.firstResponder === view && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), "HID_owner")
        if korean {
            try paletteIMERequire(SessionHostInputSourcePolicy.currentSourceID() == SessionHostInputSourcePolicy.korean2SetSourceID &&
                view.inputContext?.selectedKeyboardInputSource == SessionHostInputSourcePolicy.korean2SetSourceID, "HID_source")
        }
        try paletteIMEKeyboardState(view: view, window: window)
        PaletteIMERun.requestID += 1
        PaletteIMERun.requestedAt = ProcessInfo.processInfo.systemUptime
        let row: [String: Any] = ["id": PaletteIMERun.requestID, "pid": getpid(), "keycode": code, "flags": flags,
            "korean": korean, "generation": String(paletteIMEWitness(3)), "time": PaletteIMERun.requestedAt]
        try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]).write(to: paletteIMERoot.appendingPathComponent("hid-request.json"), options: .atomic)
    }
    private func paletteIMEToggle(view: MaruMetalTerminalView, window: NSWindow) throws {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "P", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35) else { throw NSError(domain: "shortcut", code: 1) }
        if !view.performKeyEquivalent(with: event) { view.keyDown(with: event) }
    }
    private func paletteIMEPrepareSource(view: MaruMetalTerminalView) throws {
        try paletteIMERequire(NSApp.isActive && view.window?.firstResponder === view &&
            NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), "source_keyboard_owner")
        guard let context = view.inputContext else { throw NSError(domain: "context", code: 1) }
        if PaletteIMERun.originalGlobal == nil {
            PaletteIMERun.originalView = context.selectedKeyboardInputSource
            PaletteIMERun.originalGlobal = try SessionHostInputSourcePolicy.prepareKoreanSelection(recordURL: paletteIMERoot.appendingPathComponent("input-source.json"))
        } else {
            let current = SessionHostInputSourcePolicy.currentSourceID()
            // Replacing a palette inputContext may reactivate the terminal's original
            // source. Permit only our selected source or that recorded original.
            try paletteIMERequire(current == SessionHostInputSourcePolicy.korean2SetSourceID || current == PaletteIMERun.originalGlobal, "source_superseded")
        }
        context.deactivate(); context.selectedKeyboardInputSource = SessionHostInputSourcePolicy.korean2SetSourceID; context.activate()
    }
    private func paletteIMEAnchor(view: MaruMetalTerminalView, window: NSWindow) throws -> NSRect {
        let scale = archiveSmokeRenderScale(window)
        let local = NSRect(x: CGFloat(paletteIMEWitness(12)) / scale,
            y: view.bounds.height - CGFloat(paletteIMEWitness(13) + paletteIMEWitness(15)) / scale,
            width: CGFloat(paletteIMEWitness(14)) / scale, height: CGFloat(paletteIMEWitness(15)) / scale)
        let field = window.convertToScreen(view.convert(local, to: nil))
        let anchor = view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil)
        try paletteIMERequire(field.width > 0 && field.height > 0 && anchor.width > 0 && anchor.height > 0 && field.insetBy(dx: -1, dy: -1).contains(anchor), "caret_outside_palette")
        PaletteIMERun.geometry.append(["x": anchor.minX, "y": anchor.minY, "w": anchor.width, "h": anchor.height,
            "field_x": field.minX, "field_y": field.minY, "field_w": field.width, "field_h": field.height])
        return anchor
    }
    private func paletteIMESnapshot(view: MaruMetalTerminalView) throws -> SessionHostIMECandidateObservation.Snapshot {
        var row = try PaletteIMERun.observer.capture(counters: .init(pty_input_bytes: paletteIMEWitness(9),
            committed_text_callbacks: PaletteIMEWitness.committed, base_screen_generation: paletteIMEWitness(11)),
            anchor: view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil))
        row.search = .init(owner_generation: paletteIMEWitness(3), first_responder: view.window?.firstResponder === view,
            search_owner: paletteIMEWitness(2) == 1, query_bytes: UInt32(clamping: paletteIMEWitness(4)), query_hash: paletteIMEWitness(5),
            preedit_bytes: UInt32(clamping: paletteIMEWitness(6)), preedit_hash: paletteIMEWitness(7))
        return row
    }
    private func paletteIMECapture(_ name: String, surface: TerminalSurface) throws {
        guard let renderer = surface.metalRenderer else { throw NSError(domain: "renderer", code: 1) }
        let path = paletteIMERoot.appendingPathComponent("captures/\(name).ppm")
        try paletteIMERequire(!FileManager.default.fileExists(atPath: path.path) && maru_metal_renderer_request_test_capture(renderer, path.path), "capture_request")
        metalNeedsRedraw = true; _ = renderTick()
        try paletteIMERequire(FileManager.default.fileExists(atPath: path.path), "capture_missing")
    }
    private func paletteIMEFinish(_ reason: String?, view: MaruMetalTerminalView?) {
        guard !PaletteIMERun.finished else { return }; PaletteIMERun.finished = true
        var failures = reason.map { [$0] } ?? []
        if let original = PaletteIMERun.originalGlobal {
            if SessionHostInputSourcePolicy.permitsViewRestoration(currentGlobal: SessionHostInputSourcePolicy.currentSourceID(), originalGlobal: original,
                currentView: view?.inputContext?.selectedKeyboardInputSource, originalView: PaletteIMERun.originalView) {
                if let context = view?.inputContext, let source = PaletteIMERun.originalView {
                    context.deactivate(); context.selectedKeyboardInputSource = source; context.activate()
                }
                if SessionHostInputSourcePolicy.restore(recordURL: paletteIMERoot.appendingPathComponent("input-source.json")) != .restored { failures.append("source_restore") }
            } else {
                try? FileManager.default.removeItem(at: paletteIMERoot.appendingPathComponent("input-source.json")); failures.append("source_superseded")
            }
        }
        let report: [String: Any] = ["schema": "maru.palette-ime.v1", "passed": failures.isEmpty, "failures": failures,
            "mode": paletteIMEDiagnostic ? "diagnostic" : "live",
            "step": PaletteIMERun.step, "observations": PaletteIMERun.observations, "composition": PaletteIMERun.composition, "geometry": PaletteIMERun.geometry, "candidate_count": PaletteIMERun.candidateCount]
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: paletteIMERoot.appendingPathComponent("result.json"), options: .atomic) }
        catch { exitCode = 1 }
        if !failures.isEmpty { exitCode = 1; fputs("PALETTE_IME failed: \(failures)\n", stderr) }
        bypassQuitConfirm = true; DispatchQueue.main.async { NSApp.terminate(nil) }
    }
    private func tickPaletteIME() {
        guard !PaletteIMERun.finished, let surface = primary, let session = surface.appSession,
              let view = surface.view, let window = surface.window else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - PaletteIMERun.started < 100 else { paletteIMEFinish("timeout_\(PaletteIMERun.step)", view: view); return }
        guard now >= PaletteIMERun.next else { return }; PaletteIMERun.next = now + 0.35
        withSurface(surface) {
            do {
                if PaletteIMERun.requestID > 0 {
                    let ack = (try? Data(contentsOf: paletteIMERoot.appendingPathComponent("hid-ack.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    if ack?["id"] as? Int != PaletteIMERun.requestID {
                        try paletteIMERequire(now - PaletteIMERun.requestedAt < 3, "relay_timeout"); return
                    }
                    try paletteIMERequire(ack?["passed"] as? Bool == true, "relay_rejected")
                }
                try paletteIMEKeyboardState(view: view, window: window)
                try paletteIMERequire(paletteIMEWitness(0) == 1, "witness")
                switch PaletteIMERun.step {
                case 0:
                    try JSONSerialization.data(withJSONObject: ["screen_capture": CGPreflightScreenCaptureAccess(), "app_post_access": CGPreflightPostEventAccess()]).write(to: paletteIMERoot.appendingPathComponent("permissions.json"))
                    try paletteIMERequire(paletteIMEDiagnostic || CGPreflightScreenCaptureAccess(), "screen_capture_permission")
                    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                    guard NSApp.isActive && window.firstResponder === view else { return }
                    PaletteIMERun.baselineBytes = paletteIMEWitness(9)
                    try paletteIMEToggle(view: view, window: window); PaletteIMERun.step = 1
                case 1:
                    try paletteIMERequire(paletteIMEWitness(1) == 1 && paletteIMEWitness(2) == 1, "palette_focus")
                    try paletteIMEText("", ""); _ = try paletteIMEAnchor(view: view, window: window)
                    try paletteIMEPrepareSource(view: view); PaletteIMERun.next = now + 0.8; PaletteIMERun.step = 10
                case 10:
                    try paletteIMEHID(5, view: view, window: window); PaletteIMERun.step = 11
                case 11:
                    try paletteIMECompositionText("ㅎ"); paletteIMEState("ㅎ_\(PaletteIMERun.candidateCount)", view: view, window: window, composition: true)
                    try paletteIMEHID(40, view: view, window: window); PaletteIMERun.step = 12
                case 12:
                    try paletteIMECompositionText("하"); paletteIMEState("하_\(PaletteIMERun.candidateCount)", view: view, window: window, composition: true)
                    try paletteIMEHID(1, view: view, window: window); PaletteIMERun.step = 13
                case 13:
                    try paletteIMECompositionText("한"); paletteIMEState("한_\(PaletteIMERun.candidateCount)", view: view, window: window, composition: true)
                    try paletteIMERequire(paletteIMEWitness(9) == PaletteIMERun.baselineBytes, "preedit_terminal_leak")
                    _ = try paletteIMEAnchor(view: view, window: window)
                    paletteIMEState("han_\(PaletteIMERun.candidateCount)", view: view, window: window)
                    PaletteIMERun.before = try paletteIMESnapshot(view: view)
                    try paletteIMEHID(36, view: view, window: window, flags: CGEventFlags.maskAlternate.rawValue)
                    PaletteIMERun.deadline = now + 6; PaletteIMERun.step = 14
                case 14:
                    guard let before = PaletteIMERun.before else { throw NSError(domain: "before", code: 1) }
                    let opened = try paletteIMESnapshot(view: view)
                    let oldIDs = Set(before.windows.map { $0.id })
                    if opened.windows.allSatisfy({ oldIDs.contains($0.id) }) { try paletteIMERequire(now < PaletteIMERun.deadline, "candidate_missing"); return }
                    let proof = paletteIMEDiagnostic ? opened : try PaletteIMERun.observer.captureAppCandidate(before: before, opened: opened)
                    PaletteIMERun.opened = proof
                    if PaletteIMERun.candidateCount < 5 {
                        try paletteIMEHID(53, view: view, window: window); PaletteIMERun.step = 15
                    } else {
                        if paletteIMEDiagnostic {
                            let fresh = opened.windows.filter { !oldIDs.contains($0.id) }
                            try paletteIMERequire(fresh.count == 1 && fresh[0].owner.pid == getpid() && fresh[0].layer == 20, "diagnostic_candidate_inventory")
                            PaletteIMERun.selectedID = fresh[0].id
                        } else {
                            guard let capture = proof.app_captures.first else { throw NSError(domain: "selection_capture", code: 1) }
                            PaletteIMERun.selectedID = capture.window_id
                            try JSONEncoder().encode(proof.app_captures).write(to: paletteIMERoot.appendingPathComponent("selected-candidate-capture.json"))
                        }
                        try paletteIMEHID(36, view: view, window: window); PaletteIMERun.step = 25
                    }
                case 15:
                    try paletteIMEText("한", "")
                    guard let before = PaletteIMERun.before, let opened = PaletteIMERun.opened else { throw NSError(domain: "triplet", code: 1) }
                    try PaletteIMERun.observer.append(before: before, opened: opened, closed: paletteIMESnapshot(view: view))
                    paletteIMEState("cancel_\(PaletteIMERun.candidateCount)", view: view, window: window)
                    PaletteIMERun.candidateCount += 1
                    if PaletteIMERun.candidateCount == 5 && !paletteIMEDiagnostic {
                        try PaletteIMERun.observer.publish(sourceID: SessionHostInputSourcePolicy.korean2SetSourceID, outputURL: paletteIMERoot.appendingPathComponent("candidate.json"), search: true)
                    }
                    try paletteIMEToggle(view: view, window: window); PaletteIMERun.step = 16
                case 16:
                    try paletteIMERequire(paletteIMEWitness(1) == 0, "palette_close")
                    try paletteIMEToggle(view: view, window: window); PaletteIMERun.step = 1
                case 25:
                    try paletteIMEText("韓", "")
                    try paletteIMERequire(paletteIMEWitness(1) == 1 && paletteIMEWitness(9) == PaletteIMERun.baselineBytes, "selection_action_leak")
                    try paletteIMERequire(!paletteIMESnapshot(view: view).windows.contains { $0.id == PaletteIMERun.selectedID }, "selection_not_closed")
                    paletteIMEState("selected", view: view, window: window); try paletteIMECapture("selected", surface: surface)
                    try paletteIMEToggle(view: view, window: window); PaletteIMERun.step = 26
                case 26:
                    try paletteIMERequire(paletteIMEWitness(1) == 0, "selection_palette_close")
                    try paletteIMEToggle(view: view, window: window); PaletteIMERun.step = 30
                case 30:
                    try paletteIMEText("", ""); try paletteIMEPrepareSource(view: view)
                    PaletteIMERun.next = now + 0.8; PaletteIMERun.step = 31
                case 31: try paletteIMEHID(5, view: view, window: window); PaletteIMERun.step = 32
                case 32: try paletteIMECompositionText("ㅎ"); try paletteIMEHID(40, view: view, window: window); PaletteIMERun.step = 33
                case 33: try paletteIMECompositionText("하"); try paletteIMEHID(1, view: view, window: window); PaletteIMERun.step = 34
                case 34:
                    try paletteIMECompositionText("한"); try paletteIMEToggle(view: view, window: window); PaletteIMERun.step = 35
                case 35:
                    try paletteIMEText("한", "")
                    try paletteIMERequire(paletteIMEWitness(1) == 0 && paletteIMEWitness(2) == 0 && paletteIMEWitness(9) == PaletteIMERun.baselineBytes && !view.hasMarkedText(), "blur_state")
                    try paletteIMEHID(44, view: view, window: window, korean: false); PaletteIMERun.step = 36
                case 36:
                    try paletteIMEText("한", "")
                    try paletteIMERequire(paletteIMEWitness(1) == 0 && paletteIMEWitness(2) == 0 && paletteIMEWitness(9) == PaletteIMERun.baselineBytes + 1 && !view.hasMarkedText(), "terminal_return")
                    paletteIMEState("terminal_restored", view: view, window: window); try paletteIMECapture("terminal-restored", surface: surface)
                    paletteIMEFinish(nil, view: view)
                default: throw NSError(domain: "unknown_step", code: PaletteIMERun.step)
                }
            } catch {
                let reason = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String ?? String(describing: error)
                paletteIMEFinish(reason, view: view)
            }
        }
    }
}
