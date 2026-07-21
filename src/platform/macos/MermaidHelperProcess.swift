import Foundation
import Security
import Darwin

/// Process/pipe 실행만 담당한다. admission, coalesce, deadline, failure latch는 Zig
/// `AppRuntime.mermaid_queue`가 만든 action/completion API가 유일한 권위다.
extension MaruMermaidCoordinatorAction: @retroactive @unchecked Sendable {}

final class MermaidRenderCoordinator: @unchecked Sendable {
    /// Reply fallback은 admission 시점이 아니라 Zig가 정한 exact action deadline에 결박한다.
    /// `pump`의 main-thread start branch에서만 호출되고 executor는 이 closure를 보지 않는다.
    var onStartJob: ((MaruMermaidJobCapability, UInt64, UInt64) -> Void)?
    /// `pump`가 main thread에서 Zig terminal 판정을 끝낸 뒤 제품 shell에 range-local 실패를 알린다.
    /// process/I/O executor는 이 closure를 직접 호출하지 않는다.
    var onRenderError: ((MaruMermaidJobCapability) -> Void)?
    enum Validation {
        case productionBundle
        case smoke(URL)
        case smokeNoRead(URL)
        case smokeClosedPipes(URL)
        case smokeDelayedStart(URL, delayMs: UInt64)
        case smokeDelayedResult(URL, delayMs: UInt64)
        case smokePathABA(URL, replacement: URL)
    }

    struct Diagnostics {
        let physicalStarts: UInt64
        let helloFrames: UInt64
        let requestFrames: UInt64
        let shutdownProbeCallbacks: UInt64
        let pendingControls: Int
        let pumpCalls: UInt64
        let maxCompletionDrain: UInt64
        let mainThreadProcessOperations: UInt64
        let mainThreadPipeSetups: UInt64
        let mainThreadPipeIO: UInt64
        let mainThreadBlockingWaits: UInt64
        let abaRestoreSuccesses: UInt64
    }

    private struct ResultCompletion {
        let capability: MaruMermaidJobCapability
        let status: UInt32
        let body: Data
        let arrivalMs: UInt64
    }

    /// Result payload backpressure와 분리된 유실 불가능 control lane이다. 물리 helper와 leased
    /// action은 각각 하나뿐이므로 각 exact identity를 fixed slot 하나로 보존할 수 있다.
    private struct ControlLane {
        var actionConsumed: (helper: UInt64, job: UInt64)?
        var integrityFailure: UInt64?
        var transientFailure: UInt64?
        var termination: UInt64?
    }

    private final class Running: @unchecked Sendable {
        let helperInstance: UInt64
        let process: Process
        let input: FileHandle
        let output: FileHandle
        let error: FileHandle
        let decoder: MermaidProtocolDecoder
        private let lifecycleLock = NSLock()
        private var active = true
        private var expectedTermination = false

        // 아래 필드는 ioExecutor에서만 접근한다.
        var expectedNonce: UInt64?
        var pendingRequest: Data?
        var stderrRing = Data()
        var pendingWrites: [Data] = []
        var writeOffset = 0
        var writeSource: DispatchSourceWrite?
        var outputSource: DispatchSourceRead?
        var errorSource: DispatchSourceRead?

        init(
            helperInstance: UInt64,
            process: Process,
            input: FileHandle,
            output: FileHandle,
            error: FileHandle,
            decoder: MermaidProtocolDecoder
        ) {
            self.helperInstance = helperInstance
            self.process = process
            self.input = input
            self.output = output
            self.error = error
            self.decoder = decoder
            stderrRing.reserveCapacity(64 * 1024)
            pendingWrites.reserveCapacity(2)
        }

        func isActive() -> Bool {
            lifecycleLock.lock()
            defer { lifecycleLock.unlock() }
            return active
        }

        func deactivate(expected: Bool) {
            lifecycleLock.lock()
            active = false
            if expected { expectedTermination = true }
            lifecycleLock.unlock()
        }

        func markExpectedTermination() {
            lifecycleLock.lock()
            expectedTermination = true
            lifecycleLock.unlock()
        }

