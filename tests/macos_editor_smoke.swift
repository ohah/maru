//! E0.5A **제품 WKWebView 게이트**(docs/editor-surface-tooling.md §7.4).
//!
//! 제품 스킴 핸들러(`MaruAppSchemeHandler`)·제품 CSP(Zig `AppAssetRole`)·실제 `WKWebView`로 diff 하니스를 로드해
//! `@codemirror/merge`가 도는지 처음 확인한다. 하니스 asset root만 스모크 소유이고 **경로는 제품 그대로**다.
//!
//! 이 스모크가 판정하는 것은 넷이다.
//!   1. MergeView·unifiedMergeView가 **non-zero layout**으로 실제 표시되는가(jsdom이 못 보는 부분).
//!   2. chunk·마커가 계산되고 **accept/reject가 문서를 바꾸는가**.
//!   3. **CSP 위반·console 오류·404가 0인가**(§7.2 남은 확인 — MergeView 스타일 주입의 영향).
//!   4. MergeView 스타일이 **app origin 문서 밖으로 새지 않는가**(§7.2 불변식 1).
//!
//! artifact는 `MARU_EDITOR_SMOKE_OUT` 아래 `editor.summary.txt`·`editor-dom.json`·`editor-snapshot.png`.
//! DOM artifact에는 크기·개수·상태만 담고 source text는 넣지 않는다(하니스 fixture조차 싣지 않는다 — §7.4).

import AppKit
import Foundation
import WebKit

@main
@MainActor
struct EditorSmoke {
    static let timeout: TimeInterval = 30

