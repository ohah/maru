// Appended only to the copied EditorIMESmokeDriver.swift. All composing/candidate/handoff
// keys use HID. Window inventory and OCR are evidence; neither drives a product callback.
extension EditorIMESmokeDriver {
    private func candidateSnapshot(view: MaruMetalTerminalView) throws -> SessionHostIMECandidateObservation.Snapshot {
        try candidateObserver.capture(counters: .init(pty_input_bytes: 0, committed_text_callbacks: 0, base_screen_generation: 0),
                                      anchor: view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil))
    }

    private func requestHandoffCandidate(view: MaruMetalTerminalView, window: NSWindow) throws {
        guard CGPreflightScreenCaptureAccess() else {
            failures.append("candidate_screen_recording_permission"); throw SessionHostIMECandidateObservation.Failure.invalidOutput
        }
        candidateBefore = try candidateSnapshot(view: view)
        guard post(36, view: view, window: window, flags: .maskAlternate) else {
            throw SessionHostIMECandidateObservation.Failure.invalidOutput
        }
        candidateNotBefore = ProcessInfo.processInfo.systemUptime + 4
    }

    private func observeHandoffCandidate(view: MaruMetalTerminalView, window: NSWindow, close: Bool, name: String) throws -> Bool {
        guard let before = candidateBefore else { throw SessionHostIMECandidateObservation.Failure.invalidOutput }
        let opened = try candidateSnapshot(view: view)
        let prior = Set(before.windows.map { $0.id })
        if opened.windows.allSatisfy({ prior.contains($0.id) }) {
            if ProcessInfo.processInfo.systemUptime < candidateNotBefore { return false }
            failures.append("\(name)_candidate_not_opened")
            throw SessionHostIMECandidateObservation.Failure.invalidOutput
        }
        let proofSnapshot = try candidateObserver.captureAppCandidate(before: before, opened: opened)
        guard let proof = proofSnapshot.app_captures.first else {
            failures.append("\(name)_candidate_not_proven")
            throw SessionHostIMECandidateObservation.Failure.invalidOutput
        }
        candidateOpened = proofSnapshot
        let beforeData = try JSONEncoder().encode(before)
        let openedData = try JSONEncoder().encode(proofSnapshot)
        let data = try JSONEncoder().encode(proof)
        candidateEvidence.append(["name": name, "window_id": proof.window_id,
            "app_capture": try JSONSerialization.jsonObject(with: data),
            "before": try JSONSerialization.jsonObject(with: beforeData), "opened": try JSONSerialization.jsonObject(with: openedData),
            "source_owner": view.controller?.imeDiagnosticOwnerID ?? 0, "key_code": close ? 13 : (name == "source" ? 124 : 123)])
        observations.append("\(name)_candidate_window=\(proof.window_id)")
        observations.append("\(name)_candidate_hanja_rows=\(proof.hanja_rows)")
        guard beginLateSwitch(code: close ? 13 : (name == "source" ? 124 : 123),
                              flags: close ? [.maskCommand] : [.maskCommand, .maskAlternate],
                              view: view, window: window) else { throw SessionHostIMECandidateObservation.Failure.invalidOutput }
        return true
    }

    private func closedHandoffCandidate(view: MaruMetalTerminalView, name: String) throws {
        guard let before = candidateBefore, let opened = candidateOpened,
              let proof = opened.app_captures.first else { throw SessionHostIMECandidateObservation.Failure.invalidOutput }
        let closed = try candidateSnapshot(view: view)
        let gone = !closed.windows.contains { $0.id == proof.window_id }
        expect(gone, "\(name)_candidate_closed")
        guard gone else { throw SessionHostIMECandidateObservation.Failure.invalidOutput }
        let data = try JSONEncoder().encode(closed)
        candidateEvidence[candidateEvidence.count - 1]["closed"] = try JSONSerialization.jsonObject(with: data)
        candidateEvidence[candidateEvidence.count - 1]["popup_closed"] = true
        candidateEvidence[candidateEvidence.count - 1]["target_owner"] = view.controller?.imeDiagnosticOwnerID ?? 0
        try candidateObserver.append(before: before, opened: opened, closed: closed)
    }

    private func tickCandidateHandoff(view: MaruMetalTerminalView, window: NSWindow) {
        func compose(_ name: String, _ code: UInt16, _ text: String, _ caret: Int, _ start: Int) throws {
            guard postLiveKey(LiveKeyExpectation(name: name, code: code, text: text, caret: caret,
                composition: NSRange(location: start, length: 1)), view: view, window: window) else {
                throw SessionHostIMECandidateObservation.Failure.invalidOutput
            }
        }
        do {
            switch liveStep {
            case 70:
                guard let trace = fixtureTrace(), let fixture = trace.split(separator: "\n").first(where: { $0.hasPrefix("[IME_FIXTURE] source=") }) else { return }
                let fields = fixture.split(separator: " ")
                guard let source = fields.first(where: { $0.hasPrefix("source=") }).flatMap({ UInt64($0.dropFirst(7)) }),
                      let peer = fields.first(where: { $0.hasPrefix("peer=") }).flatMap({ UInt64($0.dropFirst(5)) }),
                      source != peer, view.controller?.imeDiagnosticOwnerID == source else { return }
                lateSourceID = source; latePeerID = peer
                expect(virtualText(view) == "L R", "candidate_shared_seed")
                var expected = LiveKeyExpectation(name: "candidate_source_start", code: 123, text: "L R", caret: 0, composition: nil)
                expected.requiresCallback = false
                guard postLiveKey(expected, view: view, window: window, flags: .maskCommand) else { throw SessionHostIMECandidateObservation.Failure.invalidOutput }
                liveStep = 71
            case 71:
                guard postLiveKey(LiveKeyExpectation(name: "candidate_source_position", code: 124, text: "L R", caret: 1, composition: nil), view: view, window: window) else { throw SessionHostIMECandidateObservation.Failure.invalidOutput }
                liveStep = 72
            case 72: try compose("candidate_source_h", 5, "Lㅎ R", 2, 1); liveStep = 73
            case 73: try compose("candidate_source_ha", 40, "L하 R", 2, 1); liveStep = 74
            case 74: try compose("candidate_source_han", 1, "L한 R", 2, 1); liveStep = 75
            case 75: try requestHandoffCandidate(view: view, window: window); liveStep = 76
            case 76:
                if try observeHandoffCandidate(view: view, window: window, close: false, name: "source") { liveStep = 77 }
            case 77:
                guard let peer = latePeerID, settleLateSwitch(owner: peer, text: "L韓 R", name: "candidate_peer", view: view) else { return }
                try closedHandoffCandidate(view: view, name: "source")
                var expected = LiveKeyExpectation(name: "candidate_peer_end", code: 124, text: "L韓 R", caret: 4, composition: nil)
                expected.requiresCallback = false
                guard postLiveKey(expected, view: view, window: window, flags: .maskCommand) else { throw SessionHostIMECandidateObservation.Failure.invalidOutput }
                liveStep = 78
            case 78: try compose("candidate_peer_h", 5, "L韓 Rㅎ", 5, 4); liveStep = 79
            case 79: try compose("candidate_peer_ha", 40, "L韓 R하", 5, 4); liveStep = 80
            case 80: try compose("candidate_peer_han", 1, "L韓 R한", 5, 4); liveStep = 81
            case 81: try requestHandoffCandidate(view: view, window: window); liveStep = 82
            case 82:
                let close = ProcessInfo.processInfo.environment["MARU_SHARED_RESTORE_IME_CLOSE"] == "1"
                if try observeHandoffCandidate(view: view, window: window, close: close, name: "peer") { liveStep = 83 }
            case 83:
                guard let source = lateSourceID, settleLateSwitch(owner: source, text: "L韓 R韓", name: "candidate_return", view: view) else { return }
                try closedHandoffCandidate(view: view, name: "peer")
                range(view.selectedRange(), NSRange(location: 2, length: 0), "candidate_source_caret_preserved")
                expect(virtualText(view) == "L韓 R韓", "candidate_shared_exact_once")
                key(1, "s", view: view, window: window); liveStep = 84
            case 84:
                guard disk("L韓 R韓", "candidate_shared_saved") else { return }
                let artifact: [String: Any] = ["schema": "maru.editor-ime-candidate-handoff.v1", "app_pid": getpid(), "source_id": SessionHostInputSourcePolicy.korean2SetSourceID, "rows": candidateEvidence]
                let root = URL(fileURLWithPath: outputPath).deletingLastPathComponent()
                try JSONSerialization.data(withJSONObject: artifact, options: [.sortedKeys]).write(to: root.appendingPathComponent("candidate-handoffs.json"), options: .withoutOverwriting)
                restoreInputSource(view: view); finish()
            default: break
            }
        } catch {
            failures.append("candidate_handoff_error:\(error)")
            restoreInputSource(view: view); finish()
        }
    }
}