        func wasExpectedTermination() -> Bool {
            lifecycleLock.lock()
            defer { lifecycleLock.unlock() }
            return expectedTermination
        }
    }

    private struct CodeIdentity: Equatable {
        let cdHash: Data
        let identifier: String?
        let teamIdentifier: String?
    }

    private struct HelperFileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let code: CodeIdentity
    }

    private let validation: Validation
    private let controlExecutor = DispatchQueue(label: "app.maru.mermaid-helper.control")
    private let ioExecutor = DispatchQueue(label: "app.maru.mermaid-helper.io")
    private let completionLock = NSLock()
    private var results: [ResultCompletion] = []
    private var resultDrain: [ResultCompletion] = []
    private var resultBytes = 0
    private var controls = ControlLane()
    private var stdoutEOFCount: UInt64 = 0
    private var stderrEOFCount: UInt64 = 0
    private var physicalStartCount: UInt64 = 0
    private var helloFrameCount: UInt64 = 0
    private var requestFrameCount: UInt64 = 0
    private var shutdownProbeCallbackCount: UInt64 = 0
    private var pumpCallCount: UInt64 = 0
    private var maxCompletionDrainCount: UInt64 = 0
    private var mainThreadProcessOperationCount: UInt64 = 0
    private var mainThreadPipeSetupCount: UInt64 = 0
    private var mainThreadPipeIOCount: UInt64 = 0
    private var mainThreadBlockingWaitCount: UInt64 = 0
    private var abaRestoreSuccessCount: UInt64 = 0
    private var pumpActive = false
    private var running: Running? // controlExecutor-owned
    private var shuttingDown = false // controlExecutor-owned
    private(set) var staleResultCount: UInt64 = 0
    private(set) var terminalResultCount: UInt64 = 0
    private(set) var terminationAckCount: UInt64 = 0

    init(validation: Validation = .productionBundle) {
        self.validation = validation
        results.reserveCapacity(Int(MARU_MERMAID_MAX_COMPLETIONS_PER_TICK))
        resultDrain.reserveCapacity(Int(MARU_MERMAID_MAX_COMPLETIONS_PER_TICK))
    }

    func pipeEOFCounts() -> (stdout: UInt64, stderr: UInt64) {
        completionLock.lock()
        defer { completionLock.unlock() }
        return (stdoutEOFCount, stderrEOFCount)
    }

    func diagnostics() -> Diagnostics {
        completionLock.lock()
        defer { completionLock.unlock() }
        return Diagnostics(
            physicalStarts: physicalStartCount,
            helloFrames: helloFrameCount,
            requestFrames: requestFrameCount,
            shutdownProbeCallbacks: shutdownProbeCallbackCount,
            pendingControls: [
                controls.actionConsumed != nil,
                controls.integrityFailure != nil,
                controls.transientFailure != nil,
                controls.termination != nil,
            ].filter { $0 }.count,
            pumpCalls: pumpCallCount,
            maxCompletionDrain: maxCompletionDrainCount,
            mainThreadProcessOperations: mainThreadProcessOperationCount,
            mainThreadPipeSetups: mainThreadPipeSetupCount,
            mainThreadPipeIO: mainThreadPipeIOCount,
            mainThreadBlockingWaits: mainThreadBlockingWaitCount,
            abaRestoreSuccesses: abaRestoreSuccessCount
        )
    }

    func stderrTail() -> String {
        controlExecutor.sync {
            guard let running else { return "" }
            return ioExecutor.sync { String(decoding: running.stderrRing, as: UTF8.self) }
        }
    }

    func scheduleShutdownBarrierProbe() {
        ioExecutor.async { [weak self] in
            guard let self else { return }
            usleep(25_000)
            self.completionLock.lock()
            self.shutdownProbeCallbackCount += 1
            self.completionLock.unlock()
            self.enqueueFailure(helper: 999, integrity: true)
            self.controlExecutor.async {
                self.completionLock.lock()
                self.shutdownProbeCallbackCount += 1
                self.completionLock.unlock()
                self.enqueueTermination(helper: 999)
            }
        }
    }

    /// display tick에서는 fixed coordinator action 하나를 enqueue하고 completion 최대 8개만 drain한다.
    /// spawn/signature/termination은 control executor, bounded pipe read/write는 별도 I/O executor다.
    func pump(nowMs: UInt64 = MermaidRenderCoordinator.monotonicMilliseconds()) {
        precondition(Thread.isMainThread)
        pumpActive = true
        defer { pumpActive = false }
        pumpCallCount += 1
        drainCompletions(nowMs: nowMs)
        _ = maru_macos_mermaid_expire_deadline(nowMs)

        var action = MaruMermaidCoordinatorAction()
        guard maru_macos_mermaid_drain_action(nowMs, &action) == 1 else { return }
        switch action.kind {
        case UInt32(MARU_MERMAID_ACTION_TERMINATE_HELPER):
            let helper = action.capability.helper_instance
            controlExecutor.async { [weak self] in self?.terminate(helperInstance: helper) }
        case UInt32(MARU_MERMAID_ACTION_START_JOB):
            onStartJob?(action.capability, action.deadline_ms, nowMs)
            controlExecutor.async { [weak self] in
                guard let self else { return }
                var copiedAction = action
                self.start(action: &copiedAction)
            }
        default:
            break
        }
    }

    func shutdown() {
        controlExecutor.sync {
            shuttingDown = true
            if let running {
                running.deactivate(expected: true)
                ioExecutor.sync { stopIOOnExecutor(running) }
                // I/O executor의 nonblocking write 상태와 독립된 bounded 종료 경로다.
                try? running.input.close()
                if running.process.isRunning { running.process.terminate() }
                let terminateDeadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
                recordMainThreadOperation(.blockingWait)
                while running.process.isRunning && DispatchTime.now().uptimeNanoseconds < terminateDeadline {
                    usleep(5_000)
                }
                if running.process.isRunning { _ = Darwin.kill(running.process.processIdentifier, SIGKILL) }
                self.running = nil
            }
        }
        // running=nil이어도 이전 termination handler가 예약한 I/O barrier/control completion이 있을
        // 수 있다. 두 executor를 순서대로 drain한 뒤 lane을 비워야 반환 뒤 callback이 남지 않는다.
        ioExecutor.sync {}
        controlExecutor.sync {}
        completionLock.lock()
        results.removeAll(keepingCapacity: true)
        resultDrain.removeAll(keepingCapacity: true)
        resultBytes = 0
        controls = ControlLane()
        completionLock.unlock()
    }

    private func start(action: inout MaruMermaidCoordinatorAction) {
        recordMainThreadOperation(.process)
        if case let .smokeDelayedStart(_, delayMs) = validation { usleep(useconds_t(delayMs * 1_000)) }
        let helper = action.capability.helper_instance
        let job = action.capability.job_id
        let request = MermaidProtocolBridge.copyRequestFrame(action: &action)
        enqueueActionConsumed(helper: helper, job: job)
        guard let request else {
            enqueueFailure(helper: helper, integrity: true)
            return
        }
        // Zig가 terminal 판정을 소유하지만, 이미 만료된 action으로 물리 process를 새로 만들지는 않는다.
        guard Self.monotonicMilliseconds() <= action.deadline_ms else {
            enqueueFailure(helper: helper, integrity: false)
            return
        }

        if action.spawn_helper == 0 {
            guard let running, running.helperInstance == helper, running.isActive() else {
                enqueueFailure(helper: helper, integrity: false)
                return
            }
            recordRequestFrame()
            enqueueWrite(request, to: running)
            return
        }

        let helperURL = helperURL()
        guard let validatedIdentity = validateHelper(at: helperURL) else {
            enqueueFailure(helper: helper, integrity: true)
            return
        }
        guard running == nil, let decoder = MermaidProtocolDecoder() else {
            enqueueFailure(helper: helper, integrity: false)
            return
        }

        let process = Process()
        recordMainThreadOperation(.pipeSetup)
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = helperURL
        process.currentDirectoryURL = helperURL.deletingLastPathComponent()
        var environment = [
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
        ]
        if case .smokeNoRead = validation { environment["MARU_MERMAID_SMOKE_NO_STDIN"] = "1" }
        if case .smokeClosedPipes = validation { environment["MARU_MERMAID_SMOKE_CLOSE_PIPES"] = "1" }
        if case let .smokeDelayedResult(_, delayMs) = validation {
            environment["MARU_MERMAID_SMOKE_RESULT_DELAY_MS"] = String(delayMs)
        }
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        guard setNonBlocking(stdin.fileHandleForWriting.fileDescriptor),
              setNonBlocking(stdout.fileHandleForReading.fileDescriptor),
              setNonBlocking(stderr.fileHandleForReading.fileDescriptor) else {
            enqueueFailure(helper: helper, integrity: false)
            return
        }
        let record = Running(
            helperInstance: helper,
            process: process,
            input: stdin.fileHandleForWriting,
            output: stdout.fileHandleForReading,
            error: stderr.fileHandleForReading,
            decoder: decoder
        )
        record.expectedNonce = action.hello_nonce
        record.pendingRequest = request
        running = record
        process.terminationHandler = { [weak self, weak record] _ in
            self?.controlExecutor.async {
                guard let self, let record else { return }
                record.deactivate(expected: false)
                if self.running === record { self.running = nil }
                if self.shuttingDown { return }
                // exact termination/failure commit은 I/O queue의 이미 시작/예약된 callback이 모두 끝난
                // 뒤에만 발급한다. 이 barrier 뒤에는 retired helper가 다음 generation control slot을
                // 가릴 수 없다.
                self.quiesceIO(record) {
                    guard !self.shuttingDown else { return }
                    if record.wasExpectedTermination() {
                        self.enqueueTermination(helper: record.helperInstance)
                    } else {
                        // Exit 12 is reserved for the embedded-digest/resource loader boundary.
                        // A validly re-signed but digest-mismatched bundle is therefore permanent,
                        // not a transient crash retried three times.
                        let resourceIntegrityFailure = process.terminationReason == .exit && process.terminationStatus == 12
                        self.enqueueFailure(helper: record.helperInstance, integrity: resourceIntegrityFailure)
                    }
                }
            }
        }

        var pathRestore: URL?
        do {
            pathRestore = try installABAFixtureIfRequested(helperURL: helperURL)
            try process.run()
            completionLock.lock()
            physicalStartCount += 1
            completionLock.unlock()
        } catch {
            try? restoreABAFixture(pathRestore, helperURL: helperURL)
            running = nil
            record.deactivate(expected: false)
            enqueueFailure(helper: helper, integrity: false)
            return
        }
        do {
            try restoreABAFixture(pathRestore, helperURL: helperURL)
            if pathRestore != nil {
                completionLock.lock()
                abaRestoreSuccessCount += 1
                completionLock.unlock()
            }
        } catch {
            enqueueFailure(helper: helper, integrity: true)
            terminateRecord(record)
            return
        }

        // Process에는 fd-exec가 없으므로 경로 ABA는 actual child PID의 dynamic code identity까지
        // prevalidated static CDHash/identifier/team과 맞아야만 통과한다. Hello는 이 검사 뒤에만 쓴다.
        guard validateHelper(at: helperURL) == validatedIdentity,
              validateRunningProcess(pid: process.processIdentifier, expected: validatedIdentity.code) else {
            enqueueFailure(helper: helper, integrity: true)
            terminateRecord(record)
            return
        }
        armOutputRead(record)
        armErrorRead(record)
        guard let hello = MermaidProtocolBridge.hello(
            helperInstance: helper,
            nonce: action.hello_nonce,
            ack: false
        ) else {
            enqueueFailure(helper: helper, integrity: true)
            terminateRecord(record)
            return
        }
        completionLock.lock()
        helloFrameCount += 1
        completionLock.unlock()
        enqueueWrite(hello, to: record)
    }

    private func helperURL() -> URL {
        switch validation {
        case .productionBundle:
            return Bundle.main.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
                .appendingPathComponent("MaruMermaidRenderer.app", isDirectory: true)
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("MacOS", isDirectory: true)
                .appendingPathComponent("maru-mermaid-renderer", isDirectory: false)
        case let .smoke(url):
            return url
        case let .smokeNoRead(url):
            return url
        case let .smokeClosedPipes(url):
            return url
        case let .smokeDelayedStart(url, _):
            return url
        case let .smokeDelayedResult(url, _):
            return url
        case let .smokePathABA(url, _):
            return url
        }
    }

    private func armOutputRead(_ record: Running) {
        guard record.isActive(), record.outputSource == nil else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: record.output.fileDescriptor, queue: ioExecutor)
        source.setEventHandler { [weak self, weak record] in
            guard let self, let record, record.isActive() else { return }
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            let count = Darwin.read(record.output.fileDescriptor, &bytes, bytes.count)
            self.recordMainThreadOperation(.pipeIO)
            if count >= 0 {
                let arrival = Self.monotonicMilliseconds()
                let data = Data(bytes: bytes, count: count)
                if count == 0 {
                    record.outputSource?.cancel()
                    record.outputSource = nil
                    completionLock.lock()
                    stdoutEOFCount += 1
                    completionLock.unlock()
                }
                self.consumeOutput(data, arrivalMs: arrival, from: record)
            } else if errno != EAGAIN && errno != EWOULDBLOCK {
                record.outputSource?.cancel()
                record.outputSource = nil
                self.enqueueFailure(helper: record.helperInstance, integrity: false)
            }
        }
        record.outputSource = source
        source.resume()
    }

    private func armErrorRead(_ record: Running) {
        guard record.isActive(), record.errorSource == nil else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: record.error.fileDescriptor, queue: ioExecutor)
        source.setEventHandler { [weak self, weak record] in
            guard let self, let record, record.isActive() else { return }
            var bytes = [UInt8](repeating: 0, count: 16 * 1024)
            let count = Darwin.read(record.error.fileDescriptor, &bytes, bytes.count)
            self.recordMainThreadOperation(.pipeIO)
            if count > 0 {
                record.stderrRing.append(bytes, count: count)
                if record.stderrRing.count > 64 * 1024 {
                    record.stderrRing.removeFirst(record.stderrRing.count - 64 * 1024)
                }
            } else if count == 0 {
                record.errorSource?.cancel()
                record.errorSource = nil
                completionLock.lock()
                stderrEOFCount += 1
                completionLock.unlock()
            } else if errno != EAGAIN && errno != EWOULDBLOCK {
                record.errorSource?.cancel()
                record.errorSource = nil
                self.enqueueFailure(helper: record.helperInstance, integrity: false)
            }
        }
        record.errorSource = source
        source.resume()
    }

    private func consumeOutput(_ data: Data, arrivalMs: UInt64, from record: Running) {
        if data.isEmpty {
            if !record.decoder.finish(), !record.wasExpectedTermination() {
                enqueueFailure(helper: record.helperInstance, integrity: true)
            }
            return
        }
        guard record.decoder.feed(data) else {
            enqueueFailure(helper: record.helperInstance, integrity: true)
            return
        }
        while true {
            var consumed = false
            let status = record.decoder.next { frame in
                consumed = true
                if let nonce = record.expectedNonce {
                    guard maru_mermaid_protocol_matches_hello_ack(&frame, record.helperInstance, nonce) != 0,
                          let request = record.pendingRequest else {
                        enqueueFailure(helper: record.helperInstance, integrity: true)
                        return
                    }
                    record.expectedNonce = nil
                    record.pendingRequest = nil
                    recordRequestFrame()
                    enqueueWrite(request, to: record)
                    return
                }
                guard frame.tag == UInt32(MARU_MERMAID_TAG_RESULT),
                      frame.helper_instance == record.helperInstance else {
                    enqueueFailure(helper: record.helperInstance, integrity: true)
                    return
                }
                let body = frame.body_ptr.map { Data(bytes: $0, count: frame.body_len) } ?? Data()
                enqueueResult(.init(capability: frame.capability, status: frame.status, body: body, arrivalMs: arrivalMs))
            }
            guard status == true else {
                if status == false { enqueueFailure(helper: record.helperInstance, integrity: true) }
                break
            }
            if !consumed { break }
        }
    }

    /// ioExecutor-owned bounded partial-write state machine. EAGAIN은 write source 하나로 재개하며
    /// controlExecutor의 terminate/SIGKILL을 절대 막지 않는다.
    private func enqueueWrite(_ data: Data, to record: Running) {
        ioExecutor.async { [weak self, weak record] in
            guard let self, let record, record.isActive() else { return }
            let queuedBytes = record.pendingWrites.reduce(0) { $0 + $1.count } - record.writeOffset
            guard record.pendingWrites.count < 2,
                  queuedBytes + data.count <= 2 * Int(MARU_MERMAID_PROTOCOL_MAX_REQUEST_FRAME_BYTES) else {
                self.enqueueFailure(helper: record.helperInstance, integrity: false)
                return
            }
            record.pendingWrites.append(data)
            self.flushWrites(record)
        }
    }

    private func flushWrites(_ record: Running) {
        guard record.isActive() else { return }
        while let first = record.pendingWrites.first {
            let written: Int = first.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(record.input.fileDescriptor, base.advanced(by: record.writeOffset), raw.count - record.writeOffset)
            }
            recordMainThreadOperation(.pipeIO)
            if written > 0 {
                record.writeOffset += written
                if record.writeOffset == first.count {
                    record.pendingWrites.removeFirst()
                    record.writeOffset = 0
                }
                continue
            }
            if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if record.writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: record.input.fileDescriptor, queue: ioExecutor)
                    source.setEventHandler { [weak self, weak record] in
                        guard let self, let record else { return }
                        self.flushWrites(record)
                    }
                    record.writeSource = source
                    source.resume()
                }
                return
            }
            enqueueFailure(helper: record.helperInstance, integrity: false)
            return
        }
        record.writeSource?.cancel()
        record.writeSource = nil
    }

    private func stopIOOnExecutor(_ record: Running) {
        record.writeSource?.cancel()
        record.writeSource = nil
        record.outputSource?.cancel()
        record.outputSource = nil
        record.errorSource?.cancel()
        record.errorSource = nil
        record.pendingWrites.removeAll(keepingCapacity: true)
        record.writeOffset = 0
    }

    private func scheduleStopIO(_ record: Running) {
        ioExecutor.async { [weak self, weak record] in
            guard let self, let record else { return }
            self.stopIOOnExecutor(record)
        }
    }

    private func quiesceIO(_ record: Running, then completion: @escaping @Sendable () -> Void) {
        ioExecutor.async { [weak self, weak record] in
            guard let self, let record else { return }
            self.stopIOOnExecutor(record)
            self.controlExecutor.async(execute: completion)
        }
    }

    private func terminateRecord(_ record: Running) {
        recordMainThreadOperation(.process)
        record.deactivate(expected: true)
        scheduleStopIO(record)
        if record.process.isRunning {
            record.process.terminate()
            let pid = record.process.processIdentifier
            controlExecutor.asyncAfter(deadline: .now() + 0.25) { [weak record] in
                guard let record, record.process.isRunning else { return }
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
    }

    private func terminate(helperInstance: UInt64) {
        guard let record = running, record.helperInstance == helperInstance else {
            enqueueTermination(helper: helperInstance)
            return
        }
        record.markExpectedTermination()
        terminateRecord(record)
    }

    private func enqueueResult(_ completion: ResultCompletion) {
        completionLock.lock()
        defer { completionLock.unlock() }
        let projectedBytes = resultBytes + completion.body.count
        guard results.count < Int(MARU_MERMAID_MAX_COMPLETIONS_PER_TICK),
              projectedBytes <= Int(MARU_MERMAID_MAX_ACCEPTED_SVG_BYTES) else {
            if controls.transientFailure == nil { controls.transientFailure = completion.capability.helper_instance }
            return
        }
        results.append(completion)
        resultBytes = projectedBytes
    }

    private func enqueueActionConsumed(helper: UInt64, job: UInt64) {
        completionLock.lock()
        if controls.actionConsumed == nil { controls.actionConsumed = (helper, job) }
        completionLock.unlock()
    }

    private func enqueueFailure(helper: UInt64, integrity: Bool) {
        completionLock.lock()
        if integrity {
            if controls.integrityFailure == nil { controls.integrityFailure = helper }
            if controls.transientFailure == helper { controls.transientFailure = nil }
        } else if controls.integrityFailure != helper, controls.transientFailure == nil {
            controls.transientFailure = helper
        }
        completionLock.unlock()
    }

    private func enqueueTermination(helper: UInt64) {
        completionLock.lock()
        if controls.termination == nil { controls.termination = helper }
        completionLock.unlock()
    }

    private func recordRequestFrame() {
        completionLock.lock()
        requestFrameCount += 1
        completionLock.unlock()
    }

    private func drainCompletions(nowMs: UInt64) {
        completionLock.lock()
        swap(&results, &resultDrain)
        resultBytes = 0
        let drainedControls = controls
        controls = ControlLane()
        completionLock.unlock()
        maxCompletionDrainCount = max(maxCompletionDrainCount, UInt64(resultDrain.count))

        if let consumed = drainedControls.actionConsumed {
            _ = maru_macos_mermaid_complete_action_handoff(consumed.helper, consumed.job)
        }
        if let integrity = drainedControls.integrityFailure {
            _ = maru_macos_mermaid_report_failure(integrity, nowMs, 1)
        } else if let transient = drainedControls.transientFailure {
            _ = maru_macos_mermaid_report_failure(transient, nowMs, 0)
        }
        if let termination = drainedControls.termination,
           maru_macos_mermaid_complete_termination(termination) != 0 {
            terminationAckCount += 1
        }
        for completion in resultDrain.prefix(Int(MARU_MERMAID_MAX_COMPLETIONS_PER_TICK)) {
            var frame = MaruMermaidDecodedFrame()
            frame.tag = UInt32(MARU_MERMAID_TAG_RESULT)
            frame.status = completion.status
            frame.helper_instance = completion.capability.helper_instance
            frame.capability = completion.capability
            completion.body.withUnsafeBytes { raw in
                frame.body_ptr = raw.bindMemory(to: UInt8.self).baseAddress
                frame.body_len = raw.count
                let outcome = maru_macos_mermaid_complete_decoded(&frame, completion.arrivalMs)
                if outcome == 0 { staleResultCount += 1 }
                if outcome == 1 || outcome == 2 { terminalResultCount += 1 }
                if outcome == 2 { onRenderError?(completion.capability) }
            }
        }
        resultDrain.removeAll(keepingCapacity: true)
    }

    private enum MainThreadOperation {
        case process
        case pipeSetup
        case pipeIO
        case blockingWait
    }

    /// Platform operation의 실제 실행 지점에서 main-thread 귀속을 센다. 정상 구조에서는 process/control과
    /// pipe I/O가 각 executor에 있으므로 모두 0이며, 향후 pump 안으로 옮기면 native perf artifact가 실패한다.
    private func recordMainThreadOperation(_ operation: MainThreadOperation) {
        guard Thread.isMainThread && pumpActive else { return }
        completionLock.lock()
        switch operation {
        case .process: mainThreadProcessOperationCount += 1
        case .pipeSetup: mainThreadPipeSetupCount += 1
        case .pipeIO: mainThreadPipeIOCount += 1
        case .blockingWait: mainThreadBlockingWaitCount += 1
        }
        completionLock.unlock()
    }

    private func validateHelper(at url: URL) -> HelperFileIdentity? {
        let standardized = url.standardizedFileURL
        guard standardized.path == url.path,
              standardized.resolvingSymlinksInPath().path == standardized.path else { return nil }
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }

        var helperCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &helperCode) == errSecSuccess,
              let helperCode,
              SecStaticCodeCheckValidity(helperCode, [], nil) == errSecSuccess,
              staticCodeHasRequiredSandbox(helperCode),
              let code = staticCodeIdentity(helperCode) else { return nil }
        // Validate the containing nested app as code as well. This checks Info.plist and the
        // CodeResources seal before spawn; executable-only validation cannot authenticate them.
        let helperBundle = url
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard helperBundle.pathExtension == "app" else { return nil }
        var bundleCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(helperBundle as CFURL, [], &bundleCode) == errSecSuccess,
              let bundleCode,
              SecStaticCodeCheckValidity(bundleCode, [], nil) == errSecSuccess,
              staticCodeHasRequiredSandbox(bundleCode),
              let bundleIdentity = staticCodeIdentity(bundleCode),
              bundleIdentity == code else { return nil }
        let identity = HelperFileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), code: code)
        switch validation {
        case .smoke, .smokeNoRead, .smokeClosedPipes, .smokeDelayedStart, .smokeDelayedResult, .smokePathABA:
            return identity
        case .productionBundle:
            break
        }

        let expected = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("MaruMermaidRenderer.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("maru-mermaid-renderer", isDirectory: false)
        guard standardized.path == expected.standardizedFileURL.path,
              let executableURL = Bundle.main.executableURL else { return nil }
        var appCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executableURL as CFURL, [], &appCode) == errSecSuccess,
              let appCode,
              SecStaticCodeCheckValidity(appCode, [], nil) == errSecSuccess,
              let appIdentity = staticCodeIdentity(appCode),
              code.teamIdentifier == appIdentity.teamIdentifier else { return nil }
        return identity
    }

    private func validateRunningProcess(pid: Int32, expected: CodeIdentity) -> Bool {
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var guest: SecCode?
        var attempts = 0
        while attempts < 20 {
            if SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess,
               let guest,
               SecCodeCheckValidity(guest, [], nil) == errSecSuccess,
               let actual = dynamicCodeIdentity(guest) {
                return actual == expected
            }
            if kill(pid, 0) != 0 { return false }
            attempts += 1
            usleep(5_000)
        }
        return false
    }

    /// Security smoke 전용: A precheck 뒤 path에 B를 놓아 exec하고 `Process.run()` 반환 직후 A를
    /// 복원한다. 실제 PID 검증이 없다면 post-path identity가 A라 ABA를 놓치는 fixture다.
    private func installABAFixtureIfRequested(helperURL: URL) throws -> URL? {
        guard case let .smokePathABA(_, replacement) = validation else { return nil }
        let backup = helperURL.deletingLastPathComponent().appendingPathComponent("helper-a-backup", isDirectory: false)
        try FileManager.default.moveItem(at: helperURL, to: backup)
        do {
            try FileManager.default.copyItem(at: replacement, to: helperURL)
        } catch {
            try? FileManager.default.moveItem(at: backup, to: helperURL)
            throw error
        }
        return backup
    }

    private func restoreABAFixture(_ backup: URL?, helperURL: URL) throws {
        guard let backup else { return }
        try FileManager.default.removeItem(at: helperURL)
        try FileManager.default.moveItem(at: backup, to: helperURL)
    }

    private func staticCodeIdentity(_ code: SecStaticCode) -> CodeIdentity? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let hash = dictionary[kSecCodeInfoUnique as String] as? Data else { return nil }
        return CodeIdentity(
            cdHash: hash,
            identifier: dictionary[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier: dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        )
    }

    /// A signed process boundary is insufficient when it retains ambient user-file or network authority.
    /// Admission therefore requires App Sandbox and rejects every entitlement that could grant those rights.
    private func staticCodeHasRequiredSandbox(_ code: SecStaticCode) -> Bool {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              entitlements["com.apple.security.app-sandbox"] as? Bool == true else { return false }
        guard entitlements["com.apple.security.network.client"] as? Bool == true else { return false }
        let allowed = Set([
            "com.apple.security.app-sandbox",
            "com.apple.security.network.client",
        ])
        return Set(entitlements.keys) == allowed
    }

    private func dynamicCodeIdentity(_ code: SecCode) -> CodeIdentity? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        return staticCodeIdentity(staticCode)
    }

    private func setNonBlocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    nonisolated static func monotonicMilliseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }
}
