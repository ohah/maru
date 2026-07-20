import AppKit
import Foundation
import Darwin

@main
@MainActor
struct MermaidHelperSmoke {
    static func main() {
        guard let rawPath = ProcessInfo.processInfo.environment["MARU_MERMAID_HELPER_PATH"] else {
            fail("MARU_MERMAID_HELPER_PATH missing")
        }
        let helperURL = URL(fileURLWithPath: rawPath)
        var checks: [String: Any] = [:]
        // Helper가 반복 시작되어도 합성 custom-scheme base URL을 구성하지 않아야 한다.
        // 실제 alert 부재는 UI gate이고, smoke는 helper와 공유하는 page 계약의 nil 값을 증명한다.
        checks["blank_document_base_url_is_nil"] = MermaidRendererPage.baseURL == nil

        maru_macos_mermaid_test_reset()
        var before = MaruMermaidCoordinatorSnapshot()
        maru_macos_mermaid_snapshot(&before)
        let oversized = Data(repeating: 0x61, count: Int(MARU_MERMAID_PROTOCOL_MAX_SOURCE_BYTES) + 1)
        let oversizedStatus = admit(widget: 1, source: oversized)
        var after = MaruMermaidCoordinatorSnapshot()
        maru_macos_mermaid_snapshot(&after)
        checks["cap_plus_one_rejected"] = oversizedStatus < 0
        checks["cap_plus_one_copy_zero"] = before.admission_copies == after.admission_copies

        // 실제 helper handshake와 duplicate Result를 거쳐 두 번째 capability 소비가 stale인지 확인한다.
        let duplicate = MermaidRenderCoordinator(validation: .smoke(helperURL))
        precondition(admit(widget: 2, source: Data("__MARU_TEST_DUPLICATE__".utf8)) == 0)
        pump(duplicate, until: { duplicate.staleResultCount == 1 }, timeout: 3.0)
        var duplicateSnapshot = MaruMermaidCoordinatorSnapshot()
        maru_macos_mermaid_snapshot(&duplicateSnapshot)
        checks["duplicate_terminal_count"] = duplicate.terminalResultCount
        checks["duplicate_stale_count"] = duplicate.staleResultCount
        checks["duplicate_disabled"] = duplicateSnapshot.disabled
        checks["duplicate_deadlines"] = duplicateSnapshot.deadline_expirations
        checks["helper_handshake_result"] = duplicate.terminalResultCount == 1
        checks["old_or_duplicate_result_rejected"] = duplicate.staleResultCount == 1
        duplicate.shutdown()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        // Result payload queue overflow가 exact termination/integrity control을 덮어쓰지 않는다.
        maru_macos_mermaid_test_reset()
        let flooding = MermaidRenderCoordinator(validation: .smoke(helperURL))
        precondition(admit(widget: 5, source: Data("__MARU_TEST_FLOOD__".utf8)) == 0)
        pump(flooding, until: {
            var snapshot = MaruMermaidCoordinatorSnapshot()
            maru_macos_mermaid_snapshot(&snapshot)
            return snapshot.in_flight == 0 && snapshot.termination_in_progress == 0 && flooding.terminationAckCount == 1
        }, timeout: 3.0)
        var floodSnapshot = MaruMermaidCoordinatorSnapshot()
        maru_macos_mermaid_snapshot(&floodSnapshot)
        checks["result_overflow_fail_closed"] = flooding.terminalResultCount == 0 && flooding.staleResultCount > 0
        checks["result_overflow_exact_termination_ack"] = flooding.terminationAckCount == 1
        checks["result_overflow_recoverable"] = floodSnapshot.disabled == 0 && floodSnapshot.termination_in_progress == 0
        flooding.shutdown()

        // HelloAck 뒤 stdin을 전혀 읽지 않는 실제 helper에도 max request write가 control executor를
        // 막지 않고 deadline termination/exact ACK가 완료되어야 한다.
        maru_macos_mermaid_test_reset()
        let noRead = MermaidRenderCoordinator(validation: .smokeNoRead(helperURL))
        let maxSource = Data(String(repeating: String(repeating: "x", count: 511) + "\n", count: 64).utf8)
        checks["no_read_max_source_exact"] = maxSource.count == Int(MARU_MERMAID_PROTOCOL_MAX_SOURCE_BYTES)
        precondition(admit(widget: 3, source: maxSource) == 0)
        pump(noRead, until: {
            var snapshot = MaruMermaidCoordinatorSnapshot()
            maru_macos_mermaid_snapshot(&snapshot)
            return snapshot.deadline_expirations == 1 && snapshot.termination_in_progress == 0
        }, timeout: 4.0)
        var noReadSnapshot = MaruMermaidCoordinatorSnapshot()
        maru_macos_mermaid_snapshot(&noReadSnapshot)
        let shutdownStart = ProcessInfo.processInfo.systemUptime
        noRead.shutdown()
        let shutdownElapsed = ProcessInfo.processInfo.systemUptime - shutdownStart
        checks["no_read_deadline"] = noReadSnapshot.deadline_expirations == 1
        checks["no_read_exact_termination_ack"] = noRead.terminationAckCount == 1
        checks["no_read_shutdown_bounded"] = shutdownElapsed < 0.5

        // stdout/stderr EOF는 permanently-ready DispatchSource를 정확히 한 번 cancel해야 한다.
        maru_macos_mermaid_test_reset()
        let closedPipes = MermaidRenderCoordinator(validation: .smokeClosedPipes(helperURL))
        precondition(admit(widget: 6, source: Data("closed-pipes".utf8)) == 0)
        pump(closedPipes, until: {
            var snapshot = MaruMermaidCoordinatorSnapshot()
            maru_macos_mermaid_snapshot(&snapshot)
            return snapshot.termination_in_progress == 0 && closedPipes.terminationAckCount == 1
        }, timeout: 4.0)
        let eofCounts = closedPipes.pipeEOFCounts()
        var closedPipesSnapshot = MaruMermaidCoordinatorSnapshot()
        maru_macos_mermaid_snapshot(&closedPipesSnapshot)
        checks["closed_pipe_eof_once"] = eofCounts.stdout == 1 && eofCounts.stderr == 1
        checks["closed_pipe_deadline"] = closedPipesSnapshot.deadline_expirations == 1
        checks["closed_pipe_exact_termination_ack"] = closedPipes.terminationAckCount == 1
        closedPipes.shutdown()

        // control executor에서 action 처리가 deadline 뒤로 밀리면 Zig가 한 번만 terminal 처리하고,
        // Swift의 물리 안전 precheck는 새 process/Hello/Request를 만들지 않는다.
        maru_macos_mermaid_test_reset()
        let delayedStart = MermaidRenderCoordinator(validation: .smokeDelayedStart(helperURL, delayMs: 2_100))
        precondition(admit(widget: 7, source: Data("delayed-start".utf8)) == 0)
        pump(delayedStart, until: {
            var snapshot = MaruMermaidCoordinatorSnapshot()
            maru_macos_mermaid_snapshot(&snapshot)
            return snapshot.termination_in_progress == 0 && delayedStart.terminationAckCount == 1
        }, timeout: 4.0)
        let delayedDiagnostics = delayedStart.diagnostics()
        var delayedSnapshot = MaruMermaidCoordinatorSnapshot()
        maru_macos_mermaid_snapshot(&delayedSnapshot)
        checks["delayed_start_deadline_once"] = delayedSnapshot.deadline_expirations == 1
        checks["delayed_start_physical_zero"] = delayedDiagnostics.physicalStarts == 0 && delayedDiagnostics.helloFrames == 0 && delayedDiagnostics.requestFrames == 0
        checks["delayed_start_exact_termination_ack"] = delayedStart.terminationAckCount == 1
        delayedStart.shutdown()

        // A precheck -> B exec -> A path restore에서도 post-path만 보지 않고 actual child PID code를
        // 대조해 Hello/Request/Result 전에 integrity latch해야 한다.
        maru_macos_mermaid_test_reset()
        let abaDirectory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("maru-mermaid-aba-\(UUID().uuidString)", isDirectory: true)
        let abaHelper = abaDirectory.appendingPathComponent("maru-mermaid-renderer", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: abaDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: helperURL, to: abaHelper)
        } catch {
            fail("ABA fixture setup failed: \(error)")
        }
        let aba = MermaidRenderCoordinator(
            validation: .smokePathABA(abaHelper, replacement: URL(fileURLWithPath: "/bin/cat"))
        )
        precondition(admit(widget: 4, source: Data("aba".utf8)) == 0)
        pump(aba, until: {
            var snapshot = MaruMermaidCoordinatorSnapshot()
            maru_macos_mermaid_snapshot(&snapshot)
            return snapshot.disabled != 0 && snapshot.termination_in_progress == 0
        }, timeout: 3.0)
        var abaSnapshot = MaruMermaidCoordinatorSnapshot()
        maru_macos_mermaid_snapshot(&abaSnapshot)
        checks["path_aba_integrity_latched"] = abaSnapshot.disabled != 0
        let abaDiagnostics = aba.diagnostics()
        checks["path_aba_result_commit_zero"] = aba.terminalResultCount == 0
        checks["path_aba_capability_frames_zero"] = abaDiagnostics.physicalStarts == 1 && abaDiagnostics.helloFrames == 0 && abaDiagnostics.requestFrames == 0
        checks["path_aba_exact_termination_ack"] = aba.terminationAckCount == 1
        aba.shutdown()
        try? FileManager.default.removeItem(at: abaDirectory)

