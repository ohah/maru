import Foundation

struct MermaidAcceptedPayload {
    let accepted: MaruMermaidAcceptedResult
    let svg: String
}

struct MermaidReplyKey: Hashable {
    let surfaceId: UInt64
    let jobId: UInt64
}

struct MermaidReplyIdentity: Equatable {
    let editorEpoch: UInt64
    let documentRevision: UInt64
    let projectionGeneration: UInt64
    let widgetId: UInt64
    let widgetGeneration: UInt64
    let rendererInstance: UInt64

    init(renderer: MaruMermaidRendererCapability) {
        editorEpoch = renderer.editor_epoch
        documentRevision = renderer.document_revision
        projectionGeneration = renderer.projection_generation
        widgetId = renderer.widget_id
        widgetGeneration = renderer.widget_generation
        rendererInstance = renderer.renderer_instance
    }

    init(
        editorEpoch: UInt64,
        documentRevision: UInt64,
        projectionGeneration: UInt64,
        widgetId: UInt64,
        widgetGeneration: UInt64,
        rendererInstance: UInt64
    ) {
        self.editorEpoch = editorEpoch
        self.documentRevision = documentRevision
        self.projectionGeneration = projectionGeneration
        self.widgetId = widgetId
        self.widgetGeneration = widgetGeneration
        self.rendererInstance = rendererInstance
    }
}

/// Product and native perf share exact pending lookup, identity validation, response construction, and
/// one-shot callback delivery. WebKit owns its internal IPC serialization; the perf callback serializes the
/// same response object explicitly so the exact 512 KiB main-actor payload cost is still bounded by the gate.
@MainActor
final class MermaidReplyDeliveryAdapter {
    typealias ReplyHandler = (Any?, String?) -> Void

    private struct Pending {
        let requestId: Any
        let identity: MermaidReplyIdentity
        let replyHandler: ReplyHandler
        let timeout: DispatchWorkItem
        var fallbackArmed: Bool
    }

    private let maxPending: Int
    private var pending: [MermaidReplyKey: Pending] = [:]

    init(maxPending: Int) {
        precondition(maxPending > 0)
        self.maxPending = maxPending
        pending.reserveCapacity(maxPending)
    }

    var count: Int { pending.count }

    func register(
        key: MermaidReplyKey,
        requestId: Any,
        identity: MermaidReplyIdentity,
        timeout: DispatchWorkItem,
        replyHandler: @escaping ReplyHandler
    ) -> Bool {
        guard pending.count < maxPending, pending[key] == nil else { return false }
        pending[key] = Pending(
            requestId: requestId,
            identity: identity,
            replyHandler: replyHandler,
            timeout: timeout,
            fallbackArmed: false
        )
        return true
    }