    static func main() {
        let env = ProcessInfo.processInfo.environment
        guard let assetRoot = env["MARU_WEB_APP_ROOT"], !assetRoot.isEmpty else {
            fail("MARU_WEB_APP_ROOT missing")
        }
        guard let outRoot = env["MARU_EDITOR_SMOKE_OUT"], !outRoot.isEmpty else {
            fail("MARU_EDITOR_SMOKE_OUT missing")
        }
        let visible = env["MARU_EDITOR_SMOKE_DISPLAY"] == "1"

        let app = NSApplication.shared
        app.setActivationPolicy(visible ? .regular : .accessory)

        let config = WKWebViewConfiguration()
        // **비영속 스토어.** 기본 스토어는 앱 실행 사이에도 캐시가 남아, asset을 고쳐도 옛 CSS/JS가 로드될 수 있다.
        // 게이트는 "지금 이 산출물"을 재야 하므로 캐시를 아예 두지 않는다.
        config.websiteDataStore = .nonPersistent()
        // 제품과 같은 등록 — 핸들러도 CSP도 제품 코드가 소유한다(스모크는 root만 바꾼다).
        config.setURLSchemeHandler(
            MaruAppSchemeHandler(assetRoot: assetRoot),
            forURLScheme: MaruAppSchemeHandler.scheme
        )
        let frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let webView = WKWebView(frame: frame, configuration: config)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.title = "Maru editor smoke"
        if visible {
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
        }

        guard let url = URL(string: "\(MaruAppSchemeHandler.scheme)://app/index.html") else {
            fail("harness URL is not constructible")
        }
        webView.load(URLRequest(url: url))

        // 마운트에 걸린 시간을 남긴다 — 문서가 커질 때 어디서 못 쓰게 되는지 판단할 근거다(추측 금지).
        let ready_started = Date()
        // 하니스가 마운트를 끝낼 때까지 run loop를 돌린다. 폴링이지만 값이 도착하면 즉시 나가므로 고정 대기가 아니다.
        guard let ready = waitFor(webView: webView, expression: "window.__maruEditorSmoke ? (window.__maruEditorSmoke.ready || window.__maruEditorSmoke.error || false) : false") else {
            fail("harness never became ready within \(Int(timeout))s")
        }
        if let errorText = ready as? String {
            fail("harness mount failed: \(errorText)")
        }

        var summary: [String: String] = [:]
        summary["ready_ms"] = String(Int(Date().timeIntervalSince(ready_started) * 1000))
        summary["engine"] = "codemirror-merge/MergeView+unifiedMergeView"
        summary["webkit_user_agent"] = (evaluate(webView, "navigator.userAgent") as? String) ?? "unknown"
        summary["asset_root"] = assetRoot

        // ── 초기 상태
        guard let initial = evaluateJSON(webView, "JSON.stringify(window.__maruEditorSmoke.probe())") else {
            fail("probe returned nothing")
        }
        record(&summary, prefix: "initial", probe: initial)

        // ── accept: 첫 chunk를 받아들이면 chunk가 하나 줄어야 한다.
        let accepted = evaluate(webView, "window.__maruEditorSmoke.accept()") as? Bool ?? false
        guard let afterAccept = evaluateJSON(webView, "JSON.stringify(window.__maruEditorSmoke.probe())") else {
            fail("probe after accept returned nothing")
        }
        summary["accept_applied"] = String(accepted)
        record(&summary, prefix: "after_accept", probe: afterAccept)

        // ── reject: 남은 chunk 하나를 되돌린다(문서가 원본 쪽으로 간다).
        let rejected = evaluate(webView, "window.__maruEditorSmoke.reject()") as? Bool ?? false
        guard let afterReject = evaluateJSON(webView, "JSON.stringify(window.__maruEditorSmoke.probe())") else {
            fail("probe after reject returned nothing")
        }
        summary["reject_applied"] = String(rejected)
        record(&summary, prefix: "after_reject", probe: afterReject)

        // ── 위반·오류 수집(마운트 전에 설치된 수집기에서).
        let violations = (evaluate(webView, "JSON.stringify(window.__maruEditorSmoke.violations)") as? String) ?? "[]"
        let consoleErrors = (evaluate(webView, "JSON.stringify(window.__maruEditorSmoke.console_errors)") as? String) ?? "[]"
        summary["csp_violations"] = violations
        summary["console_errors"] = consoleErrors
        summary["csp_violation_count"] = String(jsonArrayCount(violations))
        summary["console_error_count"] = String(jsonArrayCount(consoleErrors))

        // ── 큰 응답 파싱 비용(상한 근거 — docs/editor-surface.md §10.6). 네이티브 직렬화 비용은 Zig 테스트가
        //    재고, 여기서는 **웹이 받아 파싱하는** 쪽을 잰다. 둘을 합쳐야 "큰 파일을 열면 얼마나 기다리는가"다.
        if let parse = evaluateJSON(webView, "JSON.stringify(window.__maruEditorSmoke.measure_parse(8*1024*1024))") {
            summary["parse_8mib_response_bytes"] = String(intOf(parse["response_bytes"]))
            summary["parse_8mib_ms"] = String(intOf(parse["parse_ms"]))
        }

        // ── CSP 자가검증. 헤더가 빠져도 위반은 0으로 보이므로, "위반 0"을 근거로 쓰려면 CSP가 실제로 막는다는
        //    증거가 있어야 한다. 반드시 차단돼야 하는 eval을 일부러 시도한다 — **위 계측이 모두 끝난 뒤**에.
        let cspEnforced = evaluate(webView, "window.__maruEditorSmoke.csp_self_test()") as? Bool ?? false
        summary["csp_enforced"] = String(cspEnforced)
        let violationsAfterSelfTest = (evaluate(webView, "JSON.stringify(window.__maruEditorSmoke.violations)") as? String) ?? "[]"
        summary["csp_self_test_violations"] = violationsAfterSelfTest
        // 자가검증이 위반을 **실제로 만들어야** 수집기도 살아 있다는 뜻이다(수집기가 죽어 있으면 위 0도 거짓이다).
        let selfTestRaisedViolation = jsonArrayCount(violationsAfterSelfTest) > jsonArrayCount(violations)
        summary["csp_violation_recorder_live"] = String(selfTestRaisedViolation)

        // ── 자원 스케일링(§9 E0.5A 종료 조건): diff 1/2/4개의 web content 프로세스 RSS·유휴 CPU·닫은 뒤 회수.
        //    WKWebView는 메모리 API가 없으므로 **우리가 만들기 전후의 WebContent 프로세스 집합 차이**로 귀속한다
        //    (같은 순간 다른 앱이 WebContent를 띄우면 섞일 수 있다 — 그 한계는 summary에 남긴다).
        measureResources(&summary, config: config, url: url)

        // ── snapshot: Metal PPM은 WKWebView 픽셀을 담지 못하므로 WebKit takeSnapshot을 쓴다(§7.4).
        let outURL = URL(fileURLWithPath: outRoot, isDirectory: true)
        try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        summary["snapshot_written"] = String(snapshot(webView, to: outURL.appendingPathComponent("editor-snapshot.png")))

        // ── DOM artifact: 크기·개수·상태만(§7.4 — source text 금지).
        let dom: [String: Any] = [
            "initial": redacted(initial),
            "after_accept": redacted(afterAccept),
            "after_reject": redacted(afterReject),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dom, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: outURL.appendingPathComponent("editor-dom.json"))
        }

