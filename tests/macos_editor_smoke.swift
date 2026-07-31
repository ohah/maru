//! E0.5A **제품 WKWebView 게이트**(docs/editor-surface.md §7.4).
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

        // 하니스가 마운트를 끝낼 때까지 run loop를 돌린다. 폴링이지만 값이 도착하면 즉시 나가므로 고정 대기가 아니다.
        guard let ready = waitFor(webView: webView, expression: "window.__maruEditorSmoke ? (window.__maruEditorSmoke.ready || window.__maruEditorSmoke.error || false) : false") else {
            fail("harness never became ready within \(Int(timeout))s")
        }
        if let errorText = ready as? String {
            fail("harness mount failed: \(errorText)")
        }

        var summary: [String: String] = [:]
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

        // ── CSP 자가검증. 헤더가 빠져도 위반은 0으로 보이므로, "위반 0"을 근거로 쓰려면 CSP가 실제로 막는다는
        //    증거가 있어야 한다. 반드시 차단돼야 하는 eval을 일부러 시도한다 — **위 계측이 모두 끝난 뒤**에.
        let cspEnforced = evaluate(webView, "window.__maruEditorSmoke.csp_self_test()") as? Bool ?? false
        summary["csp_enforced"] = String(cspEnforced)
        let violationsAfterSelfTest = (evaluate(webView, "JSON.stringify(window.__maruEditorSmoke.violations)") as? String) ?? "[]"
        summary["csp_self_test_violations"] = violationsAfterSelfTest
        // 자가검증이 위반을 **실제로 만들어야** 수집기도 살아 있다는 뜻이다(수집기가 죽어 있으면 위 0도 거짓이다).
        let selfTestRaisedViolation = jsonArrayCount(violationsAfterSelfTest) > jsonArrayCount(violations)
        summary["csp_violation_recorder_live"] = String(selfTestRaisedViolation)

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
