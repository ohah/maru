import AppKit
import Foundation

/// N3 callback contract through the product NSTextInputClient. These deterministic callbacks
/// test range transport and document edits; they do not impersonate a live Korean input method.
/// Only fixture text is saved. The shell also checks the saved bytes, independently of this driver.
@MainActor
final class EditorIMESmokeDriver {
    private var step = 0
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private(set) var finished = false
    private(set) var failures: [String] = []
    private var observations: [String] = []
    private let documentPath: String
    private let outputPath: String
    private let live: Bool
    private let wrappedCandidate: Bool
    private let lateFocus: Bool
    private var lateSourceID: UInt64?
    private var latePeerID: UInt64?
    private var lateSwitchTraceOffset: UInt64 = 0
    private var lateQuietTraceOffset: UInt64 = 0
    private var lateQuietStarted: TimeInterval?
    private var lateQuietSelection: NSRange?
    private var lateQuietPreserved = true
    private var lateObservedCallbacks = 0
    private var candidateIndex = 0
    private let candidateObserver = SessionHostIMECandidateObservation()
    private var candidateBefore: SessionHostIMECandidateObservation.Snapshot?
    private var candidateOpened: SessionHostIMECandidateObservation.Snapshot?
    private var candidateBaselineY: CGFloat = 0
    private var candidateEvidence: [[String: Any]] = []
    private var candidateNotBefore: TimeInterval = 0
    private var candidatePrefix: String { String(repeating: "x", count: 192 + candidateIndex * 32) + " " }
    private var liveStep = 0
    private var liveKeyIndex = 0
    private var nextLiveEvent: TimeInterval = 0
    private struct LiveMarkedExpectation {
        let text: String
        let caret: Int
        let composition: NSRange
    }
    private struct LiveKeyExpectation {
        let name: String
        let code: UInt16
        let text: String
        let caret: Int
        let composition: NSRange?
        var markedStates: [LiveMarkedExpectation] = []
        var requiresCallback = true
    }
    private var pendingLiveKey: LiveKeyExpectation?
    private var liveKeyPostedAt: TimeInterval = 0
    private var liveTraceOffset: UInt64 = 0
    private var liveMarkedCallbacks = 0
    private var liveInsertCallbacks = 0
    private var liveReplacementCallbacks = 0
    private var originalViewSource: String?
    private var originalGlobalSource: String?
    private var sourceRecord: URL?
    private var sourceSuperseded = false
    private var diskWaitStarted: TimeInterval?
    private let unspecified = NSRange(location: NSNotFound, length: 0)