        let summaryText = summary.keys.sorted().map { "\($0)=\(summary[$0]!)" }.joined(separator: "\n") + "\n"
        try? Data(summaryText.utf8).write(to: outURL.appendingPathComponent("editor.summary.txt"))

        // ── 판정. 값을 남긴 뒤에 본다 — 실패해도 artifact가 있어야 원인을 볼 수 있다.
        var failures: [String] = []
        if boolValue(summary["initial_split_visible"]) == false { failures.append("split view has zero layout") }
        if boolValue(summary["initial_unified_visible"]) == false { failures.append("unified view has zero layout") }
        if intValue(summary["initial_split_chunks"]) <= 0 { failures.append("split view computed no chunks") }
        if intValue(summary["initial_unified_chunks"]) <= 0 { failures.append("unified view computed no chunks") }
        if intValue(summary["initial_split_changed_elements"]) <= 0 { failures.append("no change decorations") }
        if intValue(summary["initial_unified_gutter_markers"]) <= 0 { failures.append("no gutter markers") }
        if intValue(summary["initial_split_line_numbers"]) <= 0 { failures.append("no line numbers") }
        if boolValue(summary["initial_split_scrollable"]) == false { failures.append("split view cannot scroll") }
        if boolValue(summary["initial_split_scrollable_x"]) == false { failures.append("split view cannot scroll horizontally") }
        if boolValue(summary["initial_unified_scrollable"]) == false { failures.append("unified view cannot scroll") }
        if !accepted { failures.append("acceptChunk did not apply") }
        if intValue(summary["after_accept_unified_chunks"]) >= intValue(summary["initial_unified_chunks"]) {
            failures.append("acceptChunk did not reduce the chunk count")
        }
        if !rejected { failures.append("rejectChunk did not apply") }
        if intValue(summary["csp_violation_count"]) != 0 { failures.append("CSP violations: \(violations)") }
        if intValue(summary["console_error_count"]) != 0 { failures.append("console errors: \(consoleErrors)") }
        if boolValue(summary["initial_styles_all_in_this_document"]) == false {
            failures.append("MergeView styles left the app origin document")
        }
        if summary["snapshot_written"] != "true" { failures.append("snapshot missing") }
        // CSP가 안 걸렸거나 수집기가 죽었으면 위 "위반 0"은 근거가 없다 — 초록을 주지 않는다.
        if !cspEnforced { failures.append("CSP is not enforced (eval succeeded) — a zero violation count proves nothing") }
        if !selfTestRaisedViolation { failures.append("violation recorder did not observe the deliberate violation") }
        // 자원 측정이 실제로 일어났는가 — 0이면 귀속에 실패한 것이고, 그 상태로 "예산 안"이라 말할 수 없다.
        for count in [1, 2, 4] where intValue(summary["rss_\(count)_view_kb"]) <= 0 {
            failures.append("no web content RSS attributed for \(count) view(s)")
        }
        // 닫은 뒤 회수: 우리가 띄운 프로세스가 남아 있으면 안 된다(누수 = 탭을 닫아도 메모리가 안 돌아온다).
        if intValue(summary["webcontent_processes_after_close"]) != 0 {
            failures.append("web content processes survived close: \(summary["webcontent_processes_after_close"] ?? "?")")
        }
        // 유휴 CPU: 화면에 없는 diff가 코어를 돌리면 안 된다. 임계는 넉넉히 잡되(측정 창의 50%) 0은 아니게 둔다.
        if intValue(summary["idle_cpu_percent_4_view"]) > 50 {
            failures.append("hidden diff views burned CPU: \(summary["idle_cpu_percent_4_view"] ?? "?")%")
        }