    /// Admission queue에서 기다린 시간은 Zig response deadline에 포함되지 않는다. 따라서 fallback도
    /// 실제 start action의 absolute deadline을 받은 뒤에만 arm하고, 그 전에는 pending reply를 보존한다.
    @discardableResult
    func armFallback(
        capability: MaruMermaidJobCapability,
        deadlineMs: UInt64,
        nowMs: UInt64,
        schedule: (Int, DispatchWorkItem) -> Void = { delayMs, item in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: item)
        }
    ) -> Bool {
        let identity = MermaidReplyIdentity(renderer: capability.renderer)
        guard let key = pending.first(where: {
            $0.key.jobId == capability.job_id && $0.value.identity == identity
        })?.key,
              var current = pending[key], !current.fallbackArmed else { return false }
        current.fallbackArmed = true
        pending[key] = current
        let grace = UInt64(MARU_MERMAID_REPLY_FALLBACK_GRACE_MS)
        let fallbackDeadline = deadlineMs.addingReportingOverflow(grace)
        let absolute = fallbackDeadline.overflow ? UInt64.max : fallbackDeadline.partialValue
        let remaining = absolute > nowMs ? absolute - nowMs : 0
        let delayMs = remaining > UInt64(Int.max) ? Int.max : Int(remaining)
        schedule(delayMs, current.timeout)
        return true
    }

    /// Product wiring and native smoke share this exact start-action seam. Keeping the binding beside the
    /// pending table prevents the app host from reimplementing when and how a fallback becomes armed.
    func bindFallback(
        to coordinator: MermaidRenderCoordinator,
        schedule: @escaping (Int, DispatchWorkItem) -> Void = { delayMs, item in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: item)
        }
    ) {
        coordinator.onStartJob = { [weak self] capability, deadlineMs, nowMs in
            _ = self?.armFallback(
                capability: capability,
                deadlineMs: deadlineMs,
                nowMs: nowMs,
                schedule: schedule
            )
        }
    }

    func deliver(
        _ payload: MermaidAcceptedPayload,
        onRevoke: (MermaidReplyKey, MermaidReplyIdentity) -> Void
    ) {
        let accepted = payload.accepted
        let key = MermaidReplyKey(surfaceId: accepted.window_id, jobId: accepted.capability.job_id)
        guard let current = pending[key] else { return }
        let actual = MermaidReplyIdentity(renderer: accepted.capability.renderer)
        guard actual == current.identity else {
            finish(
                key: key,
                svg: nil,
                error: "stale mermaid capability",
                revoke: true,
                onRevoke: onRevoke
            )
            return
        }
        finish(key: key, svg: payload.svg, error: nil, revoke: false, onRevoke: onRevoke)
    }

    func fail(
        capability: MaruMermaidJobCapability,
        error: String,
        onRevoke: (MermaidReplyKey, MermaidReplyIdentity) -> Void
    ) {
        let actual = MermaidReplyIdentity(renderer: capability.renderer)
        let matches = pending.compactMap { key, value in
            key.jobId == capability.job_id && value.identity == actual ? key : nil
        }
        for key in matches {
            finish(key: key, svg: nil, error: error, revoke: false, onRevoke: onRevoke)
        }
    }

    func finish(
        key: MermaidReplyKey,
        svg: String?,
        error: String?,
        revoke: Bool,
        onRevoke: (MermaidReplyKey, MermaidReplyIdentity) -> Void
    ) {
        guard let current = pending.removeValue(forKey: key) else { return }
        current.timeout.cancel()
        if revoke { onRevoke(key, current.identity) }
        if let svg {
            current.replyHandler([
                "jsonrpc": "2.0",
                "id": current.requestId,
                "result": ["job_id": key.jobId, "svg": svg],
            ], nil)
        } else {
            current.replyHandler(nil, error ?? "mermaid render failed")
        }
    }

    func finishMatching(
        surfaceId: UInt64,
        identity: MermaidReplyIdentity,
        error: String,
        onRevoke: (MermaidReplyKey, MermaidReplyIdentity) -> Void
    ) {
        let matches = pending.compactMap { key, value in
            key.surfaceId == surfaceId && value.identity == identity ? key : nil
        }
        for key in matches {
            finish(key: key, svg: nil, error: error, revoke: false, onRevoke: onRevoke)
        }
    }

    @discardableResult
    func finishExact(key: MermaidReplyKey, identity: MermaidReplyIdentity, error: String) -> Bool {
        guard pending[key]?.identity == identity else { return false }
        finish(key: key, svg: nil, error: error, revoke: false) { _, _ in }
        return true
    }

    @discardableResult
    func cancelSurface(
        _ surfaceId: UInt64,
        error: String,
        onRevoke: (MermaidReplyKey, MermaidReplyIdentity) -> Void
    ) -> Int {
        let matches = pending.keys.filter { $0.surfaceId == surfaceId }
        for key in matches {
            finish(key: key, svg: nil, error: error, revoke: true, onRevoke: onRevoke)
        }
        return matches.count
    }

    func cancelAll(error: String, onRevoke: (MermaidReplyKey, MermaidReplyIdentity) -> Void) {
        for key in Array(pending.keys) {
            finish(key: key, svg: nil, error: error, revoke: true, onRevoke: onRevoke)
        }
    }
}

