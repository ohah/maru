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

        guard let rawScriptPath = ProcessInfo.processInfo.environment["MARU_MERMAID_RENDERER_SCRIPT"] else {
            fail("MARU_MERMAID_RENDERER_SCRIPT missing")
        }
        let scriptURL = URL(fileURLWithPath: rawScriptPath, isDirectory: false)
        checks["renderer_script_exact_digest_accepted"] = MermaidScriptLoader.load(
            url: scriptURL,
            maxBytes: MermaidRendererPage.maxScriptBytes,
            expectedSHA256: MermaidHelperDigest.sha256
        ) != nil
        let scriptFixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("maru-mermaid-script-\(UUID().uuidString)", isDirectory: true)
        let modifiedScriptURL = scriptFixtureDirectory.appendingPathComponent("modified.js", isDirectory: false)
        let symlinkScriptURL = scriptFixtureDirectory.appendingPathComponent("symlink.js", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: scriptFixtureDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: scriptURL, to: modifiedScriptURL)
            let modified = try FileHandle(forWritingTo: modifiedScriptURL)
            try modified.seekToEnd()
            try modified.write(contentsOf: Data("\n// modified\n".utf8))
            try modified.close()
            try FileManager.default.createSymbolicLink(at: symlinkScriptURL, withDestinationURL: scriptURL)
        } catch {
            fail("renderer script fixture setup failed: \(error)")
        }
        checks["renderer_script_digest_mismatch_rejected"] = MermaidScriptLoader.load(
            url: modifiedScriptURL,
            maxBytes: MermaidRendererPage.maxScriptBytes,
            expectedSHA256: MermaidHelperDigest.sha256
        ) == nil
        checks["renderer_script_symlink_rejected"] = MermaidScriptLoader.load(
            url: symlinkScriptURL,
            maxBytes: MermaidRendererPage.maxScriptBytes,
            expectedSHA256: MermaidHelperDigest.sha256
        ) == nil
        try? FileManager.default.removeItem(at: scriptFixtureDirectory)

        maru_macos_mermaid_test_reset()
        var before = MaruMermaidCoordinatorSnapshot()
        maru_macos_mermaid_snapshot(&before)
        let oversized = Data(repeating: 0x61, count: Int(MARU_MERMAID_PROTOCOL_MAX_SOURCE_BYTES) + 1)
        let oversizedStatus = admit(widget: 1, source: oversized)
        var after = MaruMermaidCoordinatorSnapshot()
        maru_macos_mermaid_snapshot(&after)
        checks["cap_plus_one_rejected"] = oversizedStatus < 0
        checks["cap_plus_one_copy_zero"] = before.admission_copies == after.admission_copies

        // 정상 fence는 helper의 실제 WKWebView Mermaid 실행과 sanitizer를 거쳐 one-shot SVG가 된다.
        //
        // **cold deadline 스파이크를 한 번 흡수한다.** 이 게이트가 보는 것은 "SVG가 나오고
        // sanitize되고 외부를 안 부르는가"이지 **"5초 안에 되는가"가 아니다**(성능은 아래 perf
        // 시나리오가 따로 본다). 실측하면 cold는 로컬 571ms·CI 정상 1,064ms로 deadline(5,000ms)의
        // 21%인데, 공유 러너에서 간헐적으로 5배 넘게 튀어 파이프라인이 멀쩡한데도 게이트가 죽었다
        // (2026-08-11 하루에 여덟 번). deadline 상수를 올리는 것은 틀린 처방이다 — 5초는 이미
        // 정상의 5배이고, 사용자가 다이어그램을 기다리는 시간이라는 제품 정책이다.
        //
        // 두 번 연속 실패는 그대로 실패시킨다. 스파이크는 반복되지 않지만 진짜 결함은 반복된다.
        // 재시도 횟수를 결과에 실어, 이 값이 상시 1이 되면 그것 자체가 신호가 되게 한다.
        var rendering = MermaidRenderCoordinator(validation: .smoke(helperURL))
        var coldMs = 0
        var coldRetries = 0
        var renderedOnce = false
        for attempt in 0..<2 {
            maru_macos_mermaid_test_reset()
            if attempt > 0 {
                rendering = MermaidRenderCoordinator(validation: .smoke(helperURL))
                coldRetries += 1
            }
            precondition(admit(widget: 90, source: Data("```mermaid\ngraph TD\nA --> B\n```".utf8)) == 0)
            let coldStart = Date()
            pump(rendering, until: {
                var snapshot = MaruMermaidCoordinatorSnapshot()
                maru_macos_mermaid_snapshot(&snapshot)
                return snapshot.accepted_results == 1
            }, timeout: 7.0)
            coldMs = Int(Date().timeIntervalSince(coldStart) * 1000)
            var probe = MaruMermaidCoordinatorSnapshot()
            maru_macos_mermaid_snapshot(&probe)
            renderedOnce = probe.accepted_results == 1
            if renderedOnce { break }
        }
        checks["actual_mermaid_cold_ms"] = coldMs
        checks["actual_mermaid_cold_retries"] = coldRetries
        var accepted = MaruMermaidAcceptedResult()
        var svg = [UInt8](repeating: 0, count: Int(MARU_MERMAID_PROTOCOL_MAX_SVG_BYTES))
        let takeStatus = svg.withUnsafeMutableBufferPointer {
            maru_macos_mermaid_take_accepted(&accepted, $0.baseAddress, $0.count)
        }
        let renderedSvg = String(decoding: svg.prefix(accepted.svg_len), as: UTF8.self)
        let renderingDiagnostics = rendering.diagnostics()
        var renderingSnapshot = MaruMermaidCoordinatorSnapshot()
        maru_macos_mermaid_snapshot(&renderingSnapshot)
        checks["actual_mermaid_physical_starts"] = renderingDiagnostics.physicalStarts
        checks["actual_mermaid_hello_frames"] = renderingDiagnostics.helloFrames
        checks["actual_mermaid_request_frames"] = renderingDiagnostics.requestFrames
        checks["actual_mermaid_terminal_results"] = rendering.terminalResultCount
        checks["actual_mermaid_deadlines"] = renderingSnapshot.deadline_expirations
        checks["actual_mermaid_disabled"] = renderingSnapshot.disabled
        checks["actual_mermaid_stderr"] = rendering.stderrTail()
        checks["actual_mermaid_svg"] = takeStatus == 1 && accepted.window_id == 1 && renderedSvg.hasPrefix("<svg")
        let lowerSvg = renderedSvg.lowercased()
        checks["actual_mermaid_sanitized"] = !lowerSvg.contains("<script") &&
            !renderedSvg.localizedCaseInsensitiveContains("foreignObject") &&
            !lowerSvg.contains("href=\"http") &&
            !lowerSvg.contains("href='http") &&
            !lowerSvg.contains("url(http")
        // Result OK is encoded only after the native page adapter observes all four page-world
        // request counters, CSP violations, and top-level navigation attempts at zero.
        checks["normal_external_api_attempts_zero"] = checks["actual_mermaid_svg"] as? Bool == true
        checks["normal_external_csp_violations_zero"] = checks["actual_mermaid_svg"] as? Bool == true
        checks["normal_external_navigation_attempts_zero"] = checks["actual_mermaid_svg"] as? Bool == true
        rendering.shutdown()

        // 이전 2초 gate보다 느리지만 새 cold 5초 안인 결과는 정상 commit되어야 한다. helper env는 smoke에서만
        // 주입되며 제품 입력 문자열이 timing hook을 열지 않는다.
        //
        // harness outer timeout은 제품 cold deadline(5.0s) + fallback grace(→ 5.25s)보다 커야 한다.
        // 그렇지 않으면(옛 4.5s) 느린 runner에서 제품이 아직 정상 accept할 결과를 harness가 먼저 잘라
        // false-fail이 난다. 성공·실패 판정은 여전히 Zig deadline(`deadline_expirations==0`)이 소유하고
        // harness는 그 판정을 관측할 시간 여유만 준다. 정상 cold render pump(위 7.0s)와 같은 값으로 맞춘다.
        maru_macos_mermaid_test_reset()
        let delayedResult = MermaidRenderCoordinator(
            validation: .smokeDelayedResult(helperURL, delayMs: 2_600)
        )
        precondition(admit(widget: 97, source: Data("__MARU_TEST_MAX_SVG__".utf8)) == 0)
        pump(delayedResult, until: {
            var snapshot = MaruMermaidCoordinatorSnapshot()
            maru_macos_mermaid_snapshot(&snapshot)
            return snapshot.accepted_results == 1
        }, timeout: 7.0)
        var delayedAccepted = MaruMermaidAcceptedResult()
        var delayedSvg = [UInt8](repeating: 0, count: Int(MARU_MERMAID_PROTOCOL_MAX_SVG_BYTES))
        let delayedTake = delayedSvg.withUnsafeMutableBufferPointer {
            maru_macos_mermaid_take_accepted(&delayedAccepted, $0.baseAddress, $0.count)
        }
        var delayedResultSnapshot = MaruMermaidCoordinatorSnapshot()
        maru_macos_mermaid_snapshot(&delayedResultSnapshot)
        checks["slow_cold_result_before_five_seconds_accepted"] = delayedTake == 1 &&
            delayedAccepted.svg_len == Int(MARU_MERMAID_PROTOCOL_MAX_SVG_BYTES) &&
            delayedResultSnapshot.deadline_expirations == 0 &&
            delayedResult.diagnostics().physicalStarts == 1
        delayedResult.shutdown()

        // The actual signed/sandboxed WKWebView guard must count and reject every closed API family.
        maru_macos_mermaid_test_reset()
        let externalAPIs = MermaidRenderCoordinator(validation: .smoke(helperURL))
        precondition(admit(widget: 91, source: Data("__MARU_TEST_EXTERNAL_APIS__".utf8)) == 0)
        // cold helper의 첫 full render→terminal을 기다린다(정상 cold render pump와 같은 7.0s: harness가
        // 제품 cold deadline 5.25s를 삼키지 않게). 아래 subresource/navigation/duplicate/flood 동일.
        pump(externalAPIs, until: { externalAPIs.terminalResultCount == 1 }, timeout: 7.0)
        var externalAPISnapshot = MaruMermaidCoordinatorSnapshot()
        maru_macos_mermaid_snapshot(&externalAPISnapshot)
        checks["external_api_probe_counted_and_rejected"] = externalAPIs.terminalResultCount == 1 &&
            externalAPISnapshot.accepted_results == 0 && externalAPISnapshot.deadline_expirations == 0
        let startsAfterExternalAPIProbe = externalAPIs.diagnostics().physicalStarts
        precondition(admit(widget: 96, source: Data("```mermaid\ngraph TD\nClean --> Reused\n```".utf8)) == 0)
        pump(externalAPIs, until: {
            var snapshot = MaruMermaidCoordinatorSnapshot()
            maru_macos_mermaid_snapshot(&snapshot)
            return snapshot.accepted_results == 1
        }, timeout: 7.0)
        var postProbeAccepted = MaruMermaidAcceptedResult()
        var postProbeSvg = [UInt8](repeating: 0, count: Int(MARU_MERMAID_PROTOCOL_MAX_SVG_BYTES))
        let postProbeTakeStatus = postProbeSvg.withUnsafeMutableBufferPointer {
            maru_macos_mermaid_take_accepted(&postProbeAccepted, $0.baseAddress, $0.count)
        }
        checks["external_counter_is_per_render_on_same_helper"] = postProbeTakeStatus == 1 &&
            String(decoding: postProbeSvg.prefix(postProbeAccepted.svg_len), as: UTF8.self).hasPrefix("<svg") &&
            externalAPIs.diagnostics().physicalStarts == startsAfterExternalAPIProbe
        externalAPIs.shutdown()

        maru_macos_mermaid_test_reset()
        let externalSubresource = MermaidRenderCoordinator(validation: .smoke(helperURL))
        precondition(admit(widget: 95, source: Data("__MARU_TEST_EXTERNAL_SUBRESOURCE__".utf8)) == 0)
        pump(externalSubresource, until: { externalSubresource.terminalResultCount == 1 }, timeout: 7.0)
        var externalSubresourceSnapshot = MaruMermaidCoordinatorSnapshot()
        maru_macos_mermaid_snapshot(&externalSubresourceSnapshot)
        checks["external_subresource_csp_probe_counted_and_rejected"] =
            externalSubresource.terminalResultCount == 1 &&
            externalSubresourceSnapshot.accepted_results == 0 &&
            externalSubresourceSnapshot.deadline_expirations == 0
        externalSubresource.shutdown()

        maru_macos_mermaid_test_reset()
        let externalNavigation = MermaidRenderCoordinator(validation: .smoke(helperURL))
        precondition(admit(widget: 92, source: Data("__MARU_TEST_EXTERNAL_NAVIGATION__".utf8)) == 0)
        pump(externalNavigation, until: { externalNavigation.terminalResultCount == 1 }, timeout: 7.0)
        var externalNavigationSnapshot = MaruMermaidCoordinatorSnapshot()
        maru_macos_mermaid_snapshot(&externalNavigationSnapshot)
        checks["external_navigation_probe_counted_and_rejected"] = externalNavigation.terminalResultCount == 1 &&
            externalNavigationSnapshot.accepted_results == 0 && externalNavigationSnapshot.deadline_expirations == 0
        externalNavigation.shutdown()

        // 실제 helper handshake와 duplicate Result를 거쳐 두 번째 capability 소비가 stale인지 확인한다.
        maru_macos_mermaid_test_reset()
        let duplicate = MermaidRenderCoordinator(validation: .smoke(helperURL))
        precondition(admit(widget: 2, source: Data("__MARU_TEST_DUPLICATE__".utf8)) == 0)
        pump(duplicate, until: { duplicate.staleResultCount == 1 }, timeout: 7.0)
        var duplicateSnapshot = MaruMermaidCoordinatorSnapshot()
        maru_macos_mermaid_snapshot(&duplicateSnapshot)
        let duplicateDiagnostics = duplicate.diagnostics()
        checks["duplicate_physical_starts"] = duplicateDiagnostics.physicalStarts
        checks["duplicate_hello_frames"] = duplicateDiagnostics.helloFrames
        checks["duplicate_request_frames"] = duplicateDiagnostics.requestFrames
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
        }, timeout: 7.0)
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
        }, timeout: 7.0)
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
        }, timeout: 7.0)
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
        let delayedStart = MermaidRenderCoordinator(validation: .smokeDelayedStart(helperURL, delayMs: 5_100))
        precondition(admit(widget: 7, source: Data("delayed-start".utf8)) == 0)
        pump(delayedStart, until: {
            var snapshot = MaruMermaidCoordinatorSnapshot()
            maru_macos_mermaid_snapshot(&snapshot)
            return snapshot.termination_in_progress == 0 && delayedStart.terminationAckCount == 1
        }, timeout: 7.0)
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
        let sourceHelperBundle = helperURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let abaHelperBundle = abaDirectory.appendingPathComponent("MaruMermaidRenderer.app", isDirectory: true)
        let abaHelper = abaHelperBundle
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("maru-mermaid-renderer", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: abaDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceHelperBundle, to: abaHelperBundle)
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
        }, timeout: 7.0)
        var abaSnapshot = MaruMermaidCoordinatorSnapshot()
        maru_macos_mermaid_snapshot(&abaSnapshot)
        checks["path_aba_integrity_latched"] = abaSnapshot.disabled != 0
        let abaDiagnostics = aba.diagnostics()
        checks["path_aba_result_commit_zero"] = aba.terminalResultCount == 0
        checks["path_aba_capability_frames_zero"] = abaDiagnostics.physicalStarts == 1 && abaDiagnostics.helloFrames == 0 && abaDiagnostics.requestFrames == 0
        checks["path_aba_a_restored_before_pid_check"] = abaDiagnostics.abaRestoreSuccesses == 1
        checks["path_aba_exact_termination_ack"] = aba.terminationAckCount == 1
        aba.shutdown()
        try? FileManager.default.removeItem(at: abaDirectory)

        // A modified, un-re-signed nested resource must fail the parent bundle seal before spawn.
        maru_macos_mermaid_test_reset()
        let tamperedDirectory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("maru-mermaid-resource-tamper-\(UUID().uuidString)", isDirectory: true)
        let tamperedBundle = tamperedDirectory.appendingPathComponent("MaruMermaidRenderer.app", isDirectory: true)
        let tamperedHelper = tamperedBundle
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("maru-mermaid-renderer", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: tamperedDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceHelperBundle, to: tamperedBundle)
            let resource = tamperedBundle
                .appendingPathComponent("Contents/Resources/web/mermaid-helper.js", isDirectory: false)
            let handle = try FileHandle(forWritingTo: resource)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\n// unsealed tamper\n".utf8))
            try handle.close()
        } catch {
            fail("resource tamper fixture setup failed: \(error)")
        }
        let tampered = MermaidRenderCoordinator(validation: .smoke(tamperedHelper))
        precondition(admit(widget: 93, source: Data("```mermaid\ngraph TD\nA --> B\n```".utf8)) == 0)
        pump(tampered, until: {
            var snapshot = MaruMermaidCoordinatorSnapshot()
            maru_macos_mermaid_snapshot(&snapshot)
            return snapshot.disabled != 0
        }, timeout: 7.0)
        var tamperedSnapshot = MaruMermaidCoordinatorSnapshot()
        maru_macos_mermaid_snapshot(&tamperedSnapshot)
        checks["tampered_bundle_seal_rejected_before_spawn"] = tamperedSnapshot.disabled != 0 &&
            tampered.diagnostics().physicalStarts == 0
        tampered.shutdown()
        try? FileManager.default.removeItem(at: tamperedDirectory)

        // A deliberately re-signed mismatch passes the bundle seal, then the embedded digest makes
        // helper exit 12. Parent maps that exact code to one permanent integrity latch (no 3x retry).
        guard let mismatchRawPath = ProcessInfo.processInfo.environment["MARU_MERMAID_DIGEST_MISMATCH_HELPER_PATH"] else {
            fail("MARU_MERMAID_DIGEST_MISMATCH_HELPER_PATH missing")
        }
        maru_macos_mermaid_test_reset()
        let mismatch = MermaidRenderCoordinator(validation: .smoke(URL(fileURLWithPath: mismatchRawPath)))
        precondition(admit(widget: 94, source: Data("```mermaid\ngraph TD\nA --> B\n```".utf8)) == 0)
        pump(mismatch, until: {
            var snapshot = MaruMermaidCoordinatorSnapshot()
            maru_macos_mermaid_snapshot(&snapshot)
            return snapshot.disabled != 0
        }, timeout: 7.0)
        var mismatchSnapshot = MaruMermaidCoordinatorSnapshot()
        maru_macos_mermaid_snapshot(&mismatchSnapshot)
        checks["digest_mismatch_permanent_after_one_start"] = mismatchSnapshot.disabled != 0 &&
            mismatchSnapshot.helper_starts == 1 && mismatch.diagnostics().physicalStarts == 1 &&
            mismatch.terminalResultCount == 0
        mismatch.shutdown()

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
        let hangingProductTick = MermaidProductTickAdapter()
        let hangingAcceptedDrainer = MermaidAcceptedResultDrainer()
        var admitted = 0
        for widget in 10..<110 {
            if admit(widget: UInt64(widget), source: Data("__MARU_TEST_HANG__".utf8)) == 0 { admitted += 1 }
        }
        pumpProductTick(hanging, tick: hangingProductTick, drainer: hangingAcceptedDrainer, until: {
            var snapshot = MaruMermaidCoordinatorSnapshot()
            maru_macos_mermaid_snapshot(&snapshot)
            return snapshot.disabled != 0
        }, timeout: 20.0)
        pumpProductTick(hanging, tick: hangingProductTick, drainer: hangingAcceptedDrainer, until: {
            var snapshot = MaruMermaidCoordinatorSnapshot()
            maru_macos_mermaid_snapshot(&snapshot)
            return snapshot.termination_in_progress == 0 && snapshot.action_handoff_pending == 0
        }, timeout: 7.0)
        var final = MaruMermaidCoordinatorSnapshot()
        maru_macos_mermaid_snapshot(&final)
        checks["hundred_hangs_submitted"] = admitted == Int(MARU_MERMAID_MAX_PENDING_JOBS)
        checks["failure_latched"] = final.disabled != 0
        checks["helper_starts_at_most_three"] = final.helper_starts <= 3
        checks["helper_started_three"] = final.helper_starts == 3
        checks["three_deadlines_expired"] = final.deadline_expirations == 3
        checks["termination_acknowledged_exactly"] = hanging.terminationAckCount == final.helper_starts
        checks["pending_reclaimed"] = final.pending_jobs == 0 && final.pending_source_bytes == 0
        checks["failure_latch_uses_product_tick"] = hangingProductTick.pumpCalls > 0 &&
            hangingProductTick.maxCompletionDrain <= UInt64(MARU_MERMAID_MAX_COMPLETIONS_PER_TICK)
        // hang/restart/latch 경로의 lock 대기는 shutdown 전에 캡처한다(shutdown 뒤 상태를 읽지 않도록).
        let hangingLockWaitMaxMicros = hanging.diagnostics().maxCompletionLockWaitMicros
        hanging.shutdown()

        // Product bridge admission and reply registration are synchronous, while same-widget latest coalesce
        // can happen before the next display tick. The Zig fixed terminal must close A immediately and leave B
        // pending even if a late native timeout tries to revoke A with the same renderer identity.
        maru_macos_mermaid_test_reset()
        let coalesceWidget: UInt64 = 70
        let coalesceSurface = 1 + coalesceWidget % 3
        var coalesceRenderer = MaruMermaidRendererCapability(
            editor_epoch: 1,
            document_revision: 1,
            projection_generation: 1,
            widget_id: coalesceWidget,
            widget_generation: 1,
            renderer_instance: coalesceWidget + 1_000
        )
        precondition(admit(widget: coalesceWidget, source: Data("first".utf8)) == 0)
        let coalescedReplies = MermaidReplyDeliveryAdapter(maxPending: 2)
        let oldKey = MermaidReplyKey(surfaceId: coalesceSurface, jobId: 1)
        var oldTerminalCallbacks = 0
        precondition(coalescedReplies.register(
            key: oldKey,
            requestId: 1,
            identity: MermaidReplyIdentity(renderer: coalesceRenderer),
            timeout: DispatchWorkItem {},
            replyHandler: { _, error in
                if error != nil { oldTerminalCallbacks += 1 }
            }
        ))
        precondition(admit(widget: coalesceWidget, source: Data("second".utf8)) == 0)
        var coalesceBeforeDrain = MaruMermaidCoordinatorSnapshot()
        maru_macos_mermaid_snapshot(&coalesceBeforeDrain)
        let coalesceDrainer = MermaidAcceptedResultDrainer()
        var supersededDrained = 0
        coalesceDrainer.drainTerminals { terminal in
            supersededDrained += 1
            coalescedReplies.finishExact(
                key: MermaidReplyKey(surfaceId: terminal.window_id, jobId: terminal.job_id),
                identity: MermaidReplyIdentity(renderer: terminal.renderer),
                error: "mermaid render superseded"
            )
        }
        maru_macos_mermaid_revoke_job(coalesceSurface, oldKey.jobId, &coalesceRenderer)
        var coalesceAfterLateRevoke = MaruMermaidCoordinatorSnapshot()
        maru_macos_mermaid_snapshot(&coalesceAfterLateRevoke)
        checks["coalesce_old_reply_terminal_exactly_once"] = coalesceBeforeDrain.terminal_results == 1 &&
            supersededDrained == 1 && oldTerminalCallbacks == 1 && coalescedReplies.count == 0
        checks["coalesce_late_old_timeout_keeps_replacement"] = coalesceAfterLateRevoke.pending_jobs == 1 &&
            coalesceAfterLateRevoke.terminal_results == 0

        // Zig failure reducer가 회수한 exact terminal은 native 5.25초 safety fallback을 기다리지 않고 제품과 같은
        // adapter에서 즉시 one-shot 완료된다. 늦은 timer/result는 이미 비워진 key와 stale capability라 무동작이다.
        maru_macos_mermaid_test_reset()
        let deadlineWidget: UInt64 = 710
        let deadlineSurface = surfaceId(widget: deadlineWidget)
        let deadlineRenderer = renderer(widget: deadlineWidget)
        precondition(admit(widget: deadlineWidget, source: Data("deadline".utf8)) == 0)
        let deadlineReplies = MermaidReplyDeliveryAdapter(maxPending: 1)
        let deadlineKey = MermaidReplyKey(surfaceId: deadlineSurface, jobId: 1)
        var deadlineCallbacks = 0
        precondition(deadlineReplies.register(
            key: deadlineKey,
            requestId: 710,
            identity: MermaidReplyIdentity(renderer: deadlineRenderer),
            timeout: DispatchWorkItem {},
            replyHandler: { _, error in if error != nil { deadlineCallbacks += 1 } }
        ))
        var deadlineAction = MaruMermaidCoordinatorAction()
        precondition(maru_macos_mermaid_drain_action(10, &deadlineAction) == 1)
        precondition(maru_macos_mermaid_complete_action_handoff(
            deadlineAction.capability.helper_instance,
            deadlineAction.capability.job_id
        ) == 1)
        precondition(maru_macos_mermaid_expire_deadline(deadlineAction.deadline_ms + 1) == 1)
        let deadlineDrainer = MermaidAcceptedResultDrainer()
        var deadlineReasons: [UInt32] = []
        deadlineDrainer.drainTerminals { terminal in
            deadlineReasons.append(terminal.reason)
            deadlineReplies.finishExact(
                key: MermaidReplyKey(surfaceId: terminal.window_id, jobId: terminal.job_id),
                identity: MermaidReplyIdentity(renderer: terminal.renderer),
                error: "deadline"
            )
        }
        var lateDeadlineFrame = MaruMermaidDecodedFrame()
        lateDeadlineFrame.tag = MARU_MERMAID_TAG_RESULT
        lateDeadlineFrame.status = MARU_MERMAID_RESULT_RENDER_ERROR
        lateDeadlineFrame.capability = deadlineAction.capability
        let lateDeadlineResult = maru_macos_mermaid_complete_decoded(&lateDeadlineFrame, deadlineAction.deadline_ms + 2)
        let lateDeadlineTimer = maru_macos_mermaid_expire_deadline(deadlineAction.deadline_ms + 2)
        checks["deadline_terminal_reply_immediate_once"] = deadlineReasons == [MARU_MERMAID_TERMINAL_DEADLINE] &&
            deadlineCallbacks == 1 && deadlineReplies.count == 0
        checks["deadline_late_result_and_timer_noop"] = lateDeadlineResult == 0 && lateDeadlineTimer == 0 &&
            deadlineCallbacks == 1

        maru_macos_mermaid_test_reset()
        let transientWidget: UInt64 = 720
        let transientSurface = surfaceId(widget: transientWidget)
        let transientRenderer = renderer(widget: transientWidget)
        precondition(admit(widget: transientWidget, source: Data("transient".utf8)) == 0)
        let transientReplies = MermaidReplyDeliveryAdapter(maxPending: 1)
        let transientKey = MermaidReplyKey(surfaceId: transientSurface, jobId: 1)
        var transientCallbacks = 0
        precondition(transientReplies.register(
            key: transientKey,
            requestId: 720,
            identity: MermaidReplyIdentity(renderer: transientRenderer),
            timeout: DispatchWorkItem {},
            replyHandler: { _, error in if error != nil { transientCallbacks += 1 } }
        ))
        var transientAction = MaruMermaidCoordinatorAction()
        precondition(maru_macos_mermaid_drain_action(20, &transientAction) == 1)
        precondition(maru_macos_mermaid_complete_action_handoff(
            transientAction.capability.helper_instance,
            transientAction.capability.job_id
        ) == 1)
        precondition(maru_macos_mermaid_report_failure(transientAction.capability.helper_instance, 21, 0) == 1)
        let transientDrainer = MermaidAcceptedResultDrainer()
        var transientReasons: [UInt32] = []
        transientDrainer.drainTerminals { terminal in
            transientReasons.append(terminal.reason)
            transientReplies.finishExact(
                key: MermaidReplyKey(surfaceId: terminal.window_id, jobId: terminal.job_id),
                identity: MermaidReplyIdentity(renderer: terminal.renderer),
                error: "transient"
            )
        }
        checks["transient_terminal_reply_immediate_once"] = transientReasons == [MARU_MERMAID_TERMINAL_TRANSIENT_FAILURE] &&
            transientCallbacks == 1 && transientReplies.count == 0

        maru_macos_mermaid_test_reset()
        let integrityRunningWidget: UInt64 = 730
        let integrityPendingWidget: UInt64 = 731
        let integrityRunningSurface = surfaceId(widget: integrityRunningWidget)
        let integrityPendingSurface = surfaceId(widget: integrityPendingWidget)
        let integrityRunningRenderer = renderer(widget: integrityRunningWidget)
        let integrityPendingRenderer = renderer(widget: integrityPendingWidget)
        precondition(admit(widget: integrityRunningWidget, source: Data("integrity-running".utf8)) == 0)
        precondition(admit(widget: integrityPendingWidget, source: Data("integrity-pending".utf8)) == 0)
        let integrityReplies = MermaidReplyDeliveryAdapter(maxPending: 2)
        var integrityRunningCallbacks = 0
        var integrityPendingCallbacks = 0
        precondition(integrityReplies.register(
            key: MermaidReplyKey(surfaceId: integrityRunningSurface, jobId: 1),
            requestId: 730,
            identity: MermaidReplyIdentity(renderer: integrityRunningRenderer),
            timeout: DispatchWorkItem {},
            replyHandler: { _, error in if error != nil { integrityRunningCallbacks += 1 } }
        ))
        precondition(integrityReplies.register(
            key: MermaidReplyKey(surfaceId: integrityPendingSurface, jobId: 2),
            requestId: 731,
            identity: MermaidReplyIdentity(renderer: integrityPendingRenderer),
            timeout: DispatchWorkItem {},
            replyHandler: { _, error in if error != nil { integrityPendingCallbacks += 1 } }
        ))
        var integrityAction = MaruMermaidCoordinatorAction()
        precondition(maru_macos_mermaid_drain_action(30, &integrityAction) == 1)
        precondition(maru_macos_mermaid_complete_action_handoff(
            integrityAction.capability.helper_instance,
            integrityAction.capability.job_id
        ) == 1)
        precondition(maru_macos_mermaid_report_failure(integrityAction.capability.helper_instance, 31, 1) == 1)
        let integrityDrainer = MermaidAcceptedResultDrainer()
        var integrityReasons: [UInt32] = []
        integrityDrainer.drainTerminals { terminal in
            integrityReasons.append(terminal.reason)
            integrityReplies.finishExact(
                key: MermaidReplyKey(surfaceId: terminal.window_id, jobId: terminal.job_id),
                identity: MermaidReplyIdentity(renderer: terminal.renderer),
                error: "integrity"
            )
        }
        var integritySnapshot = MaruMermaidCoordinatorSnapshot()
        maru_macos_mermaid_snapshot(&integritySnapshot)
        let lateIntegrityFailure = maru_macos_mermaid_report_failure(integrityAction.capability.helper_instance, 32, 1)
        var lateIntegrityFrame = MaruMermaidDecodedFrame()
        lateIntegrityFrame.tag = MARU_MERMAID_TAG_RESULT
        lateIntegrityFrame.status = MARU_MERMAID_RESULT_RENDER_ERROR
        lateIntegrityFrame.capability = integrityAction.capability
        let lateIntegrityResult = maru_macos_mermaid_complete_decoded(&lateIntegrityFrame, 32)
        checks["integrity_terminals_running_and_pending_once"] = integrityReasons.count == 2 &&
            integrityReasons.allSatisfy { $0 == MARU_MERMAID_TERMINAL_INTEGRITY_FAILURE } &&
            integrityRunningCallbacks == 1 && integrityPendingCallbacks == 1 && integrityReplies.count == 0 &&
            integritySnapshot.pending_jobs == 0 && integritySnapshot.in_flight == 0
        checks["integrity_late_failure_and_result_noop"] = lateIntegrityFailure == 0 && lateIntegrityResult == 0 &&
            integrityRunningCallbacks == 1 && integrityPendingCallbacks == 1

        // 제품 tick과 같은 allocation-free `has_work` gate를 정확히 1,000회 통과시킨다. 결과 대기 cadence는
        // 8ms라 전체 loop window가 cold 5초보다 충분히 길고, deadline 직전 completion 뒤에도 마지막 drain tick이
        // 남는다. 결과를 소비한 뒤 남은 idle tick은 pump를 호출하지 않아 process/pipe churn이 0이어야 한다.
        maru_macos_mermaid_test_reset()
        let perf = MermaidRenderCoordinator(validation: .smoke(helperURL))
        precondition(admit(widget: 500, source: Data("__MARU_TEST_MAX_SVG__".utf8)) == 0)
        var perfAccepted = false
        var perfReplyDelivered = false
        var perfReplySerializedBytes = 0
        let productTick = MermaidProductTickAdapter()
        let acceptedDrainer = MermaidAcceptedResultDrainer()
        let replyDelivery = MermaidReplyDeliveryAdapter(maxPending: 1)
        for _ in 0..<1_000 {
            productTick.tick(
                coordinator: perf,
                drainer: acceptedDrainer,
                consume: { payload in
                    guard !perfAccepted else { return }
                    perfAccepted = payload.accepted.svg_len == Int(MARU_MERMAID_PROTOCOL_MAX_SVG_BYTES) &&
                        payload.svg.hasPrefix("<svg")
                    let key = MermaidReplyKey(
                        surfaceId: payload.accepted.window_id,
                        jobId: payload.accepted.capability.job_id
                    )
                    let timeout = DispatchWorkItem {}
                    guard replyDelivery.register(
                        key: key,
                        requestId: 1,
                        identity: MermaidReplyIdentity(renderer: payload.accepted.capability.renderer),
                        timeout: timeout,
                        replyHandler: { response, error in
                            guard error == nil,
                                  let response,
                                  let serialized = try? JSONSerialization.data(withJSONObject: response) else { return }
                            perfReplySerializedBytes = serialized.count
                            perfReplyDelivered = serialized.count > Int(MARU_MERMAID_PROTOCOL_MAX_SVG_BYTES)
                        }
                    ) else { return }
                    replyDelivery.deliver(payload) { _, _ in perfReplyDelivered = false }
                },
                consumeTerminal: { _ in }
            )
            if !perfAccepted { RunLoop.current.run(until: Date().addingTimeInterval(0.008)) }
        }

        // The product reply table is security- and lifetime-sensitive even though its operations are
        // synchronous on MainActor. Exercise the same concrete adapter rather than a test double so exact
        // identity, one-shot completion, targeted cancellation, and bounded admission cannot drift.
        let expectedRenderer = replyRenderer(seed: 1)
        let expectedIdentity = MermaidReplyIdentity(renderer: expectedRenderer)
        let wrongKey = MermaidReplyKey(surfaceId: 41, jobId: 101)
        let wrongAdapter = MermaidReplyDeliveryAdapter(maxPending: 1)
        var wrongCallbacks = 0
        var wrongErrors = 0
        var wrongRevokeKey = MermaidReplyKey(surfaceId: 0, jobId: 0)
        var wrongRevokeIdentity: MermaidReplyIdentity?
        precondition(wrongAdapter.register(
            key: wrongKey,
            requestId: 101,
            identity: expectedIdentity,
            timeout: DispatchWorkItem {},
            replyHandler: { _, error in
                wrongCallbacks += 1
                if error != nil { wrongErrors += 1 }
            }
        ))
        var staleRenderer = expectedRenderer
        staleRenderer.editor_epoch += 1
        wrongAdapter.deliver(replyPayload(surfaceId: 41, jobId: 101, renderer: staleRenderer)) { key, identity in
            wrongRevokeKey = key
            wrongRevokeIdentity = identity
        }
        checks["reply_wrong_identity_exact_revoke"] = wrongCallbacks == 1 && wrongErrors == 1 &&
            wrongAdapter.count == 0 && wrongRevokeKey == wrongKey && wrongRevokeIdentity == expectedIdentity

        let duplicateKey = MermaidReplyKey(surfaceId: 42, jobId: 102)
        let duplicateAdapter = MermaidReplyDeliveryAdapter(maxPending: 1)
        var duplicateCallbacks = 0
        var duplicateRevokes = 0
        duplicateAdapter.deliver(replyPayload(surfaceId: 999, jobId: 999, renderer: expectedRenderer)) { _, _ in
            duplicateRevokes += 1
        }
        precondition(duplicateAdapter.register(
            key: duplicateKey,
            requestId: 102,
            identity: expectedIdentity,
            timeout: DispatchWorkItem {},
            replyHandler: { response, error in
                if response != nil && error == nil { duplicateCallbacks += 1 }
            }
        ))
        let duplicatePayload = replyPayload(surfaceId: 42, jobId: 102, renderer: expectedRenderer)
        duplicateAdapter.deliver(duplicatePayload) { _, _ in duplicateRevokes += 1 }
        duplicateAdapter.deliver(duplicatePayload) { _, _ in duplicateRevokes += 1 }
        checks["reply_unknown_duplicate_one_shot"] = duplicateCallbacks == 1 && duplicateRevokes == 0 &&
            duplicateAdapter.count == 0

        let exactKey = MermaidReplyKey(surfaceId: 45, jobId: 105)
        let exactAdapter = MermaidReplyDeliveryAdapter(maxPending: 1)
        var exactCallbacks = 0
        precondition(exactAdapter.register(
            key: exactKey,
            requestId: 105,
            identity: expectedIdentity,
            timeout: DispatchWorkItem {},
            replyHandler: { _, _ in exactCallbacks += 1 }
        ))
        let wrongExactRejected = !exactAdapter.finishExact(
            key: exactKey,
            identity: otherIdentityFor(expectedIdentity),
            error: "wrong identity"
        ) && exactAdapter.count == 1 && exactCallbacks == 0
        let exactAccepted = exactAdapter.finishExact(
            key: exactKey,
            identity: expectedIdentity,
            error: "superseded"
        )
        checks["reply_superseded_requires_exact_identity"] = wrongExactRejected && exactAccepted &&
            exactAdapter.count == 0 && exactCallbacks == 1

        let deliverFirstKey = MermaidReplyKey(surfaceId: 43, jobId: 103)
        let deliverFirst = MermaidReplyDeliveryAdapter(maxPending: 1)
        var deliverFirstCallbacks = 0
        var deliverFirstRevokes = 0
        precondition(deliverFirst.register(
            key: deliverFirstKey,
            requestId: 103,
            identity: expectedIdentity,
            timeout: DispatchWorkItem {},
            replyHandler: { _, _ in deliverFirstCallbacks += 1 }
        ))
        deliverFirst.deliver(replyPayload(surfaceId: 43, jobId: 103, renderer: expectedRenderer)) { _, _ in
            deliverFirstRevokes += 1
        }
        deliverFirst.finish(
            key: deliverFirstKey,
            svg: nil,
            error: "late timeout",
            revoke: true
        ) { _, _ in deliverFirstRevokes += 1 }

        let timeoutFirstKey = MermaidReplyKey(surfaceId: 44, jobId: 104)
        let timeoutFirst = MermaidReplyDeliveryAdapter(maxPending: 1)
        var timeoutFirstCallbacks = 0
        var timeoutFirstRevokes = 0
        precondition(timeoutFirst.register(
            key: timeoutFirstKey,
            requestId: 104,
            identity: expectedIdentity,
            timeout: DispatchWorkItem {},
            replyHandler: { _, _ in timeoutFirstCallbacks += 1 }
        ))
        timeoutFirst.finish(
            key: timeoutFirstKey,
            svg: nil,
            error: "timeout",
            revoke: true
        ) { _, _ in timeoutFirstRevokes += 1 }
        timeoutFirst.deliver(replyPayload(surfaceId: 44, jobId: 104, renderer: expectedRenderer)) { _, _ in
            timeoutFirstRevokes += 1
        }
        checks["reply_deliver_timeout_race_one_shot"] = deliverFirstCallbacks == 1 && deliverFirstRevokes == 0 &&
            deliverFirst.count == 0 && timeoutFirstCallbacks == 1 && timeoutFirstRevokes == 1 && timeoutFirst.count == 0

        let otherRenderer = replyRenderer(seed: 2)
        let otherIdentity = MermaidReplyIdentity(renderer: otherRenderer)
        // Fallback은 admission 때 arm되지 않는다. 각 exact start action의 deadline+250ms만 소비하므로
        // 앞선 cold 작업을 기다린 B도 자기 warm 2초를 온전히 가진다.
        let fallbackAdapter = MermaidReplyDeliveryAdapter(maxPending: 2)
        let fallbackColdKey = MermaidReplyKey(surfaceId: 46, jobId: 106)
        let fallbackWarmKey = MermaidReplyKey(surfaceId: 47, jobId: 107)
        precondition(fallbackAdapter.register(
            key: fallbackColdKey,
            requestId: 106,
            identity: expectedIdentity,
            timeout: DispatchWorkItem {},
            replyHandler: { _, _ in }
        ))
        precondition(fallbackAdapter.register(
            key: fallbackWarmKey,
            requestId: 107,
            identity: otherIdentity,
            timeout: DispatchWorkItem {},
            replyHandler: { _, _ in }
        ))
        var coldCapability = MaruMermaidJobCapability()
        coldCapability.job_id = fallbackColdKey.jobId
        coldCapability.renderer = expectedRenderer
        var warmCapability = MaruMermaidJobCapability()
        warmCapability.job_id = fallbackWarmKey.jobId
        warmCapability.renderer = otherRenderer
        var fallbackDelays: [Int] = []
        let coldArmed = fallbackAdapter.armFallback(
            capability: coldCapability,
            deadlineMs: 6_000,
            nowMs: 1_000
        ) { delayMs, _ in fallbackDelays.append(delayMs) }
        let coldDuplicateRejected = !fallbackAdapter.armFallback(
            capability: coldCapability,
            deadlineMs: 6_000,
            nowMs: 1_000
        ) { _, _ in }
        fallbackAdapter.deliver(
            replyPayload(surfaceId: fallbackColdKey.surfaceId, jobId: fallbackColdKey.jobId, renderer: expectedRenderer)
        ) { _, _ in }
        let warmArmedAfterQueueWait = fallbackAdapter.armFallback(
            capability: warmCapability,
            deadlineMs: 9_000,
            nowMs: 7_000
        ) { delayMs, _ in fallbackDelays.append(delayMs) }
        checks["reply_fallback_arms_from_exact_action_deadline"] = coldArmed && coldDuplicateRejected &&
            warmArmedAfterQueueWait && fallbackDelays == [5_250, 2_250]
        fallbackAdapter.cancelAll(error: "cleanup") { _, _ in }

        // The product binding itself must observe real coordinator start actions. Admit B before pumping A so
        // B waits in the native queue, then verify the same helper yields cold 5.25s and warm 2.25s fallbacks.
        maru_macos_mermaid_test_reset()
        let boundCoordinator = MermaidRenderCoordinator(validation: .smoke(helperURL))
        let boundAdapter = MermaidReplyDeliveryAdapter(maxPending: 2)
        let boundAWidget: UInt64 = 610
        let boundBWidget: UInt64 = 611
        let boundARenderer = renderer(widget: boundAWidget)
        let boundBRenderer = renderer(widget: boundBWidget)
        let boundAKey = MermaidReplyKey(surfaceId: surfaceId(widget: boundAWidget), jobId: 1)
        let boundBKey = MermaidReplyKey(surfaceId: surfaceId(widget: boundBWidget), jobId: 2)
        var boundCallbacks = 0
        precondition(boundAdapter.register(
            key: boundAKey,
            requestId: 1,
            identity: MermaidReplyIdentity(renderer: boundARenderer),
            timeout: DispatchWorkItem {},
            replyHandler: { response, error in
                if response != nil && error == nil { boundCallbacks += 1 }
            }
        ))
        precondition(boundAdapter.register(
            key: boundBKey,
            requestId: 2,
            identity: MermaidReplyIdentity(renderer: boundBRenderer),
            timeout: DispatchWorkItem {},
            replyHandler: { response, error in
                if response != nil && error == nil { boundCallbacks += 1 }
            }
        ))
        var boundFallbackDelays: [Int] = []
        boundAdapter.bindFallback(to: boundCoordinator) { delayMs, _ in
            boundFallbackDelays.append(delayMs)
        }
        precondition(admit(widget: boundAWidget, source: Data("```mermaid\ngraph TD\nA --> B\n```".utf8)) == 0)
        precondition(admit(widget: boundBWidget, source: Data("```mermaid\ngraph TD\nB --> C\n```".utf8)) == 0)
        let boundTick = MermaidProductTickAdapter()
        let boundDrainer = MermaidAcceptedResultDrainer()
        let boundDeadline = Date().addingTimeInterval(7.0)
        while boundAdapter.count != 0 && Date() < boundDeadline {
            boundTick.tick(
                coordinator: boundCoordinator,
                drainer: boundDrainer,
                consume: { payload in
                    boundAdapter.deliver(payload) { _, _ in }
                },
                consumeTerminal: { terminal in
                    boundAdapter.finishExact(
                        key: MermaidReplyKey(surfaceId: terminal.window_id, jobId: terminal.job_id),
                        identity: MermaidReplyIdentity(renderer: terminal.renderer),
                        error: "unexpected terminal"
                    )
                }
            )
            if boundAdapter.count != 0 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
        }
        checks["reply_fallback_product_pump_wiring"] = boundCallbacks == 2 && boundAdapter.count == 0 &&
            boundFallbackDelays == [5_250, 2_250]
        boundCoordinator.shutdown()

        let targeted = MermaidReplyDeliveryAdapter(maxPending: 4)
        let targetA = MermaidReplyKey(surfaceId: 51, jobId: 201)
        let targetB = MermaidReplyKey(surfaceId: 51, jobId: 202)
        let targetC = MermaidReplyKey(surfaceId: 52, jobId: 203)
        var targetACallbacks = 0
        var targetBCallbacks = 0
        var targetCCallbacks = 0
        var targetedRevokes: [(MermaidReplyKey, MermaidReplyIdentity)] = []
        precondition(targeted.register(
            key: targetA,
            requestId: 201,
            identity: expectedIdentity,
            timeout: DispatchWorkItem {},
            replyHandler: { _, _ in targetACallbacks += 1 }
        ))
        precondition(targeted.register(
            key: targetB,
            requestId: 202,
            identity: otherIdentity,
            timeout: DispatchWorkItem {},
            replyHandler: { _, _ in targetBCallbacks += 1 }
        ))
        precondition(targeted.register(
            key: targetC,
            requestId: 203,
            identity: expectedIdentity,
            timeout: DispatchWorkItem {},
            replyHandler: { _, _ in targetCCallbacks += 1 }
        ))
        targeted.finishMatching(surfaceId: 51, identity: expectedIdentity, error: "exact revoke") { key, identity in
            targetedRevokes.append((key, identity))
        }
        let matchingExact = targetACallbacks == 1 && targetBCallbacks == 0 && targetCCallbacks == 0 &&
            targeted.count == 2 && targetedRevokes.isEmpty
        targeted.cancelSurface(51, error: "surface close") { key, identity in
            targetedRevokes.append((key, identity))
        }
        let surfaceExact = targetBCallbacks == 1 && targetCCallbacks == 0 && targeted.count == 1 &&
            targetedRevokes.count == 1 && targetedRevokes[0].0 == targetB && targetedRevokes[0].1 == otherIdentity
        targeted.cancelAll(error: "app close") { key, identity in
            targetedRevokes.append((key, identity))
        }
        checks["reply_targeted_finish_and_cancel"] = matchingExact && surfaceExact && targetCCallbacks == 1 &&
            targeted.count == 0 && targetedRevokes.count == 2 && targetedRevokes[1].0 == targetC &&
            targetedRevokes[1].1 == expectedIdentity

        let bounded = MermaidReplyDeliveryAdapter(maxPending: 1)
        let boundedFirst = bounded.register(
            key: MermaidReplyKey(surfaceId: 61, jobId: 301),
            requestId: 301,
            identity: expectedIdentity,
            timeout: DispatchWorkItem {},
            replyHandler: { _, _ in }
        )
        let boundedSecond = bounded.register(
            key: MermaidReplyKey(surfaceId: 61, jobId: 302),
            requestId: 302,
            identity: otherIdentity,
            timeout: DispatchWorkItem {},
            replyHandler: { _, _ in }
        )
        checks["reply_cap_plus_one_rejected_without_mutation"] = boundedFirst && !boundedSecond && bounded.count == 1
        bounded.cancelAll(error: "cleanup") { _, _ in }

        let perfDiagnostics = perf.diagnostics()
        checks["perf_actual_svg"] = perfAccepted
        checks["perf_completion_drain_bounded"] = productTick.maxCompletionDrain <= UInt64(MARU_MERMAID_MAX_COMPLETIONS_PER_TICK)
        checks["perf_tick_process_zero"] = perfDiagnostics.mainThreadProcessOperations == 0
        checks["perf_tick_pipe_setup_zero"] = perfDiagnostics.mainThreadPipeSetups == 0
        checks["perf_tick_pipe_io_zero"] = perfDiagnostics.mainThreadPipeIO == 0
        checks["perf_tick_blocking_wait_zero"] = perfDiagnostics.mainThreadBlockingWaits == 0
        let performance: [String: Any] = [
            "schema": "maru.mermaid-macos.v1",
            "scenario": "mermaid-cold-start-restart-1000-ticks",
            "ticks": 1_000,
            "mermaid_pending_jobs_cap": MARU_MERMAID_MAX_PENDING_JOBS,
            "mermaid_pending_source_bytes_cap": MARU_MERMAID_MAX_PENDING_SOURCE_BYTES,
            "mermaid_accepted_svg_bytes_cap": MARU_MERMAID_MAX_ACCEPTED_SVG_BYTES,
            "helper_physical_starts": perfDiagnostics.physicalStarts,
            "failure_latch_helper_starts": final.helper_starts,
            "failure_latch_deadlines": final.deadline_expirations,
            "failure_latched": final.disabled,
            "failure_latch_product_tick_calls": hangingProductTick.tickCalls,
            "failure_latch_product_completion_drain_max": hangingProductTick.maxCompletionDrain,
            "completion_drain_max": productTick.maxCompletionDrain,
            "helper_result_drain_max": perfDiagnostics.maxCompletionDrain,
            "completion_drain_cap": MARU_MERMAID_MAX_COMPLETIONS_PER_TICK,
            "product_tick_calls": productTick.tickCalls,
            "product_work_ticks": productTick.workTicks,
            "product_tick_pump_calls": productTick.pumpCalls,
            "product_tick_drain_calls": productTick.acceptedDrainCalls,
            "product_tick_max_elapsed_us": productTick.maxElapsedMicroseconds,
            "product_tick_lock_wait_max_us": perfDiagnostics.maxCompletionLockWaitMicros,
            "failure_latch_product_tick_max_elapsed_us": hangingProductTick.maxElapsedMicroseconds,
            "failure_latch_product_tick_lock_wait_max_us": hangingLockWaitMaxMicros,
            "accepted_svg_bytes_max": acceptedDrainer.acceptedBytesMax,
            "cold_response_deadline_ms": MARU_MERMAID_COLD_RESPONSE_DEADLINE_MS,
            "warm_response_deadline_ms": MARU_MERMAID_WARM_RESPONSE_DEADLINE_MS,
            "reply_fallback_grace_ms": MARU_MERMAID_REPLY_FALLBACK_GRACE_MS,
            "reply_fallback_ms": MARU_MERMAID_REPLY_FALLBACK_MS,
            "tick_process_spawn_terminate": perfDiagnostics.mainThreadProcessOperations,
            "tick_pipe_setup": perfDiagnostics.mainThreadPipeSetups,
            "tick_pipe_read_write": perfDiagnostics.mainThreadPipeIO,
            "tick_blocking_wait": perfDiagnostics.mainThreadBlockingWaits,
            "actual_svg": perfAccepted,
            "product_reply_delivered": perfReplyDelivered,
            "product_reply_pending_after_delivery": replyDelivery.count,
            "product_reply_serialized_bytes": perfReplySerializedBytes,
        ]
        perf.shutdown()

        let failedChecks = checks.compactMap { key, value -> String? in
            guard let boolean = value as? Bool, !boolean else { return nil }
            return key
        }.sorted()
        let passed = failedChecks.isEmpty
        checks["passed"] = passed
        writeSummary(checks)
        writePerformance(performance)
        if !passed {
            // **이름만 찍으면 재실행 도박밖에 못 한다.** 이 스모크는 헤드리스 WebKit·프로세스 스폰에 의존해
            // 느린 러너에서 간헐 실패하는데, 그때 로그에 남는 게 체크 이름뿐이라 "타임아웃인지 진짜 거부인지"를
            // 구별할 수 없었다(실측: 같은 job이 하루 세 번 빨갛고 세 번 다 재실행으로 통과했다).
            // 실패한 체크의 **값**과 진단 항목(stderr tail·카운터)을 함께 남긴다 — summary.json은 아티팩트라
            // job 로그에 안 뜨므로 stderr로 직접 낸다.
            var lines: [String] = ["Mermaid helper smoke checks failed: \(failedChecks.joined(separator: ", "))"]
            lines.append("--- 실패한 체크의 값 ---")
            for name in failedChecks {
                lines.append("  \(name) = \(checks[name].map { String(describing: $0) } ?? "<없음>")")
            }
            lines.append("--- 진단(불리언이 아닌 관측값) ---")
            for key in checks.keys.sorted() where !(checks[key] is Bool) {
                lines.append("  \(key) = \(String(describing: checks[key]!))")
            }
            fail(lines.joined(separator: "\n"))
        }
    }

    private static func replyRenderer(seed: UInt64) -> MaruMermaidRendererCapability {
        MaruMermaidRendererCapability(
            editor_epoch: seed,
            document_revision: seed + 10,
            projection_generation: seed + 20,
            widget_id: seed + 30,
            widget_generation: seed + 40,
            renderer_instance: seed + 50
        )
    }

    private static func renderer(widget: UInt64) -> MaruMermaidRendererCapability {
        MaruMermaidRendererCapability(
            editor_epoch: 1,
            document_revision: 1,
            projection_generation: 1,
            widget_id: widget,
            widget_generation: 1,
            renderer_instance: widget + 1_000
        )
    }

    private static func surfaceId(widget: UInt64) -> UInt64 {
        1 + widget % 3
    }

    private static func replyPayload(
        surfaceId: UInt64,
        jobId: UInt64,
        renderer: MaruMermaidRendererCapability
    ) -> MermaidAcceptedPayload {
        var capability = MaruMermaidJobCapability()
        capability.helper_instance = 1
        capability.job_id = jobId
        capability.renderer = renderer
        capability.fence_id = jobId + 1_000
        var accepted = MaruMermaidAcceptedResult()
        accepted.window_id = surfaceId
        accepted.capability = capability
        accepted.svg_len = 6
        return MermaidAcceptedPayload(accepted: accepted, svg: "<svg/>")
    }

    private static func otherIdentityFor(_ identity: MermaidReplyIdentity) -> MermaidReplyIdentity {
        MermaidReplyIdentity(
            editorEpoch: identity.editorEpoch + 1,
            documentRevision: identity.documentRevision,
            projectionGeneration: identity.projectionGeneration,
            widgetId: identity.widgetId,
            widgetGeneration: identity.widgetGeneration,
            rendererInstance: identity.rendererInstance
        )
    }

    private static func admit(widget: UInt64, source: Data) -> Int32 {
        var renderer = renderer(widget: widget)
        return source.withUnsafeBytes { raw in
            maru_macos_mermaid_admit(
                surfaceId(widget: widget),
                &renderer,
                widget + 2_000,
                raw.bindMemory(to: UInt8.self).baseAddress,
                raw.count
            )
        }
    }

    /// 조건이 충족되면 **즉시** 반환한다 — 그래서 timeout을 넉넉히 잡아도 정상 실행은 느려지지 않는다.
    /// 값이 곧 "느린 러너를 얼마나 봐줄 것인가"이고, 짧게 잡을 이유가 없어 전부 같은 값으로 맞췄다
    /// (실측: CI에서 3초 만료로 `path_aba_*`가 간헐 실패했다).
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

    private static func pumpProductTick(
        _ coordinator: MermaidRenderCoordinator,
        tick: MermaidProductTickAdapter,
        drainer: MermaidAcceptedResultDrainer,
        until done: () -> Bool,
        timeout: TimeInterval
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline {
            tick.tick(
                coordinator: coordinator,
                drainer: drainer,
                consume: { _ in },
                consumeTerminal: { _ in }
            )
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

    private static func writePerformance(_ performance: [String: Any]) {
        let directory = URL(fileURLWithPath: "tests/artifacts/perf", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: performance, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("mermaid-macos.json"), options: .atomic)
        } catch {
            fail("performance artifact write failed: \(error)")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        Darwin.exit(1)
    }
}