        if failures.isEmpty {
            FileHandle.standardOutput.write(Data("editor smoke ok: \(outRoot)\n".utf8))
            exit(0)
        }
        fail("editor smoke failed: \(failures.joined(separator: "; "))")
    }

    // MARK: - 관측

    static func record(_ summary: inout [String: String], prefix: String, probe: [String: Any]) {
        let split = probe["split"] as? [String: Any] ?? [:]
        let unified = probe["unified"] as? [String: Any] ?? [:]
        summary["\(prefix)_split_chunks"] = String(intOf(split["chunk_count"]))
        summary["\(prefix)_unified_chunks"] = String(intOf(unified["chunk_count"]))
        summary["\(prefix)_split_changed_elements"] = String(intOf(split["changed_elements"]))
        summary["\(prefix)_unified_changed_elements"] = String(intOf(unified["changed_elements"]))
        summary["\(prefix)_split_gutter_markers"] = String(intOf(split["gutter_markers"]))
        summary["\(prefix)_unified_gutter_markers"] = String(intOf(unified["gutter_markers"]))
        summary["\(prefix)_split_visible"] = String(hasLayout(split["layout"]))
        // **스크롤 가능 여부**: 보이는 높이보다 전체가 커야 넘치는 내용을 볼 수 있다. merge가 편집기 높이를
        // `auto !important`로 강제하므로 스크롤 주체는 바깥 상자이고, 그 상자가 안 갇히면 여기서 같아진다.
        summary["\(prefix)_split_scrollable"] = String(isScrollable(split["scroll"]))
        // 가로도 넘쳐야 한다 — 긴 줄이 있는데 가로 스크롤이 없으면 그 줄의 나머지를 볼 방법이 없다.
        summary["\(prefix)_split_scrollable_x"] = String(isScrollableX(split["scroll"]))
        summary["\(prefix)_unified_scrollable"] = String(isScrollable(unified["scroll"]))
        summary["\(prefix)_split_line_numbers"] = String(intOf(split["line_number_elements"]))
        summary["\(prefix)_unified_visible"] = String(hasLayout(unified["layout"]))
        summary["\(prefix)_style_elements"] = String(intOf(probe["style_elements"]))
        summary["\(prefix)_styles_all_in_this_document"] = String((probe["styles_all_in_this_document"] as? Bool) ?? false)
        summary["\(prefix)_iframe_count"] = String(intOf(probe["iframe_count"]))
        // 텍스트는 요약에 싣지 않고 **길이만** 남긴다 — accept/reject가 문서를 바꿨다는 증거로는 충분하다.
        if let text = unified["text"] as? String { summary["\(prefix)_unified_text_length"] = String(text.count) }
    }

    /// DOM artifact에서 텍스트를 걷어낸다(길이만 남긴다).
    static func redacted(_ probe: [String: Any]) -> [String: Any] {
        var copy = probe
        for key in ["split", "unified"] {
            guard var side = copy[key] as? [String: Any] else { continue }
            if let text = side["text"] as? String {
                side["text_length"] = text.count
            } else if let pair = side["text"] as? [String: Any] {
                side["text_length"] = pair.values.compactMap { ($0 as? String)?.count }.reduce(0, +)
            }
            side["text"] = nil
            copy[key] = side
        }
        return copy
    }

    /// 가로로 넘치는가(fixture에 뷰 폭을 넘는 긴 줄이 있다).
    static func isScrollableX(_ raw: Any?) -> Bool {
        guard let scroll = raw as? [String: Any] else { return false }
        return intOf(scroll["scroll_width"]) > intOf(scroll["client_width"]) && intOf(scroll["client_width"]) > 0
    }

    /// 스크롤 상자가 실제로 넘치는가(fixture는 뷰 높이를 넘도록 길다).
    static func isScrollable(_ raw: Any?) -> Bool {
        guard let scroll = raw as? [String: Any] else { return false }
        return intOf(scroll["scroll_height"]) > intOf(scroll["client_height"]) && intOf(scroll["client_height"]) > 0
    }

    static func hasLayout(_ raw: Any?) -> Bool {
        guard let layout = raw as? [String: Any] else { return false }
        return intOf(layout["width"]) > 0 && intOf(layout["height"]) > 0
    }

    static func intOf(_ raw: Any?) -> Int {
        if let n = raw as? Int { return n }
        if let d = raw as? Double { return Int(d) }
        return 0
    }

    static func intValue(_ raw: String?) -> Int { Int(raw ?? "") ?? -1 }
    static func boolValue(_ raw: String?) -> Bool { raw == "true" }

    static func jsonArrayCount(_ json: String) -> Int {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return 0 }
        return array.count
    }

    // MARK: - 자원 측정

    /// diff 1/2/4개를 차례로 띄워 web content 프로세스의 RSS·유휴 CPU를 재고, 전부 닫은 뒤 회수를 확인한다.
    static func measureResources(_ summary: inout [String: String], config: WKWebViewConfiguration, url: URL) {
        // **우리 PID를 직접 추적한다.** "지금 도는 WebContent 전부 − 처음 있던 것"으로 세면 측정 도중 다른 앱이 띄운
        // WebContent가 섞여(이 기기에서 실제로 관측됨) 회수 판정이 영원히 거짓이 된다. 각 회차에서 새로 생긴 PID를
        // 그 회차의 소유로 못박고, 회수도 **그 PID들이 사라졌는가**로만 본다.
        summary["resource_attribution"] = "per-iteration new webcontent pids"
        var known = Set(webContentProcesses().keys)
        var ourPids: [Int32] = []

        for count in [1, 2, 4] {
            var rssKB = 0
            var processCount = 0
            var idleCpuPercent = 0
            var iterationPids: Set<Int32> = []

            // autoreleasepool 안에서 만들고 버린다 — 밖이면 함수 스코프가 끝날 때까지 풀에 남는다.
            autoreleasepool {
                var views: [WKWebView] = []
                var windows: [NSWindow] = []
                for _ in 0..<count {
                    // 뷰마다 별도 configuration — 같은 config를 공유하면 WebKit이 프로세스를 합쳐 "N개일 때"가
                    // 측정되지 않는다. 제품에서도 diff 파일 Term은 각자 패널이라 이쪽이 실제에 가깝다.
                    let viewConfig = WKWebViewConfiguration()
                    viewConfig.setURLSchemeHandler(
                        MaruAppSchemeHandler(assetRoot: summary["asset_root"] ?? ""),
                        forURLScheme: MaruAppSchemeHandler.scheme
                    )
                    let frame = NSRect(x: 0, y: 0, width: 900, height: 600)
                    let view = WKWebView(frame: frame, configuration: viewConfig)
                    // 창에 붙이지 않으면 WebKit이 레이아웃을 미룰 수 있다 — 화면 밖 창에 얹어 실제 렌더까지 가게 한다.
                    let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    // close()가 과다 해제로 크래시하지 않게(격리 프로브에서 SIGSEGV 실측).
                    window.isReleasedWhenClosed = false
                    window.contentView = view
                    view.load(URLRequest(url: url))
                    views.append(view)
                    windows.append(window)
                }
                for view in views {
                    _ = waitFor(webView: view, expression: "window.__maruEditorSmoke ? (window.__maruEditorSmoke.ready || false) : false")
                }

                let loaded = webContentProcesses().filter { !known.contains($0.key) }
                iterationPids = Set(loaded.keys)
                rssKB = loaded.values.reduce(0) { $0 + $1.rssKB }
                processCount = loaded.count

                // 유휴 CPU: 입력 없이 화면 밖 상태로 두고 CPU 시간 증가분을 본다.
                let windowSeconds = 1.5
                idle(seconds: windowSeconds)
                let after = webContentProcesses().filter { iterationPids.contains($0.key) }
                let cpuDelta = after.reduce(0.0) { total, entry in
                    total + max(0, entry.value.cpuSeconds - (loaded[entry.key]?.cpuSeconds ?? entry.value.cpuSeconds))
                }
                idleCpuPercent = Int((cpuDelta / windowSeconds) * 100)

                for view in views { view.stopLoading() }
                for window in windows {
                    window.contentView = nil
                    window.orderOut(nil)
                    window.close()
                }
                views.removeAll()
                windows.removeAll()
            }

            summary["rss_\(count)_view_kb"] = String(rssKB)
            summary["webcontent_processes_\(count)_view"] = String(processCount)
            summary["idle_cpu_percent_\(count)_view"] = String(idleCpuPercent)

            // 회수는 즉시가 아니다(XPC 종료). **걸린 시간을 값으로 남긴다** — 회수 여부만 boolean으로 두면
            // '오래 걸린다'와 '샌다'가 구분되지 않는다.
            let reclaimed = waitForReclaim(pids: iterationPids, limit: 20)
            summary["reclaim_seconds_\(count)_view"] = reclaimed.map { String(format: "%.1f", $0) } ?? "timeout"
            ourPids.append(contentsOf: iterationPids)
            known.formUnion(iterationPids)
        }

        let alive = webContentProcesses().filter { ourPids.contains($0.key) }
        summary["webcontent_processes_after_close"] = String(alive.count)
        summary["rss_after_close_kb"] = String(alive.values.reduce(0) { $0 + $1.rssKB })
    }

    /// 주어진 PID들이 모두 사라질 때까지 기다린다. 사라지면 걸린 초, 한도를 넘기면 nil.
    static func waitForReclaim(pids: Set<Int32>, limit: TimeInterval) -> TimeInterval? {
        if pids.isEmpty { return 0 }
        let start = Date()
        while Date().timeIntervalSince(start) < limit {
            let alive = Set(webContentProcesses().keys).intersection(pids)
            if alive.isEmpty { return Date().timeIntervalSince(start) }
            idle(seconds: 0.5)
        }
        return nil
    }

    /// 지금 도는 WebContent 프로세스의 pid → (RSS KB, 누적 CPU 초). `ps`를 쓴다 — WKWebView는 자식 프로세스를
    /// 노출하지 않고 WebContent는 launchd 아래에 뜨므로, 프로세스 목록이 유일한 관측 창구다.
    static func webContentProcesses() -> [Int32: (rssKB: Int, cpuSeconds: Double)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ax", "-o", "pid=,rss=,time=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var result: [Int32: (rssKB: Int, cpuSeconds: Double)] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard line.contains("WebKit.WebContent") else { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3, let pid = Int32(fields[0]), let rss = Int(fields[1]) else { continue }
            result[pid] = (rssKB: rss, cpuSeconds: cpuSeconds(fields[2]))
        }
        return result
    }

    /// `ps` time 필드(`M:SS.ss` 또는 `H:MM:SS`)를 초로 바꾼다.
    static func cpuSeconds(_ field: Substring) -> Double {
        let parts = field.split(separator: ":").map { Double($0) ?? 0 }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return 0
        }
    }

    static func idle(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    // MARK: - WKWebView 구동

    /// 표현식이 truthy가 될 때까지 run loop를 돌린다. 값이 오면 그 값을, 시간이 다 되면 nil을 준다.
    static func waitFor(webView: WKWebView, expression: String) -> Any? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            if let value = evaluate(webView, expression) {
                if let flag = value as? Bool, flag { return true }
                if let text = value as? String, !text.isEmpty { return text }
            }
        }
        return nil
    }

    static func evaluate(_ webView: WKWebView, _ script: String) -> Any? {
        var result: Any?
        var done = false
        webView.evaluateJavaScript(script) { value, _ in
            result = value
            done = true
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !done, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return result
    }

    static func evaluateJSON(_ webView: WKWebView, _ script: String) -> [String: Any]? {
        guard let text = evaluate(webView, script) as? String,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    static func snapshot(_ webView: WKWebView, to url: URL) -> Bool {
        var written = false
        var done = false
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        webView.takeSnapshot(with: config) { image, _ in
            defer { done = true }
            guard let image,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { return }
            written = (try? png.write(to: url)) != nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !done, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return written
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("editor smoke: \(message)\n".utf8))
        exit(1)
    }
}