    init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let document = environment["MARU_NATIVE_EDITOR"],
              let output = environment["MARU_EDITOR_IME_SMOKE_OUT"] else { return nil }
        documentPath = document
        outputPath = output
        live = environment["MARU_EDITOR_IME_SMOKE_LIVE"] == "1"
        wrappedCandidate = environment["MARU_EDITOR_IME_WRAPPED_CANDIDATE"] == "1"
        lateFocus = environment["MARU_EDITOR_IME_LATE_FOCUS"] == "1"
    }

    private func expect(_ condition: Bool, _ name: String) {
        observations.append("\(name)=\(condition)")
        if !condition { failures.append(name) }
    }

    private func range(_ actual: NSRange, _ expected: NSRange, _ name: String) {
        observations.append("\(name)_actual=\(actual.location),\(actual.length)")
        expect(actual == expected, name)
    }

    private func disk(_ expected: String, _ name: String) -> Bool {
        let matches = (try? String(contentsOfFile: documentPath, encoding: .utf8)) == expected
        if !matches {
            let now = ProcessInfo.processInfo.systemUptime
            if diskWaitStarted == nil { diskWaitStarted = now }
            if now - diskWaitStarted! < 3 { return false }
        }
        diskWaitStarted = nil
        expect(matches, name)
        return true
    }

    private func key(_ code: UInt16, _ characters: String, view: MaruMetalTerminalView, window: NSWindow) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code
        ) else { failures.append("key_creation"); return }
        view.keyDown(with: event)
    }

    private func finish() {
        finished = true
        if live {
            observations.append("live_callback_setMarkedText_count=\(liveMarkedCallbacks)")
            observations.append("live_callback_insertText_count=\(liveInsertCallbacks)")
            observations.append("live_callback_explicit_replacement_count=\(liveReplacementCallbacks)")
            let protocolName = liveMarkedCallbacks > 0
                ? (liveReplacementCallbacks > 0 ? "marked_and_replacement" : "marked")
                : (liveReplacementCallbacks > 0 ? "insertText_replacement" :
                    (liveInsertCallbacks > 0 ? "insertText" : "unobserved"))
            observations.append("live_callback_protocol=\(protocolName)")
        }
        if lateFocus {
            observations.append("late_focus_os_callback_count_after_observed_cutover=\(lateObservedCallbacks)")
            observations.append("late_focus_os_callback_observed=\(lateObservedCallbacks > 0)")
        }
        observations.append("failure_count=\(failures.count)")
        observations.append("failures=\(failures.joined(separator: ","))")
        let report = observations.joined(separator: "\n") + "\n"
        do { try Data(report.utf8).write(to: URL(fileURLWithPath: outputPath), options: .atomic) }
        catch { failures.append("summary_write") }
        FileHandle.standardOutput.write(Data(report.utf8))
    }

    func tick(editorPresent: Bool, view: MaruMetalTerminalView, window: NSWindow) {
        guard !finished else { return }
        guard ProcessInfo.processInfo.systemUptime - startedAt < (wrappedCandidate ? 100 : (live ? 28 : 18)) else {
            failures.append("editor_timeout"); restoreInputSource(view: view); finish(); return
        }
        guard editorPresent else { return }
        if live { tickLive(view: view, window: window); return }
        switch step {
        case 0:
            key(0, "a", view: view, window: window)
            let selectionBeforeUnmark = view.selectedRange()
            view.unmarkText()
            range(view.selectedRange(), selectionBeforeUnmark, "unmark_without_composition_selection")
            expect(virtualText(view) == "ab😀한cd", "unmark_without_composition_document")
            key(124, String(UnicodeScalar(NSRightArrowFunctionKey)!), view: view, window: window)
            range(view.selectedRange(), NSRange(location: 7, length: 0), "document_utf16_selection")
            view.setMarkedText("가", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: 4, length: 1))
            range(view.markedRange(), NSRange(location: 4, length: 1), "explicit_marked_range")
            range(view.selectedRange(), NSRange(location: 5, length: 0), "marked_selection")
            view.setMarkedText("나", selectedRange: NSRange(location: 0, length: 1), replacementRange: unspecified)
            range(view.selectedRange(), NSRange(location: 4, length: 1), "marked_inner_selection")
            view.insertText("漢", replacementRange: unspecified)
            expect(virtualText(view) == "ab😀漢cd", "marked_replacement_document")
            key(1, "s", view: view, window: window)
        case 1:
            guard disk("ab😀漢cd", "marked_replacement_saved") else { return }
            view.insertText("X", replacementRange: NSRange(location: 2, length: 2))
            expect(virtualText(view) == "abX漢cd", "surrogate_replacement_document")
            key(1, "s", view: view, window: window)
        case 2:
            guard disk("abX漢cd", "surrogate_replacement_saved") else { return }
            // A new document body establishes two equal selections using the user-facing chord.
            key(0, "a", view: view, window: window)
            view.insertText("cat cat", replacementRange: unspecified)
            key(0, "a", view: view, window: window)
            key(123, String(UnicodeScalar(NSLeftArrowFunctionKey)!), view: view, window: window)
            key(2, "d", view: view, window: window)
            key(2, "d", view: view, window: window)
            view.setMarkedText("하", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
            view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
            // Add Next Occurrence makes the newest match primary; only its preedit is visible.
            range(view.markedRange(), NSRange(location: 4, length: 1), "multicursor_primary_mark")
            view.insertText("한", replacementRange: unspecified)
            expect(virtualText(view) == "한 한", "multicursor_commit_document")
            key(1, "s", view: view, window: window)
        case 3:
            guard disk("한 한", "multicursor_commit_saved") else { return }
            key(6, "z", view: view, window: window)
            expect(virtualText(view) == "cat cat", "multicursor_undo_document")
            key(1, "s", view: view, window: window)
        case 4:
            guard disk("cat cat", "multicursor_single_undo") else { return }
            finish()
        default: break
        }
        step += 1
    }

    /// The input source owns this sequence: HID events enter TSM and produce the actual
    /// setMarkedText/insertText calls. Focus is checked immediately before every global event.
    private func post(_ code: UInt16, view: MaruMetalTerminalView, window: NSWindow, flags: CGEventFlags = []) -> Bool {
        guard NSApp.isActive, window.firstResponder === view,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
              SessionHostInputSourcePolicy.currentSourceID() == SessionHostInputSourcePolicy.korean2SetSourceID,
              view.inputContext?.selectedKeyboardInputSource == SessionHostInputSourcePolicy.korean2SetSourceID,
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        else {
            // Report the failed ownership condition before restoration changes the sources.
            // A source transition and a foreground loss require different follow-up actions.
            observations.append("live_post_guard=active:\(NSApp.isActive),frontmost:\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0),self:\(getpid()),responder:\(window.firstResponder === view),global:\(SessionHostInputSourcePolicy.currentSourceID() ?? "nil"),view:\(view.inputContext?.selectedKeyboardInputSource ?? "nil")")
            return false
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    func restoreInputSource(view: MaruMetalTerminalView?) {
        guard !sourceSuperseded else { return }
        if sourceRecord != nil, let originalGlobal = originalGlobalSource {
            let currentGlobal = SessionHostInputSourcePolicy.currentSourceID()
            let currentView = view?.inputContext?.selectedKeyboardInputSource
            guard currentGlobal != nil, originalViewSource == nil || currentView != nil else {
                observations.append("live_input_source_restore=unavailable")
                expect(false, "live_input_source_restore_observed")
                return
            }
            guard SessionHostInputSourcePolicy.permitsViewRestoration(
                currentGlobal: currentGlobal, originalGlobal: originalGlobal,
                currentView: currentView, originalView: originalViewSource
            ) else {
                // Do not reactivate the original view source: doing so would overwrite the user
                // before the disk-record restorer can see that its authority was superseded.
                sourceSuperseded = true
                observations.append("live_input_source_restore=superseded")
                expect(false, "live_input_source_restore_owned")
                // The view may observe the user's new source before TIS publishes it globally.
                // Revoke this fixture's disk authority too, so the EXIT helper cannot restore
                // the old global source during that interval.
                if let record = sourceRecord {
                    do {
                        try FileManager.default.removeItem(at: record)
                        observations.append("live_input_source_restore_record=revoked")
                        sourceRecord = nil
                        originalGlobalSource = nil
                        originalViewSource = nil
                    } catch {
                        observations.append("live_input_source_restore_record=revoke_failed")
                        expect(false, "live_input_source_restore_record_revoked")
                    }
                }
                return
            }
        }
        if let original = originalViewSource, let context = view?.inputContext {
            context.discardMarkedText()
            context.deactivate()
            context.selectedKeyboardInputSource = original
            context.activate()
            expect(context.selectedKeyboardInputSource == original, "live_view_source_restored")
            originalViewSource = nil
        }
        if let record = sourceRecord {
            let result = SessionHostInputSourcePolicy.restore(recordURL: record)
            observations.append("live_input_source_restore=\(result)")
            expect(result == .restored || result == .noRecord, "live_global_source_restored")
            sourceRecord = nil
            originalGlobalSource = nil
        }
    }

    private func virtualText(_ view: MaruMetalTerminalView) -> String? {
        view.attributedSubstring(forProposedRange: NSRange(location: 0, length: 4096), actualRange: nil)?.string
    }

    private var traceURL: URL {
        URL(fileURLWithPath: outputPath).deletingLastPathComponent().appendingPathComponent("app.stderr.txt")
    }

    /// Read only this isolated fixture's existing opt-in diagnostic stream. Product callbacks
    /// remain untouched; their range headers distinguish marked and direct-replacement IMEs.
    private func recordLiveCallbacks(_ expected: LiveKeyExpectation) {
        fflush(stderr)
        guard let file = try? FileHandle(forReadingFrom: traceURL) else {
            expect(false, "\(expected.name)_callback_trace"); return
        }
        defer { try? file.close() }
        do {
            try file.seek(toOffset: liveTraceOffset)
            let data = try file.read(upToCount: 65536) ?? Data()
            guard data.count < 65536 else {
                expect(false, "\(expected.name)_callback_trace_bounded"); return
            }
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            expect(lines.contains { $0.hasPrefix("[IME] keyDown ") && $0.split(separator: " ").contains(where: { String($0) == "keyCode=\(expected.code)" }) },
                   "\(expected.name)_hid_received")
            var headers: [String] = []
            for line in lines {
                if line.hasPrefix("[IME] setMarkedText ") {
                    liveMarkedCallbacks += 1
                } else if line.hasPrefix("[IME] insertText ") {
                    liveInsertCallbacks += 1
                    if !line.hasPrefix("[IME] insertText replacement={\(NSNotFound), ") {
                        liveReplacementCallbacks += 1
                    }
                } else if !line.hasPrefix("[IME] doCommand:") { continue }
                headers.append(String(line.components(separatedBy: " text=").first ?? String(line)))
            }
            observations.append("\(expected.name)_callbacks=\(headers.joined(separator: " | "))")
            expect(!headers.isEmpty || !expected.requiresCallback, "\(expected.name)_callback_observed")
        } catch { expect(false, "\(expected.name)_callback_trace") }
    }

    private func postLiveKey(_ expected: LiveKeyExpectation, view: MaruMetalTerminalView, window: NSWindow,
                             flags: CGEventFlags = []) -> Bool {
        fflush(stderr)
        guard let file = try? FileHandle(forReadingFrom: traceURL) else {
            expect(false, "\(expected.name)_callback_trace_open"); return false
        }
        defer { try? file.close() }
        guard let offset = try? file.seekToEnd() else {
            expect(false, "\(expected.name)_callback_trace_offset"); return false
        }
        liveTraceOffset = offset
        guard post(expected.code, view: view, window: window, flags: flags) else { return false }
        pendingLiveKey = expected
        liveKeyPostedAt = ProcessInfo.processInfo.systemUptime
        return true
    }

    /// A Korean input source may keep a marked span or edit the document with insertText's
    /// explicit replacementRange. Require identical per-key text/caret results for both paths.
    private func verifyPendingLiveKey(view: MaruMetalTerminalView) -> Bool {
        guard let expected = pendingLiveKey else { return true }
        let text = virtualText(view)
        let selected = view.selectedRange()
        let marked = view.markedRange()
        let hasMarked = view.hasMarkedText()
        // Only the primary projects preedit. Secondary cursors receive each committed prefix;
        // a source that directly replaces committed syllables must update every cursor now.
        let markedState = hasMarked
            ? (expected.markedStates.first { $0.text == text } ?? expected.markedStates.first) : nil
        let expectedText = markedState?.text ?? expected.text
        let expectedCaret = markedState?.caret ?? expected.caret
        let expectedComposition = markedState?.composition ?? expected.composition
        let selectedMatches = selected == NSRange(location: expectedCaret, length: 0)
        let rangeConsistent: Bool
        if hasMarked, let composition = expectedComposition {
            rangeConsistent = marked.location != NSNotFound && marked.length > 0 &&
                marked.location >= composition.location && marked.location <= expectedCaret &&
                marked.length == expectedCaret - marked.location &&
                NSMaxRange(marked) <= NSMaxRange(composition)
        } else {
            rangeConsistent = !hasMarked && marked == NSRange(location: expectedCaret, length: 0)
        }
        if (text != expectedText || !selectedMatches || !rangeConsistent),
           ProcessInfo.processInfo.systemUptime - liveKeyPostedAt < 1 { return false }
        observations.append("\(expected.name)_text_actual=\(text ?? "<unavailable>")")
        expect(text == expectedText, "\(expected.name)_text")
        range(selected, NSRange(location: expectedCaret, length: 0), "\(expected.name)_caret")
        observations.append("\(expected.name)_marked_actual=\(marked.location),\(marked.length)")
        observations.append("\(expected.name)_has_marked=\(hasMarked)")
        expect(rangeConsistent, "\(expected.name)_range_consistency")
        recordLiveCallbacks(expected)
        pendingLiveKey = nil
        return true
    }

    private func selectLiveRepeatedWords(view: MaruMetalTerminalView, window: NSWindow, name: String) {
        key(0, "a", view: view, window: window)
        view.insertText("cat cat", replacementRange: unspecified)
        key(0, "a", view: view, window: window)
        key(123, String(UnicodeScalar(NSLeftArrowFunctionKey)!), view: view, window: window)
        key(2, "d", view: view, window: window)
        key(2, "d", view: view, window: window)
        expect(virtualText(view) == "cat cat", "\(name)_seed")
        range(view.selectedRange(), NSRange(location: 4, length: 3), "\(name)_primary_selection")
    }

    private func tickLive(view: MaruMetalTerminalView, window: NSWindow) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= nextLiveEvent else { return }
        nextLiveEvent = now + 0.12
        guard verifyPendingLiveKey(view: view) else { return }
        switch liveStep {
        case 0:
            NSApp.activate(ignoringOtherApps: true)
            _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
            window.makeKeyAndOrderFront(nil)
            if !NSApp.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() {
                // Keep only the last readiness observation; no key is posted while it is false.
                observations.removeAll { $0.hasPrefix("live_focus_wait=") }
                observations.append("live_focus_wait=active:\(NSApp.isActive),frontmost:\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0),self:\(getpid())")
            }
            guard window.makeFirstResponder(view), NSApp.isActive,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else { return }
            guard CGPreflightPostEventAccess(), let context = view.inputContext else {
                failures.append("live_input_permission_or_context"); finish(); return
            }
            originalViewSource = context.selectedKeyboardInputSource
            let record = URL(fileURLWithPath: outputPath).deletingLastPathComponent().appendingPathComponent("input-source.json")
            do { originalGlobalSource = try SessionHostInputSourcePolicy.prepareKoreanSelection(recordURL: record) }
            catch {
                // The policy owns rollback until preparation succeeds. The view has not changed
                // yet, and activating its old source here could overwrite a concurrent user choice.
                originalViewSource = nil
                failures.append("live_input_source_selection"); finish(); return
            }
            sourceRecord = record
            context.deactivate()
            context.selectedKeyboardInputSource = SessionHostInputSourcePolicy.korean2SetSourceID
            context.activate()
            liveStep = lateFocus ? 50 : (wrappedCandidate ? 30 : 1)
        case 1, 5:
            key(0, "a", view: view, window: window)
            view.insertText("left right", replacementRange: unspecified)
            key(123, String(UnicodeScalar(NSLeftArrowFunctionKey)!), view: view, window: window)
            liveKeyIndex = 0
            liveStep += 1
        case 2, 6:
            // Move into the middle of the line, then let Korean TSM compose 가나 or one last jamo.
            let codes: [UInt16] = liveStep == 2
                ? [124, 124, 124, 124, 124, 15, 40, 1, 40]
                : [124, 124, 124, 124, 124, 15]
            if liveKeyIndex < codes.count {
                let prefix = liveStep == 2 ? "live_continuing" : "live_last_jamo"
                let syllables = ["ㄱ", "가", "간", "가나"]
                let composition = liveKeyIndex < 5 ? "" : syllables[liveKeyIndex - 5]
                let expected = LiveKeyExpectation(
                    name: "\(prefix)_key_\(liveKeyIndex + 1)", code: codes[liveKeyIndex],
                    text: "left \(composition)right",
                    caret: liveKeyIndex < 5 ? liveKeyIndex + 1 : 5 + composition.utf16.count,
                    composition: composition.isEmpty ? nil : NSRange(location: 5, length: composition.utf16.count)
                )
                guard postLiveKey(expected, view: view, window: window) else {
                    failures.append("live_keyboard_focus_lost"); restoreInputSource(view: view); finish(); return
                }
                liveKeyIndex += 1
            } else { liveStep += 1 }
        case 3:
            expect(virtualText(view) == "left 가나right", "live_continuing_virtual_document")
            key(1, "s", view: view, window: window)
            liveStep = 4
        case 4:
            guard disk("left 가나right", "live_continuing_saved") else { return }
            liveStep = 5
        case 7:
            let expected = LiveKeyExpectation(name: "live_last_jamo_backspace", code: 51,
                                              text: "left right", caret: 5, composition: nil)
            guard postLiveKey(expected, view: view, window: window) else {
                failures.append("live_keyboard_focus_lost"); restoreInputSource(view: view); finish(); return
            }
            liveStep = 8
        case 8:
            expect(!view.hasMarkedText(), "live_last_jamo_deleted")
            expect(virtualText(view) == "left right", "live_last_jamo_preserved_neighbors")
            key(1, "s", view: view, window: window)
            liveStep = 9
        case 9:
            guard disk("left right", "live_last_jamo_saved") else { return }
            liveStep = 10
        case 10:
            selectLiveRepeatedWords(view: view, window: window, name: "live_multi_continuing")
            liveKeyIndex = 0
            liveStep = 11
        case 11:
            let codes: [UInt16] = [15, 40, 1, 40]
            let syllables = ["ㄱ", "가", "간", "가나"]
            if liveKeyIndex < codes.count {
                let syllable = syllables[liveKeyIndex]
                var expected = LiveKeyExpectation(
                    name: "live_multi_continuing_key_\(liveKeyIndex + 1)", code: codes[liveKeyIndex],
                    text: "\(syllable) \(syllable)", caret: 1 + 2 * syllable.utf16.count, composition: nil
                )
                expected.markedStates = [LiveMarkedExpectation(
                    text: "cat \(syllable)", caret: 4 + syllable.utf16.count,
                    composition: NSRange(location: 4, length: syllable.utf16.count)
                )]
                if liveKeyIndex == 3 {
                    expected.markedStates.append(LiveMarkedExpectation(
                        text: "가 가나", caret: 4, composition: NSRange(location: 3, length: 1)
                    ))
                }
                guard postLiveKey(expected, view: view, window: window) else {
                    failures.append("live_multi_keyboard_focus_lost"); restoreInputSource(view: view); finish(); return
                }
                liveKeyIndex += 1
            } else { liveStep = 12 }
        case 12:
            key(1, "s", view: view, window: window)
            expect(virtualText(view) == "가나 가나", "live_multi_continuing_committed")
            range(view.selectedRange(), NSRange(location: 5, length: 0), "live_multi_continuing_commit_caret")
            liveStep = 13
        case 13:
            guard disk("가나 가나", "live_multi_continuing_saved") else { return }
            liveStep = 14
        case 14:
            selectLiveRepeatedWords(view: view, window: window, name: "live_multi_last_jamo")
            view.insertText("L", replacementRange: unspecified)
            expect(virtualText(view) == "L L", "live_multi_last_jamo_carets_seed")
            range(view.selectedRange(), NSRange(location: 3, length: 0), "live_multi_last_jamo_seed_caret")
            liveStep = 15
        case 15:
            var expected = LiveKeyExpectation(name: "live_multi_last_jamo_insert", code: 15,
                                              text: "Lㄱ Lㄱ", caret: 5, composition: nil)
            expected.markedStates = [LiveMarkedExpectation(
                text: "L Lㄱ", caret: 4, composition: NSRange(location: 3, length: 1)
            )]
            guard postLiveKey(expected, view: view, window: window) else {
                failures.append("live_multi_keyboard_focus_lost"); restoreInputSource(view: view); finish(); return
            }
            liveStep = 16
        case 16:
            let expected = LiveKeyExpectation(name: "live_multi_last_jamo_backspace", code: 51,
                                              text: "L L", caret: 3, composition: nil)
            guard postLiveKey(expected, view: view, window: window) else {
                failures.append("live_multi_keyboard_focus_lost"); restoreInputSource(view: view); finish(); return
            }
            liveStep = 17
        case 17:
            expect(!view.hasMarkedText(), "live_multi_last_jamo_deleted")
            expect(virtualText(view) == "L L", "live_multi_last_jamo_preserved_neighbors")
            key(1, "s", view: view, window: window)
            liveStep = 18
        case 18:
            guard disk("L L", "live_multi_last_jamo_saved") else { return }
            key(0, "a", view: view, window: window)
            view.insertText("left right", replacementRange: unspecified)
            key(123, String(UnicodeScalar(NSLeftArrowFunctionKey)!), view: view, window: window)
            // Use the same real arrow path as the earlier live sequences. A direct
            // doCommand call has no associated key event and does not move this view.
            liveKeyIndex = 0
            liveStep = 24
        case 24:
            if liveKeyIndex < 5 {
                let expected = LiveKeyExpectation(name: "live_enter_move_\(liveKeyIndex + 1)", code: 124,
                                                  text: "left right", caret: liveKeyIndex + 1, composition: nil)
                guard postLiveKey(expected, view: view, window: window) else {
                    failures.append("live_enter_focus_lost"); restoreInputSource(view: view); finish(); return
                }
                liveKeyIndex += 1
            } else {
                range(view.selectedRange(), NSRange(location: 5, length: 0), "live_enter_seed_caret")
                liveStep = 19
            }
        case 19:
            guard postLiveKey(LiveKeyExpectation(name: "live_enter_initial", code: 15,
                                                text: "left ㄱright", caret: 6, composition: NSRange(location: 5, length: 1)), view: view, window: window) else {
                failures.append("live_enter_focus_lost"); restoreInputSource(view: view); finish(); return
            }
            liveStep = 20
        case 20:
            guard postLiveKey(LiveKeyExpectation(name: "live_enter_syllable", code: 40,
                                                text: "left 가right", caret: 6, composition: NSRange(location: 5, length: 1)), view: view, window: window) else {
                failures.append("live_enter_focus_lost"); restoreInputSource(view: view); finish(); return
            }
            liveStep = 21
        case 21:
            guard postLiveKey(LiveKeyExpectation(name: "live_enter_commit", code: 36,
                                                text: "left 가\nright", caret: 7, composition: nil), view: view, window: window) else {
                failures.append("live_enter_focus_lost"); restoreInputSource(view: view); finish(); return
            }
            liveStep = 22
        case 22:
            expect(!view.hasMarkedText(), "live_enter_no_marked")
            key(1, "s", view: view, window: window)
            liveStep = 23
        case 23:
            guard disk("left 가\nright", "live_enter_saved") else { return }
            restoreInputSource(view: view)
            finish()
        case 30...39:
            tickWrappedCandidate(view: view, window: window)
        case 50...69:
            tickLateFocus(view: view, window: window)
        default: break
        }
    }

    private func fixtureTrace(from offset: UInt64 = 0) -> String? {
        fflush(stderr)
        guard let file = try? FileHandle(forReadingFrom: traceURL) else { return nil }
        defer { try? file.close() }
        do {
            try file.seek(toOffset: offset)
            let data = try file.read(upToCount: 1_048_576) ?? Data()
            guard data.count < 1_048_576 else { return nil }
            return String(decoding: data, as: UTF8.self)
        } catch { return nil }
    }

    private func fixtureTraceEnd() -> UInt64? {
        fflush(stderr)
        guard let file = try? FileHandle(forReadingFrom: traceURL) else { return nil }
        defer { try? file.close() }
        return try? file.seekToEnd()
    }

    private func focusCallbackLines(_ trace: String) -> [String] {
        trace.split(separator: "\n").filter {
            $0.hasPrefix("[IME] callback_arrival insertText ") ||
                $0.hasPrefix("[IME] callback_arrival setMarkedText ") ||
                $0.hasPrefix("[IME] callback_arrival unmarkText ") ||
                $0.hasPrefix("[IME] callback_arrival doCommand ")
        }.map(String.init)
    }

    private func beginLateSwitch(code: UInt16, view: MaruMetalTerminalView, window: NSWindow) -> Bool {
        guard let offset = fixtureTraceEnd() else { return false }
        lateSwitchTraceOffset = offset
        lateQuietStarted = nil
        lateQuietSelection = nil
        lateQuietPreserved = true
        fputs("[IME_FOCUS] post code=\(code) owner=\(view.controller?.imeDiagnosticOwnerID ?? 0) t=\(ProcessInfo.processInfo.systemUptime)\n", stderr)
        fflush(stderr)
        return post(code, view: view, window: window, flags: [.maskCommand, .maskAlternate])
    }

    /// A successful focus round trip is distinct from observing a late OS callback. Keep the
    /// entire natural switch trace and separately count callbacks after the new owner was seen.
    private func settleLateSwitch(owner: UInt64, text: String, name: String,
                                  view: MaruMetalTerminalView) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let actualOwner = view.controller?.imeDiagnosticOwnerID
        if lateQuietStarted == nil {
            guard actualOwner == owner else { return false }
            fputs("[IME_FOCUS] observed owner=\(owner) t=\(now)\n", stderr)
            guard let offset = fixtureTraceEnd() else { return false }
            lateQuietStarted = now
            lateQuietTraceOffset = offset
            lateQuietSelection = view.selectedRange()
            observations.append("\(name)_owner=\(owner)")
        }
        lateQuietPreserved = lateQuietPreserved && actualOwner == owner && virtualText(view) == text &&
            view.selectedRange() == lateQuietSelection && !view.hasMarkedText()
        guard now - (lateQuietStarted ?? now) >= 0.6 else { return false }
        expect(lateQuietPreserved, "\(name)_settled_document_selection")
        observations.append("\(name)_text_actual=\(virtualText(view) ?? "<unavailable>")")
        observations.append("\(name)_caret_actual=\(view.selectedRange().location),\(view.selectedRange().length)")
        if let trace = fixtureTrace(from: lateSwitchTraceOffset),
           let quietTrace = fixtureTrace(from: lateQuietTraceOffset) {
            let callbacks = focusCallbackLines(trace)
            let quietCallbacks = focusCallbackLines(quietTrace)
            lateObservedCallbacks += quietCallbacks.count
            observations.append("\(name)_switch_callbacks=\(callbacks.joined(separator: " | "))")
            observations.append("\(name)_callbacks_after_observed_cutover=\(quietCallbacks.count)")
        } else { expect(false, "\(name)_callback_trace") }
        return true
    }

    /// Both tabs share one fixture document but keep their own caret. All composing keys and
    /// tab chords go through HID/TSM; no setMarkedText/insertText callback is injected here.
    private func tickLateFocus(view: MaruMetalTerminalView, window: NSWindow) {
        func failedInput() {
            failures.append("late_focus_input_unavailable")
            restoreInputSource(view: view)
            finish()
        }
        switch liveStep {
        case 50:
            guard let trace = fixtureTrace(),
                  let fixture = trace.split(separator: "\n").first(where: { $0.hasPrefix("[IME_FIXTURE] source=") }) else { return }
            let fields = fixture.split(separator: " ")
            guard let sourceField = fields.first(where: { $0.hasPrefix("source=") }),
                  let peerField = fields.first(where: { $0.hasPrefix("peer=") }),
                  let source = UInt64(sourceField.dropFirst(7)), let peer = UInt64(peerField.dropFirst(5)),
                  source != peer, view.controller?.imeDiagnosticOwnerID == source else { return }
            lateSourceID = source
            latePeerID = peer
            observations.append("late_focus_source=\(source)")
            observations.append("late_focus_peer=\(peer)")
            expect(virtualText(view) == "L R", "late_focus_shared_seed")
            var expected = LiveKeyExpectation(name: "late_focus_source_start", code: 123,
                                              text: "L R", caret: 0, composition: nil)
            expected.requiresCallback = false
            guard postLiveKey(expected, view: view, window: window, flags: .maskCommand) else { failedInput(); return }
            liveStep = 51
        case 51:
            guard postLiveKey(LiveKeyExpectation(name: "late_focus_source_position", code: 124,
                                                text: "L R", caret: 1, composition: nil), view: view, window: window) else { failedInput(); return }
            liveStep = 52
        case 52:
            guard postLiveKey(LiveKeyExpectation(name: "late_focus_source_initial", code: 15,
                                                text: "Lㄱ R", caret: 2, composition: NSRange(location: 1, length: 1)), view: view, window: window) else { failedInput(); return }
            liveStep = 53
        case 53:
            guard postLiveKey(LiveKeyExpectation(name: "late_focus_source_syllable", code: 40,
                                                text: "L가 R", caret: 2, composition: NSRange(location: 1, length: 1)), view: view, window: window) else { failedInput(); return }
            liveStep = 54
        case 54:
            expect(view.controller?.imeDiagnosticOwnerID == lateSourceID, "late_focus_source_before_switch")
            guard beginLateSwitch(code: 30, view: view, window: window) else { failedInput(); return }
            liveStep = 55
        case 55:
            guard let peer = latePeerID,
                  settleLateSwitch(owner: peer, text: "L가 R", name: "late_focus_peer", view: view) else { return }
            var expected = LiveKeyExpectation(name: "late_focus_peer_end", code: 124,
                                              text: "L가 R", caret: 4, composition: nil)
            expected.requiresCallback = false
            guard postLiveKey(expected, view: view, window: window, flags: .maskCommand) else { failedInput(); return }
            liveStep = 56
        case 56:
            guard postLiveKey(LiveKeyExpectation(name: "late_focus_peer_initial", code: 1,
                                                text: "L가 Rㄴ", caret: 5, composition: NSRange(location: 4, length: 1)), view: view, window: window) else { failedInput(); return }
            liveStep = 57
        case 57:
            guard postLiveKey(LiveKeyExpectation(name: "late_focus_peer_syllable", code: 40,
                                                text: "L가 R나", caret: 5, composition: NSRange(location: 4, length: 1)), view: view, window: window) else { failedInput(); return }
            liveStep = 58
        case 58:
            expect(view.controller?.imeDiagnosticOwnerID == latePeerID, "late_focus_peer_before_return")
            guard beginLateSwitch(code: 33, view: view, window: window) else { failedInput(); return }
            liveStep = 59
        case 59:
            guard let source = lateSourceID,
                  settleLateSwitch(owner: source, text: "L가 R나", name: "late_focus_return", view: view) else { return }
            range(view.selectedRange(), NSRange(location: 2, length: 0), "late_focus_source_caret_preserved")
            expect(virtualText(view) == "L가 R나", "late_focus_shared_exact_once")
            key(1, "s", view: view, window: window)
            liveStep = 60
        case 60:
            guard disk("L가 R나", "late_focus_shared_saved") else { return }
            restoreInputSource(view: view)
            finish()
        default: break
        }
    }

    /// Exercise the real Korean context at five positions beyond the first visual wrap row.
    /// Fixture seeding is a callback; composition, candidate request and confirmation use HID.
    private func tickWrappedCandidate(view: MaruMetalTerminalView, window: NSWindow) {
        guard ProcessInfo.processInfo.systemUptime >= candidateNotBefore else { return }
        let counts = SessionHostIMECandidateObservation.Counters(pty_input_bytes: 0, committed_text_callbacks: 0, base_screen_generation: 0)
        do {
            switch liveStep {
            case 30:
                guard CGPreflightScreenCaptureAccess() else { throw SessionHostIMECandidateObservation.Failure.invalidOutput }
                key(0, "a", view: view, window: window)
                view.insertText("", replacementRange: unspecified)
                // firstRect reports the current caret, rather than the proposed range. Measure
                // the empty document before moving it to the wrapped fixture position.
                candidateBaselineY = view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil).minY
                view.insertText(candidatePrefix, replacementRange: unspecified)
                expect(virtualText(view) == candidatePrefix, "wrapped_seed_\(candidateIndex)")
                liveStep = 31
            case 31...33:
                let letters = ["ㅎ", "하", "한"]
                let codes: [UInt16] = [5, 40, 1]
                let index = liveStep - 31
                let length = candidatePrefix.utf16.count
                guard postLiveKey(LiveKeyExpectation(name: "wrapped_compose_\(candidateIndex)_\(index)", code: codes[index], text: candidatePrefix + letters[index], caret: length + 1, composition: NSRange(location: length, length: 1)), view: view, window: window) else { throw SessionHostIMECandidateObservation.Failure.invalidOutput }
                liveStep += 1
            case 34:
                let anchor = view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil)
                expect(anchor.height > 0 && candidateBaselineY - anchor.minY >= anchor.height, "wrapped_visual_row_\(candidateIndex)")
                candidateBefore = try candidateObserver.capture(counters: counts, anchor: anchor)
                guard post(36, view: view, window: window, flags: .maskAlternate) else { throw SessionHostIMECandidateObservation.Failure.invalidOutput }
                candidateNotBefore = ProcessInfo.processInfo.systemUptime + 0.3
                liveStep = 35
            case 35:
                guard let before = candidateBefore else { throw SessionHostIMECandidateObservation.Failure.invalidOutput }
                let anchor = view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil)
                let opened = try candidateObserver.capture(counters: counts, anchor: anchor)
                candidateOpened = try candidateObserver.captureAppCandidate(before: before, opened: opened)
                guard let proof = candidateOpened?.app_captures.first,
                      let popup = opened.windows.first(where: { $0.id == proof.window_id }),
                      let display = opened.displays.first(where: { anchor.midX >= $0.appkit_frame.x && anchor.midX < $0.appkit_frame.x + $0.appkit_frame.w && anchor.midY >= $0.appkit_frame.y && anchor.midY < $0.appkit_frame.y + $0.appkit_frame.h }) else { throw SessionHostIMECandidateObservation.Failure.invalidOutput }
                let qx = display.quartz_bounds.x + anchor.minX - display.appkit_frame.x
                let qy = display.quartz_bounds.y + display.appkit_frame.y + display.appkit_frame.h - anchor.maxY
                let gap = max(0, max(popup.bounds.y - (qy + anchor.height), qy - (popup.bounds.y + popup.bounds.h)))
                expect(abs(popup.bounds.x - qx) <= anchor.height * 2 && gap <= anchor.height * 2, "wrapped_candidate_anchor_\(candidateIndex)")
                let encoded = try JSONEncoder().encode(proof)
                candidateEvidence.append(["window_id": proof.window_id, "app_capture": try JSONSerialization.jsonObject(with: encoded), "anchor_quartz": ["x": qx, "y": qy, "w": anchor.width, "h": anchor.height], "bounds": ["x": popup.bounds.x, "y": popup.bounds.y, "w": popup.bounds.w, "h": popup.bounds.h], "wrapped_delta_y": candidateBaselineY - anchor.minY])
                guard postLiveKey(LiveKeyExpectation(name: "wrapped_confirm_\(candidateIndex)", code: 36, text: candidatePrefix + "韓", caret: candidatePrefix.utf16.count + 1, composition: nil), view: view, window: window) else { throw SessionHostIMECandidateObservation.Failure.invalidOutput }
                candidateNotBefore = ProcessInfo.processInfo.systemUptime + 0.3
                liveStep = 36
            case 36:
                guard let before = candidateBefore, let opened = candidateOpened, let proof = opened.app_captures.first else { throw SessionHostIMECandidateObservation.Failure.invalidOutput }
                let closed = try candidateObserver.capture(counters: counts, anchor: view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil))
                expect(!closed.windows.contains(where: { $0.id == proof.window_id }), "wrapped_candidate_closed_\(candidateIndex)")
                expect(!view.hasMarkedText(), "wrapped_candidate_committed_\(candidateIndex)")
                try candidateObserver.append(before: before, opened: opened, closed: closed)
                key(1, "s", view: view, window: window)
                liveStep = 37
            case 37:
                guard disk(candidatePrefix + "韓", "wrapped_candidate_saved_\(candidateIndex)") else { return }
                candidateIndex += 1
                if candidateIndex < 5 { liveStep = 30; return }
                let root = URL(fileURLWithPath: outputPath).deletingLastPathComponent()
                let artifact: [String: Any] = ["schema": "maru.editor-ime-wrapped-candidate.v1", "source_id": SessionHostInputSourcePolicy.korean2SetSourceID, "rows": candidateEvidence]
                let data = try JSONSerialization.data(withJSONObject: artifact, options: [.sortedKeys])
                try data.write(to: root.appendingPathComponent("editor-wrapped-candidates.json"), options: .withoutOverwriting)
                restoreInputSource(view: view)
                finish()
            default: break
            }
        } catch {
            failures.append("wrapped_candidate_error:\(error)")
            restoreInputSource(view: view)
            finish()
        }
    }
}
