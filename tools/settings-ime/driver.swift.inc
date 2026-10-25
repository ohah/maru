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
    static var pointerObservations: [[String: Any]] = []
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
    private var addressPointerMode: Bool { ProcessInfo.processInfo.environment["MARU_ADDRESS_POINTER"] == "1" }
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
            "active_surface": paletteIMEWitness(10), "open": paletteIMEWitness(1), "palette_owner": paletteIMEWitness(2), "owner_generation": String(paletteIMEWitness(3)),
            "query_bytes": paletteIMEWitness(4), "query_hash": String(paletteIMEWitness(5)),
            "preedit_bytes": paletteIMEWitness(6), "preedit_hash": String(paletteIMEWitness(7)),
            "navigate_pending": paletteIMEWitness(8), "document_hash": String(paletteIMEWitness(17)), "filter_count": paletteIMEWitness(27), "document_bytes": paletteIMEWitness(18), "caret": paletteIMEWitness(19), "terminal_bytes": paletteIMEWitness(9), "has_marked": view.hasMarkedText(), "committed_callbacks": PaletteIMEWitness.committed]
        if composition { PaletteIMERun.composition.append(row) } else { PaletteIMERun.observations.append(row) }
    }
    private func paletteIMEKeyboardState(view: MaruMetalTerminalView, window: NSWindow) throws {
        let row: [String: Any] = ["pid":getpid(), "first_responder":window.firstResponder === view,
            "generation":String(paletteIMEWitness(3)), "view_source":view.inputContext?.selectedKeyboardInputSource ?? "", "time":ProcessInfo.processInfo.systemUptime]
        try JSONSerialization.data(withJSONObject:row).write(to:paletteIMERoot.appendingPathComponent("keyboard-state.json"),options:.atomic)
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
        let report: [String: Any] = ["schema": "maru.settings-ime.v1", "passed": failures.isEmpty, "failures": failures,
            "mode": paletteIMEDiagnostic ? "diagnostic" : "live",
            "window_inventory_validated": PaletteIMERun.candidateCount == 5 && !paletteIMEDiagnostic,
            "workflow": addressPointerMode ? "pointer" : "fixture", "pointer_observations": PaletteIMERun.pointerObservations,
            "step": PaletteIMERun.step, "observations": PaletteIMERun.observations, "composition": PaletteIMERun.composition, "geometry": PaletteIMERun.geometry, "candidate_count": PaletteIMERun.candidateCount]
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: paletteIMERoot.appendingPathComponent("result.json"), options: .atomic) }
        catch { exitCode = 1 }
        if !failures.isEmpty { exitCode = 1; fputs("PALETTE_IME failed: \(failures)\n", stderr) }
        bypassQuitConfirm = true; DispatchQueue.main.async { NSApp.terminate(nil) }
    }
    private func addressDocument(_ text: String) throws {
        try paletteIMERequire(paletteIMEWitness(17) == paletteIMEHash(text) && paletteIMEWitness(18) == text.utf8.count && paletteIMEWitness(8) == 0 , "settings_document")
    }
    private func addressPublish() throws {
        let encoded = try JSONEncoder().encode(PaletteIMERun.observer.rows)
        try encoded.write(to: paletteIMERoot.appendingPathComponent("window-transcript.json"))
        let valid = encoded.withUnsafeBytes { maru_address_validate_windows($0.bindMemory(to: UInt8.self).baseAddress!, encoded.count) }
        try paletteIMERequire(valid == 1, "shared_window_reducer")
        try encoded.write(to: paletteIMERoot.appendingPathComponent("window-transcript.json"))
        let rows = try PaletteIMERun.observer.rows.map { row -> [String: Any] in
            guard let proof = row.opened.app_captures.first, let window = row.opened.windows.first(where: { $0.id == proof.window_id }) else { throw NSError(domain: "missing_capture", code: 1) }
            let capture = try JSONSerialization.jsonObject(with: JSONEncoder().encode(proof))
            return ["window_id": window.id, "owner_pid": window.owner.pid, "bundle_id": window.owner.bundle_id,
                "signing_id": window.owner.signing_id, "apple_signed": window.owner.apple_signed,
                "layer": window.layer, "app_capture": capture]
        }
        try JSONSerialization.data(withJSONObject: ["schema": "maru.settings-ime-candidate.v1", "source_id": SessionHostInputSourcePolicy.korean2SetSourceID, "rows": rows], options: [.sortedKeys]).write(to: paletteIMERoot.appendingPathComponent("candidate.json"))
    }
    private func tickPaletteIME() {
        guard !PaletteIMERun.finished, let surface = primary, surface.appSession != nil,
              let view = surface.view, let window = surface.window else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - PaletteIMERun.started < 100 else { paletteIMEFinish("timeout_\(PaletteIMERun.step)", view: view); return }
        guard now >= PaletteIMERun.next else { return }; PaletteIMERun.next = now + 0.4
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
                switch PaletteIMERun.step {
                case 0:
                    try JSONSerialization.data(withJSONObject: ["screen_capture": CGPreflightScreenCaptureAccess()]).write(to: paletteIMERoot.appendingPathComponent("permissions.json"))
                    try paletteIMERequire(paletteIMEDiagnostic || CGPreflightScreenCaptureAccess(), "screen_capture_permission")
                    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                    guard NSApp.isActive && window.firstResponder === view else { return }
                    try paletteIMERequire(maru_address_fixture_start(0) != 0, "address_fixture")
                    PaletteIMERun.step = 1; PaletteIMERun.next = now + 1
                case 1:
                    try paletteIMERequire(paletteIMEWitness(1) == 1 && paletteIMEWitness(2) == 1, "address_owner")
                    try addressDocument("")
                    paletteIMEState("selected_fixture_\(PaletteIMERun.candidateCount)", view: view, window: window)
                    if PaletteIMERun.candidateCount == 0 { PaletteIMERun.baselineBytes = paletteIMEWitness(9) }
                    try paletteIMEPrepareSource(view: view)
                    _ = try paletteIMEAnchor(view: view, window: window)
                    PaletteIMERun.step = 10; PaletteIMERun.next = now + 1
                case 10: try paletteIMEHID(5, view: view, window: window); PaletteIMERun.step = 11
                case 11:
                    try addressDocument("ㅎ"); paletteIMEState("ㅎ", view: view, window: window, composition: true)
                    try paletteIMEHID(40, view: view, window: window); PaletteIMERun.step = 12
                case 12:
                    try addressDocument("하"); paletteIMEState("하", view: view, window: window, composition: true)
                    try paletteIMEHID(1, view: view, window: window); PaletteIMERun.step = 13
                case 13:
                    try addressDocument("한"); paletteIMEState("한", view: view, window: window, composition: true)
                    _ = try paletteIMEAnchor(view: view, window: window)
                    PaletteIMERun.step = 20
                case 20:
                    try addressDocument("한")
                    paletteIMEState("han_\(PaletteIMERun.candidateCount)", view: view, window: window)
                    PaletteIMERun.before = try paletteIMESnapshot(view: view)
                    try paletteIMEHID(36, view: view, window: window, flags: CGEventFlags.maskAlternate.rawValue)
                    PaletteIMERun.deadline = now + 8; PaletteIMERun.step = 21
                case 21:
                    guard let before = PaletteIMERun.before else { throw NSError(domain: "before", code: 1) }
                    let opened = try paletteIMESnapshot(view: view)
                    let old = Set(before.windows.map { $0.id })
                    if opened.windows.allSatisfy({ old.contains($0.id) }) { try paletteIMERequire(now < PaletteIMERun.deadline, "candidate_missing"); return }
                    try addressDocument("韓")
                    PaletteIMERun.opened = paletteIMEDiagnostic ? opened : try PaletteIMERun.observer.captureAppCandidate(before: before, opened: opened)
                    paletteIMEState("opened_\(PaletteIMERun.candidateCount)", view: view, window: window)
                    if PaletteIMERun.candidateCount < 5 {
                        try paletteIMEHID(53, view: view, window: window); PaletteIMERun.step = 22
                    } else {
                        try paletteIMEHID(36, view: view, window: window); PaletteIMERun.step = 30
                    }
                case 22:
                    try addressDocument("한")
                    try paletteIMERequire(!view.hasMarkedText(), "cancel_marked")
                    guard let before = PaletteIMERun.before, let opened = PaletteIMERun.opened else { throw NSError(domain: "triplet", code: 1) }
                    try PaletteIMERun.observer.append(before: before, opened: opened, closed: paletteIMESnapshot(view: view))
                    paletteIMEState("cancel_\(PaletteIMERun.candidateCount)", view: view, window: window)
                    PaletteIMERun.candidateCount += 1
                    if PaletteIMERun.candidateCount == 5 && !paletteIMEDiagnostic { try addressPublish() }
                    try paletteIMERequire(maru_address_fixture_start(0) != 0, "next_rename_fixture")
                    PaletteIMERun.step = 1; PaletteIMERun.next = now + 0.8
                case 30:
                    try addressDocument("韓")
                    try paletteIMERequire(!view.hasMarkedText() && paletteIMEWitness(1) == 1, "selected_or_navigated")
                    paletteIMEState("selected", view: view, window: window)
                    try paletteIMECapture("selected", surface: surface)
                    try paletteIMEHID(53, view:view, window:window)
                    PaletteIMERun.step = 33; PaletteIMERun.next = now + 0.8
                case 33:
                    try paletteIMERequire(paletteIMEWitness(1) == 0 && paletteIMEWitness(28) == 1, "search_escape")
                    try paletteIMEHID(53, view:view, window:window)
                    PaletteIMERun.step = 31; PaletteIMERun.next = now + 0.8
                case 31:
                    try paletteIMERequire(paletteIMEWitness(28) == 0, "settings_escape")
                    try paletteIMERequire(paletteIMEWitness(1) == 0 && paletteIMEWitness(2) == 0 && window.firstResponder === view, "terminal_focus")
                    try paletteIMEHID(44, view: view, window: window, korean: false); PaletteIMERun.step = 32
                case 32:
                    try paletteIMERequire(paletteIMEWitness(9) == PaletteIMERun.baselineBytes + 1, "terminal_input")
                    paletteIMEState("terminal_restored", view: view, window: window)
                    try paletteIMECapture("terminal-restored", surface: surface)
                    paletteIMEFinish(nil, view: view)
                default: throw NSError(domain: "step", code: PaletteIMERun.step)
                }
                if PaletteIMERun.step > 1 && PaletteIMERun.step < 32 { try paletteIMERequire(paletteIMEWitness(9) == PaletteIMERun.baselineBytes, "terminal_leak") }
            } catch { paletteIMEFinish(String(describing: error), view: view) }
        }
    }
}
@_silgen_name("maru_address_fixture_start") private func maru_address_fixture_start(_ mode: UInt32) -> UInt64
@_silgen_name("maru_address_validate_windows") private func maru_address_validate_windows(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> UInt32

