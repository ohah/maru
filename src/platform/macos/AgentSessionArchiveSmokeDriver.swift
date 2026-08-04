import Foundation

/// AS4-c의 AppKit-side state machine. 이 타입은 fixture 좌표를 계산하거나 Zig state를
/// 변경하지 않는다. host가 제공한 read-only published probe와 실제 NSView event closure만
/// 소비해, 일반 사용자와 같은 dock-switcher → card pointer 경로를 재현한다.
@MainActor
final class AgentSessionArchiveSmokeDriver {
    /// Each process exercises one physical input source.  Keeping pointer and keyboard in
    /// separate cold processes prevents a newly spawned resume terminal or a consumed reveal
    /// one-shot from accidentally satisfying the other route.
    enum Scenario: String {
        case resumePointer = "resume-pointer"
        case resumeKeyboard = "resume-keyboard"
        case revealPointer = "reveal-pointer"
        case revealKeyboard = "reveal-keyboard"
        case revealRecheckPointer = "reveal-recheck-pointer"
        case detailStale = "detail-stale"
        case detailCloseReopen = "detail-close-reopen"
        case snapshotReplacePointer = "snapshot-replace-pointer"
        case expandedScrollAnchor = "expanded-scroll-anchor"
        case fontScaleRects = "font-scale-rects"
        case fontZoom = "font-zoom"
        case claudeResumePointer = "claude-resume-pointer"