/// Product and perf smoke share this exact ABI-copy and UTF-8 decoding path. Keeping the fixed buffer here makes
/// the accepted-byte cap and per-tick drain count concrete rather than allowing each caller to imitate it.
@MainActor
final class MermaidAcceptedResultDrainer {
    private var bytes = [UInt8](repeating: 0, count: Int(MARU_MERMAID_PROTOCOL_MAX_SVG_BYTES))
    private(set) var acceptedBytesMax: UInt64 = 0

    @discardableResult
    func drain(
        _ consume: (MermaidAcceptedPayload) -> Void,
        limit: Int = Int(MARU_MERMAID_MAX_COMPLETIONS_PER_TICK)
    ) -> Int {
        var drained = 0
        for _ in 0..<limit {
            var accepted = MaruMermaidAcceptedResult()
            let status = bytes.withUnsafeMutableBufferPointer {
                maru_macos_mermaid_take_accepted(&accepted, $0.baseAddress, $0.count)
            }
            guard status == 1 else { return drained }
            drained += 1
            guard accepted.svg_len <= bytes.count,
                  let svg = String(bytes: bytes[0..<accepted.svg_len], encoding: .utf8) else { continue }
            acceptedBytesMax = max(acceptedBytesMax, UInt64(accepted.svg_len))
            consume(MermaidAcceptedPayload(accepted: accepted, svg: svg))
        }
        return drained
    }

    @discardableResult
    func drainTerminals(_ consume: (MaruMermaidTerminalResult) -> Void) -> Int {
        var drained = 0
        for _ in 0..<Int(MARU_MERMAID_MAX_COMPLETIONS_PER_TICK) {
            var terminal = MaruMermaidTerminalResult()
            guard maru_macos_mermaid_take_terminal(&terminal) == 1 else { return drained }
            consume(terminal)
            drained += 1
        }
        return drained
    }
}

/// The single main-actor gate used by both the product display tick and the native performance smoke. Its inputs
/// are concrete product adapters, not arbitrary pump/drain closures. A source-policy gate rejects filesystem,
/// WebView construction, process/pipe, sleep, and blocking-wait APIs from this file.
@MainActor
final class MermaidProductTickAdapter {
    private(set) var tickCalls: UInt64 = 0
    private(set) var workTicks: UInt64 = 0
    private(set) var pumpCalls: UInt64 = 0
    private(set) var acceptedDrainCalls: UInt64 = 0
    private(set) var maxCompletionDrain: UInt64 = 0
    private(set) var maxElapsedMicroseconds: UInt64 = 0

    func tick(
        coordinator: MermaidRenderCoordinator,
        drainer: MermaidAcceptedResultDrainer,
        consume: (MermaidAcceptedPayload) -> Void,
        consumeTerminal: (MaruMermaidTerminalResult) -> Void
    ) {
        tickCalls &+= 1
        guard maru_macos_mermaid_has_work() != 0 else { return }
        let started = ProcessInfo.processInfo.systemUptime
        workTicks &+= 1
        pumpCalls &+= 1
        coordinator.pump()
        acceptedDrainCalls &+= 1
        let terminals = drainer.drainTerminals(consumeTerminal)
        let accepted = drainer.drain(consume, limit: Int(MARU_MERMAID_MAX_COMPLETIONS_PER_TICK) - terminals)
        maxCompletionDrain = max(maxCompletionDrain, UInt64(terminals + accepted))
        let elapsed = UInt64(max(0, (ProcessInfo.processInfo.systemUptime - started) * 1_000_000))
        maxElapsedMicroseconds = max(maxElapsedMicroseconds, elapsed)
    }
}