        // running=nil이어도 이미 예약된 I/O/control callback을 shutdown이 모두 drain하고 lane을 비운다.
        let shutdownBarrier = MermaidRenderCoordinator(validation: .smoke(helperURL))
        shutdownBarrier.scheduleShutdownBarrierProbe()
        shutdownBarrier.shutdown()
        let shutdownAtReturn = shutdownBarrier.diagnostics()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let shutdownAfterWait = shutdownBarrier.diagnostics()
        checks["shutdown_barrier_drained"] = shutdownAtReturn.shutdownProbeCallbacks == 2 && shutdownAtReturn.pendingControls == 0
        checks["shutdown_barrier_no_late_callbacks"] = shutdownAfterWait.shutdownProbeCallbacks == shutdownAtReturn.shutdownProbeCallbacks && shutdownAfterWait.pendingControls == 0

        // 100개 hang 요청을 넣어도 queue는 bounded이고 rolling 세 번째 timeout에서 app-lifetime latch가 걸린다.
        maru_macos_mermaid_test_reset()
        let hanging = MermaidRenderCoordinator(validation: .smoke(helperURL))
        var admitted = 0
        for widget in 10..<110 {
            if admit(widget: UInt64(widget), source: Data("__MARU_TEST_HANG__".utf8)) == 0 { admitted += 1 }
        }
        pump(hanging, until: {
            var snapshot = MaruMermaidCoordinatorSnapshot()
            maru_macos_mermaid_snapshot(&snapshot)
            return snapshot.disabled != 0
        }, timeout: 8.0)
        pump(hanging, until: {
            var snapshot = MaruMermaidCoordinatorSnapshot()
            maru_macos_mermaid_snapshot(&snapshot)
            return snapshot.termination_in_progress == 0 && snapshot.action_handoff_pending == 0
        }, timeout: 1.0)
        var final = MaruMermaidCoordinatorSnapshot()
        maru_macos_mermaid_snapshot(&final)
        checks["hundred_hangs_submitted"] = admitted == Int(MARU_MERMAID_MAX_PENDING_JOBS)
        checks["failure_latched"] = final.disabled != 0
        checks["helper_starts_at_most_three"] = final.helper_starts <= 3
        checks["helper_started_three"] = final.helper_starts == 3
        checks["three_deadlines_expired"] = final.deadline_expirations == 3
        checks["termination_acknowledged_exactly"] = hanging.terminationAckCount == final.helper_starts
        checks["pending_reclaimed"] = final.pending_jobs == 0 && final.pending_source_bytes == 0
        hanging.shutdown()

        let passed = checks.values.compactMap { $0 as? Bool }.allSatisfy { $0 }
        checks["passed"] = passed
        writeSummary(checks)
        if !passed { fail("one or more Mermaid helper smoke checks failed") }
    }

    private static func admit(widget: UInt64, source: Data) -> Int32 {
        var renderer = MaruMermaidRendererCapability(
            document_revision: 1,
            projection_generation: 1,
            widget_id: widget,
            widget_generation: 1,
            renderer_instance: widget + 1_000
        )
        return source.withUnsafeBytes { raw in
            maru_macos_mermaid_admit(
                1 + widget % 3,
                &renderer,
                widget + 2_000,
                raw.bindMemory(to: UInt8.self).baseAddress,
                raw.count
            )
        }
    }

    private static func pump(
        _ coordinator: MermaidRenderCoordinator,
        until done: () -> Bool,
        timeout: TimeInterval
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline {
            coordinator.pump()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private static func writeSummary(_ checks: [String: Any]) {
        let directory = URL(fileURLWithPath: "zig-out/maru-macos-mermaid-helper-smoke", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("mermaid-helper.summary.json"), options: .atomic)
        } catch {
            fail("summary write failed: \(error)")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        Darwin.exit(1)
    }
}