        init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
            guard let raw = environment["MARU_AGENT_SESSION_ARCHIVE_SMOKE_SCENARIO"] else { return nil }
            self.init(rawValue: raw)
        }
    }

    enum Shortcut {
        case resume
        case reveal
        case increaseFont
        case decreaseFont
    }

    /// Renderer capture is deliberately a fixture observer, not an input/action path. The two
    /// sentinel scenarios capture the ready session list plus loading, ready, and stale detail
    /// states without multiplying every pointer/keyboard action scenario's GPU readback cost.
    enum CaptureState {
        case list
        case loading
        case ready
        case stale
        case scrollAnchorBefore
        case scrollAnchorAfter
    }

    /// A narrow read-only witness for AS4-d. The fixture never receives a Term pointer or any
    /// archive content: it only compares the active terminal identity and global Term count
    /// across the ordinary dock-card click and detached detail read.
    struct TerminalInvariant: Equatable {
        let activeSurfaceId: UInt64
        let termCount: UInt32
    }

    enum Stage: String {
        case openDock
        case enterAgentSessions
        case waitForCard
        case waitForGate
        case observeLoading
        case waitForReady
        case closeDetail
        case waitForClosed
        case waitForReopenGate
        case observeReopenLoading
        case waitForReopenReady
        case startSnapshotRefresh
        case waitForSnapshotGate
        case holdOldResume
        case waitForSnapshotReplacement
        case releaseStalePointer
        case waitForStalePointer
        case scrollExpandedAnchor
        case waitForExpandedAnchorBefore
        case startExpandedAnchorRefresh
        case waitForExpandedAnchorGate
        case waitForExpandedAnchorAfter
        case waitForFontZoomIncrease
        case waitForFontZoomReset
        case waitForFontZoomDecrease
        case invokeAction
        case waitForAction
        case succeeded
        case failed
    }

    private(set) var stage: Stage = .openDock
    private(set) var failure = ""
    private let deadline: TimeInterval
    private let scenario: Scenario
    private var paintRequested = false
    /// The Session Dock's immutable system-text artifact is published by a detached worker.
    /// A card probe proves geometry/input publication, but one additional ordinary frame proves
    /// the screenshot is not the intentional first-frame skeleton before rich text arrives.
    private var stableListFrames = 0
    /// Detail data and its measured Korean/SVG action content are produced independently.  The
    /// action probe becomes ready with the detail DTO; wait through one regular worker-poll frame
    /// before recording the ready detail so the artifact is part of the captured product frame.
    private var stableReadyFrames = 0
    private var stableReopenReadyFrames = 0
    /// The same-card toggle must revoke the prior detail capability before it starts the next
    /// request. Keeping only the opaque request id proves that no old ready action is reused.
    private var firstDetailRequestId: UInt64?
    /// This is a copy of an already-published backing rect, never an action token. The fixture
    /// sends down before replacement and the matching up only after the normal product refresh
    /// has invalidated the prior tree.
    private var stalePointerProbe: MaruAppHostAgentSessionArchiveSmokeProbe?
    /// Both are raw, un-clipped outer-card rects. A clipped visible rect would be pinned to the
    /// content edge and falsely pass even if refresh lost the intra-card scroll position.
    private var expandedAnchorBefore: MaruAppHostAgentSessionArchiveSmokeProbe?
    /// A fixed, fully visible control is the geometry witness for Cmd zoom. The inline resume
    /// action can legitimately be clipped by the scroll viewport, in which case its visible
    /// height is not its component metric and is therefore unsuitable for a scale assertion.
    private var fontZoomBaselineScopeHeight: Float?
    private var terminalBaseline: TerminalInvariant?
    private(set) var terminalInvariantSatisfied = false
    private(set) var scrollDispatched = false
    private(set) var anchorBeforePresent = false
    private(set) var anchorAfterPresent = false
    private(set) var anchorRawTopPreserved = false
    private(set) var anchorSnapshotReordered = false
    private(set) var anchorNewGenerationPublished = false

    init?(
        scenario: Scenario? = Scenario(environment: ProcessInfo.processInfo.environment),
        now: TimeInterval = ProcessInfo.processInfo.systemUptime,
        timeout: TimeInterval = 12
    ) {
        guard let scenario else { return nil }
        self.scenario = scenario
        deadline = now + timeout
    }

    var finished: Bool { stage == .succeeded || stage == .failed }
    var scenarioName: String { scenario.rawValue }

    /// Pointer input mutates Zig state after the host has completed its normal frame tick.  Ask
    /// the host for one immediate ordinary render so the next probe can only observe a published
    /// frame, not wait for a quiescent timer to happen to repaint it.
    func takePaintRequest() -> Bool {
        defer { paintRequested = false }
        return paintRequested
    }

    /// The caller owns every side effect: ABI reads, smoke-gate arm/release, and AppKit event
    /// dispatch. This keeps the driver's decision graph unit-testable and prevents it from
    /// becoming a second UI/action authority.
    func tick(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime,
        probe: (UInt32) -> MaruAppHostAgentSessionArchiveSmokeProbe?,
        sessionInvariant: () -> TerminalInvariant?,
        setGate: (Bool) -> Bool,
        gateReached: () -> Bool,
        setScanGate: (Bool) -> Bool,
        scanGateReached: () -> Bool,
        click: (MaruAppHostAgentSessionArchiveSmokeProbe) -> Bool,
        pointerDown: (MaruAppHostAgentSessionArchiveSmokeProbe) -> Bool,
        pointerUp: (MaruAppHostAgentSessionArchiveSmokeProbe) -> Bool,
        preciseScroll: (MaruAppHostAgentSessionArchiveSmokeProbe) -> Bool,
        shortcut: (Shortcut) -> Bool,
        fakeResumeVerdict: () -> Bool,
        revealAllowedCount: () -> UInt32,
        revealRejectedCount: () -> UInt32,
        staleRevealCount: () -> UInt32,
        claudeModelMetadataPresent: () -> Bool,
        replaceRevealSource: () -> Bool,
        reorderArchiveSnapshot: () -> Bool,
        captureGeometry: () -> Bool,
        capture: (CaptureState) -> Bool
    ) {
        guard !finished else { return }
        guard now <= deadline else {
            fail("timeout_\(stage.rawValue)")
            return
        }

        switch stage {
        case .openDock:
            guard let launcher = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_DOCK_LAUNCHER), launcher.present != 0, launcher.enabled != 0 else { return }
            guard click(launcher) else { fail("dock_launcher_click") ; return }
            stage = .enterAgentSessions
            paintRequested = true

        case .enterAgentSessions:
            guard let dock = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_DOCK_AGENT_SESSIONS), dock.present != 0, dock.enabled != 0 else { return }
            guard click(dock) else { fail("dock_click") ; return }
            stage = .waitForCard
            paintRequested = true

        case .waitForCard:
            guard let card = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_DOCK_CARD), card.present != 0, card.enabled != 0 else { return }
            stableListFrames += 1
            guard stableListFrames >= 2 else {
                paintRequested = true
                return
            }
            // Capture the fully published SessionDock before the ordinary card click leaves the
            // list. This is visual evidence for the right-dock list geometry, not an alternate
            // activation path: the next two lines still arm the detail gate and use the same
            // pointer event as a user.
            if shouldCapture(.list), !capture(.list) {
                fail("capture_list")
                return
            }
            guard let baseline = sessionInvariant(), baseline.activeSurfaceId != 0, baseline.termCount != 0 else {
                fail("terminal_baseline")
                return
            }
            terminalBaseline = baseline
            guard setGate(true) else { fail("gate_arm") ; return }
            guard click(card) else { fail("card_click") ; return }
            stage = .waitForGate
            paintRequested = true

        case .waitForGate:
            if gateReached() { stage = .observeLoading }

        case .observeLoading:
            guard let detail = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_RESUME) else { return }
            // Loading paints the same resume card geometry as ready, but its published action is
            // explicitly disabled.  This proves both the loading detail and its non-executable
            // capability boundary were presented before the worker is released.
            guard detail.request_id != 0, detail.state == 1, detail.present != 0, detail.enabled == 0 else { return }
            guard matchesTerminalBaseline(sessionInvariant()) else {
                fail("inline_detail_changed_terminal_loading")
                return
            }
            // The stale scenario mutates only the synthetic source after the completed loading
            // tree is visible and before the worker's no-follow read. This is the TOCTOU window
            // the detail backend must close; normal scenarios release without a replacement.
            if shouldCapture(.loading), !capture(.loading) {
                fail("capture_loading")
                return
            }
            if scenario == .detailStale, !replaceRevealSource() {
                fail("stale_replace")
                return
            }
            guard setGate(false) else { fail("gate_release") ; return }
            stage = .waitForReady

        case .waitForReady:
            guard let detail = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_RESUME) else { return }
            if scenario == .detailStale {
                guard detail.request_id != 0, detail.state == 3, detail.present != 0, detail.enabled == 0,
                      let reveal = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_REVEAL_LOG),
                      reveal.request_id == detail.request_id, reveal.state == 3, reveal.present != 0, reveal.enabled == 0
                else { return }
                guard matchesTerminalBaseline(sessionInvariant()) else {
                    fail("inline_detail_changed_terminal_stale")
                    return
                }
                if shouldCapture(.stale), !capture(.stale) {
                    fail("capture_stale")
                    return
                }
                terminalInvariantSatisfied = true
                stage = .succeeded
                return
            }
            guard detail.request_id != 0, detail.state == 2, detail.present != 0, detail.enabled != 0 else { return }
            guard matchesTerminalBaseline(sessionInvariant()) else {
                fail("inline_detail_changed_terminal_ready")
                return
            }
            stableReadyFrames += 1
            guard stableReadyFrames >= 2 else {
                paintRequested = true
                return
            }
            if shouldCapture(.ready), !capture(.ready) {
                fail("capture_ready")
                return
            }
            terminalInvariantSatisfied = true
            if scenario == .claudeResumePointer, !claudeModelMetadataPresent() {
                fail("claude_model_metadata")
                return
            }
            if scenario == .detailCloseReopen {
                firstDetailRequestId = detail.request_id
                stage = .closeDetail
                paintRequested = true
                return
            }
            if scenario == .snapshotReplacePointer {
                stage = .startSnapshotRefresh
                paintRequested = true
                return
            }
            if scenario == .expandedScrollAnchor {
                stage = .scrollExpandedAnchor
                paintRequested = true
                return
            }
            if scenario == .fontScaleRects {
                guard captureGeometry() else {
                    fail("font_scale_geometry")
                    return
                }
                stage = .succeeded
                return
            }
            if scenario == .fontZoom {
                guard let scope = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_SCOPE_ROW),
                      scope.present != 0, scope.height_px > 0
                else { return }
                fontZoomBaselineScopeHeight = scope.height_px
                guard shortcut(.increaseFont) else {
                    fail("font_zoom_increase_shortcut")
                    return
                }
                stage = .waitForFontZoomIncrease
                paintRequested = true
                return
            }
            stage = .invokeAction

        case .waitForFontZoomIncrease:
            guard let baseline = fontZoomBaselineScopeHeight,
                  let scope = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_SCOPE_ROW),
                  scope.present != 0, scope.height_px > baseline
            else { return }
            guard shortcut(.decreaseFont) else {
                fail("font_zoom_reset_shortcut")
                return
            }
            stage = .waitForFontZoomReset
            paintRequested = true

        case .waitForFontZoomReset:
            guard let baseline = fontZoomBaselineScopeHeight,
                  let scope = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_SCOPE_ROW),
                  scope.present != 0, scope.height_px == baseline
            else { return }
            guard shortcut(.decreaseFont) else {
                fail("font_zoom_decrease_shortcut")
                return
            }
            stage = .waitForFontZoomDecrease
            paintRequested = true

        case .waitForFontZoomDecrease:
            guard let baseline = fontZoomBaselineScopeHeight,
                  let scope = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_SCOPE_ROW),
                  scope.present != 0, scope.height_px < baseline
            else { return }
            guard matchesTerminalBaseline(sessionInvariant()) else {
                fail("inline_detail_changed_terminal_font_zoom")
                return
            }
            terminalInvariantSatisfied = true
            stage = .succeeded

        case .closeDetail:
            // Use the exact same published card capability that opened the detail. This is an
            // ordinary mouse lifecycle, so the test cannot close an inline disclosure through a
            // private AppSession shortcut.
            guard let card = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_DOCK_CARD),
                  card.present != 0, card.enabled != 0,
                  click(card) else { return }
            stage = .waitForClosed
            paintRequested = true

        case .waitForClosed:
            guard let card = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_DOCK_CARD),
                  card.present != 0, card.enabled != 0,
                  let resume = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_RESUME),
                  let reveal = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_REVEAL_LOG),
                  resume.request_id == 0, resume.present == 0,
                  reveal.request_id == 0, reveal.present == 0
            else { return }
            guard matchesTerminalBaseline(sessionInvariant()) else {
                fail("inline_detail_changed_terminal_closed")
                return
            }
            // The next ordinary card click must create a fresh worker request. Arm the fixture
            // gate before that physical click so loading is observable rather than racing ready.
            guard setGate(true), click(card) else {
                fail("reopen_card_click")
                return
            }
            stage = .waitForReopenGate
            paintRequested = true

        case .waitForReopenGate:
            if gateReached() { stage = .observeReopenLoading }

        case .observeReopenLoading:
            guard let detail = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_RESUME),
                  let firstDetailRequestId,
                  detail.request_id != 0, detail.request_id != firstDetailRequestId,
                  detail.state == 1, detail.present != 0, detail.enabled == 0
            else { return }
            guard matchesTerminalBaseline(sessionInvariant()) else {
                fail("inline_detail_changed_terminal_reopen_loading")
                return
            }
            guard setGate(false) else {
                fail("reopen_gate_release")
                return
            }
            stage = .waitForReopenReady

        case .waitForReopenReady:
            guard let detail = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_RESUME),
                  let firstDetailRequestId,
                  detail.request_id != 0, detail.request_id != firstDetailRequestId,
                  detail.state == 2, detail.present != 0, detail.enabled != 0
            else { return }
            guard matchesTerminalBaseline(sessionInvariant()) else {
                fail("inline_detail_changed_terminal_reopen_ready")
                return
            }
            stableReopenReadyFrames += 1
            guard stableReopenReadyFrames >= 2 else {
                paintRequested = true
                return
            }
            terminalInvariantSatisfied = true
            stage = .succeeded

        case .startSnapshotRefresh:
            // Only the ordinary published header control can submit the scan. Arm the test gate
            // first so the retained ready snapshot remains observable after this physical click.
            guard let refresh = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_REFRESH),
                  refresh.present != 0, refresh.enabled != 0,
                  setScanGate(true), click(refresh)
            else {
                fail("snapshot_refresh_click")
                return
            }
            stage = .waitForSnapshotGate
            paintRequested = true

        case .waitForSnapshotGate:
            if scanGateReached() { stage = .holdOldResume }

        case .holdOldResume:
            // The old ready capability is still the retained completed snapshot. Hold only its
            // ordinary pointer capture; no action may execute on down.
            guard let detail = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_RESUME),
                  detail.request_id != 0, detail.state == 2, detail.present != 0, detail.enabled != 0,
                  pointerDown(detail)
            else {
                fail("snapshot_old_resume_down")
                return
            }
            stalePointerProbe = detail
            guard replaceRevealSource(), setScanGate(false) else {
                fail("snapshot_replace_or_release")
                return
            }
            stage = .waitForSnapshotReplacement
            paintRequested = true

        case .waitForSnapshotReplacement:
            // A same-provider/session replacement with a different inode turns this disclosure
            // stale. Selection is exact-identity based, so the replacement card must not
            // materialize the old detail capability at all; the prior capture must already have
            // been cancelled before the next pointer up reaches product routing.
            guard let detail = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_RESUME),
                  detail.request_id != 0, detail.state == 3, detail.present == 0, detail.enabled == 0
            else { return }
            guard matchesTerminalBaseline(sessionInvariant()) else {
                fail("snapshot_replace_changed_terminal")
                return
            }
            stage = .releaseStalePointer

        case .releaseStalePointer:
            guard let stalePointerProbe, pointerUp(stalePointerProbe) else {
                fail("snapshot_old_resume_up")
                return
            }
            stage = .waitForStalePointer
            paintRequested = true

        case .waitForStalePointer:
            guard !fakeResumeVerdict(), revealAllowedCount() == 0, revealRejectedCount() == 0,
                  staleRevealCount() == 0, matchesTerminalBaseline(sessionInvariant())
            else {
                fail("snapshot_stale_up_executed")
                return
            }
            terminalInvariantSatisfied = true
            stage = .succeeded

        case .scrollExpandedAnchor:
            // Wheel coordinates come from the already-painted ordinary card capability. The
            // closure sends a genuine NSView scrollWheel event; it does not call Zig's scroll
            // method or mutate the dock state through a test seam.
            guard let card = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_DOCK_CARD),
                  card.present != 0, card.enabled != 0,
                  preciseScroll(card)
            else {
                fail("expanded_anchor_scroll")
                return
            }
            scrollDispatched = true
            stage = .waitForExpandedAnchorBefore
            paintRequested = true

        case .waitForExpandedAnchorBefore:
            guard let anchor = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_EXPANDED_SCROLL_ANCHOR),
                  anchor.request_id != 0, anchor.state == 2, anchor.present != 0,
                  anchor.generation != 0,
                  anchor.height_px > 0
            else { return }
            expandedAnchorBefore = anchor
            anchorBeforePresent = true
            if !capture(.scrollAnchorBefore) {
                fail("capture_expanded_anchor_before")
                return
            }
            stage = .startExpandedAnchorRefresh
            paintRequested = true

        case .startExpandedAnchorRefresh:
            // Normal refresh is the only worker admission. The bounded gate simply makes the
            // retained completed tree observable before the fixture changes the independent
            // record's mtime to reorder the next immutable snapshot.
            guard let refresh = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_REFRESH),
                  refresh.present != 0, refresh.enabled != 0,
                  setScanGate(true), click(refresh)
            else {
                fail("expanded_anchor_refresh")
                return
            }
            stage = .waitForExpandedAnchorGate
            paintRequested = true

        case .waitForExpandedAnchorGate:
            guard scanGateReached(), let before = expandedAnchorBefore,
                  let retained = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_EXPANDED_SCROLL_ANCHOR),
                  retained.request_id == before.request_id, retained.present != 0,
                  retained.generation == before.generation,
                  retained.y_px == before.y_px
            else { return }
            guard reorderArchiveSnapshot(), setScanGate(false) else {
                fail("expanded_anchor_reorder_or_release")
                return
            }
            anchorSnapshotReordered = true
            stage = .waitForExpandedAnchorAfter
            paintRequested = true

        case .waitForExpandedAnchorAfter:
            guard let before = expandedAnchorBefore,
                  let after = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_EXPANDED_SCROLL_ANCHOR),
                  after.request_id == before.request_id, after.state == 2, after.present != 0,
                  after.generation != before.generation,
                  after.height_px == before.height_px
            else { return }
            anchorAfterPresent = true
            anchorNewGenerationPublished = true
            guard after.y_px == before.y_px else {
                fail("expanded_anchor_raw_top_changed")
                return
            }
            guard matchesTerminalBaseline(sessionInvariant()) else {
                fail("expanded_anchor_changed_terminal")
                return
            }
            anchorRawTopPreserved = true
            if !capture(.scrollAnchorAfter) {
                fail("capture_expanded_anchor_after")
                return
            }
            terminalInvariantSatisfied = true
            stage = .succeeded

        case .invokeAction:
            switch scenario {
            case .fontScaleRects, .fontZoom:
                fail("font_scale_unreachable_action")
                return
            case .resumePointer, .claudeResumePointer:
                guard let detail = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_RESUME),
                      detail.present != 0, detail.enabled != 0,
                      click(detail) else { return }
            case .resumeKeyboard:
                guard let detail = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_RESUME),
                      detail.present != 0, detail.enabled != 0,
                      shortcut(.resume) else { return }
            case .revealPointer:
                guard let detail = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_REVEAL_LOG),
                      detail.present != 0, detail.enabled != 0,
                      click(detail) else { return }
            case .revealKeyboard:
                guard let detail = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_REVEAL_LOG),
                      detail.present != 0, detail.enabled != 0,
                      shortcut(.reveal) else { return }
            case .revealRecheckPointer:
                // Replace after the ready action tree has been published, then use the ordinary
                // pointer route. The click must reach the no-follow identity recheck before it
                // can publish an external-open one-shot.
                guard replaceRevealSource(),
                      let detail = probe(MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_REVEAL_LOG),
                      detail.present != 0, detail.enabled != 0,
                      click(detail) else { return }
            case .detailStale, .detailCloseReopen, .snapshotReplacePointer, .expandedScrollAnchor:
                return
            }
            stage = .waitForAction
            paintRequested = true

        case .waitForAction:
            switch scenario {
            case .fontScaleRects, .fontZoom:
                fail("font_scale_unreachable_wait")
                return
            case .resumePointer, .resumeKeyboard, .claudeResumePointer:
                guard fakeResumeVerdict() else { return }
            case .revealPointer, .revealKeyboard:
                guard revealAllowedCount() == 1 else { return }
            case .revealRecheckPointer:
                // The stale source is rejected in Zig before the shared external-open consumer
                // is populated. An unexpected host allowlist rejection is a fixture failure too.
                guard revealAllowedCount() == 0,
                      revealRejectedCount() == 0,
                      staleRevealCount() == 1 else { return }
            case .detailStale, .detailCloseReopen, .snapshotReplacePointer, .expandedScrollAnchor:
                return
            }
            stage = .succeeded

        case .succeeded, .failed:
            return
        }
    }

    private func fail(_ reason: String) {
        failure = reason
        stage = .failed
    }

    private func matchesTerminalBaseline(_ observed: TerminalInvariant?) -> Bool {
        guard let terminalBaseline, let observed else { return false }
        return observed == terminalBaseline
    }

    private func shouldCapture(_ state: CaptureState) -> Bool {
        switch (scenario, state) {
        case (.resumePointer, .list), (.resumePointer, .loading), (.resumePointer, .ready), (.detailStale, .loading), (.detailStale, .stale):
            return true
        default:
            return false
        }
    }
}
