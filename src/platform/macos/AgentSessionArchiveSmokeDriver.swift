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
        case claudeResumePointer = "claude-resume-pointer"

        init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
            guard let raw = environment["MARU_AGENT_SESSION_ARCHIVE_SMOKE_SCENARIO"] else { return nil }
            self.init(rawValue: raw)
        }
    }

    enum Shortcut {
        case resume
        case reveal
    }

    /// Renderer capture is deliberately a fixture observer, not an input/action path. The two
    /// sentinel scenarios capture the ready session list plus loading, ready, and stale detail
    /// states without multiplying every pointer/keyboard action scenario's GPU readback cost.
    enum CaptureState {
        case list
        case loading
        case ready
        case stale
    }

    enum Stage: String {
        case openDock
        case enterAgentSessions
        case waitForCard
        case waitForGate
        case observeLoading
        case waitForReady
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
        setGate: (Bool) -> Bool,
        gateReached: () -> Bool,
        click: (MaruAppHostAgentSessionArchiveSmokeProbe) -> Bool,
        shortcut: (Shortcut) -> Bool,
        fakeResumeVerdict: () -> Bool,
        revealAllowedCount: () -> UInt32,
        revealRejectedCount: () -> UInt32,
        staleRevealCount: () -> UInt32,
        claudeModelMetadataPresent: () -> Bool,
        replaceRevealSource: () -> Bool,
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
                if shouldCapture(.stale), !capture(.stale) {
                    fail("capture_stale")
                    return
                }
                stage = .succeeded
                return
            }
            guard detail.request_id != 0, detail.state == 2, detail.present != 0, detail.enabled != 0 else { return }
            stableReadyFrames += 1
            guard stableReadyFrames >= 2 else {
                paintRequested = true
                return
            }
            if shouldCapture(.ready), !capture(.ready) {
                fail("capture_ready")
                return
            }
            if scenario == .claudeResumePointer, !claudeModelMetadataPresent() {
                fail("claude_model_metadata")
                return
            }
            stage = .invokeAction

        case .invokeAction:
            switch scenario {
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
            case .detailStale:
                return
            }
            stage = .waitForAction
            paintRequested = true

        case .waitForAction:
            switch scenario {
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
            case .detailStale:
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

    private func shouldCapture(_ state: CaptureState) -> Bool {
        switch (scenario, state) {
        case (.resumePointer, .list), (.resumePointer, .loading), (.resumePointer, .ready), (.detailStale, .loading), (.detailStale, .stale):
            return true
        default:
            return false
        }
    }
}
