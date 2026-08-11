//! `maru-app://` 신뢰 스킴 핸들러(Phase 5c-2c). MaruAppHost.swift에서 분리했다 — 제품 앱과 E0.5A editor 스모크가
//! **같은 핸들러·같은 CSP**를 컴파일해야 그 게이트가 "제품 경로"를 검증한다고 말할 수 있기 때문이다(docs/editor-surface.md
//! §7.4). 옮기기만 했고 동작은 그대로다. 헬퍼 두 타입은 파일이 갈리며 `private`을 뗐다(같은 모듈 안 internal).

import AppKit
import Foundation
import WebKit

// MARK: - Phase 5c-2c: maru-app:// 신뢰 스킴 핸들러 (WKURLSchemeHandler 어댑터)
//
// 신뢰(markdown) 웹 패널의 `WKWebViewConfiguration`에만 등록되는 커스텀 스킴 핸들러. `maru-app://app/<path>` 요청을
// 받으면 Zig `maru_macos_app_read_app_asset`이 flat role allowlist를 판정하고 root-relative no-follow open한 같은 fd에서
// 읽은 bytes만 돌려준다. Swift는 그 bytes에 **role별 엄격 CSP 헤더**(단일 출처=Zig AppAssetRole)를 붙여 응답한다.
// 거부(샌드박스·symlink·부재)는 정보 노출 없이 404. **정책·파일 identity는 Zig, 여기는 WebKit 응답 조립만** 한다
// (docs/plans/web-panel.md §10). 비신뢰(browser) 패널엔 이 핸들러를 애초에 등록하지 않는다
// (origin 위장 탈취 1차 차단 — §7 ④·§8.1(c), 2차는 browser 패널의 maru-app:// 네비 차단).
final class MaruSchemeSmokeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private(set) var response: HTTPURLResponse?
    private(set) var data = Data()
    private(set) var finished = false
    private(set) var failure: Error?

    init(url: URL) {
        self.request = URLRequest(url: url)
        super.init()
    }

    func didReceive(_ response: URLResponse) {
        self.response = response as? HTTPURLResponse
    }

    func didReceive(_ data: Data) {
        self.data.append(data)
    }

    func didFinish() {
        finished = true
    }

    func didFailWithError(_ error: Error) {
        failure = error
    }
}

@MainActor
struct MaruAssetLoadBudget {
    static let capacity = 32
    let limit: Int
    private var physicalIds = [UInt64](repeating: 0, count: capacity)
    private var nextPhysicalId: UInt64 = 1

    init(limit: Int) {
        precondition(limit > 0 && limit <= Self.capacity)
        self.limit = limit
    }

    var physicalCount: Int { physicalIds.prefix(limit).reduce(0) { $0 + ($1 == 0 ? 0 : 1) } }

    mutating func admit() -> UInt64? {
        guard let slot = physicalIds.prefix(limit).firstIndex(of: 0) else { return nil }
        var loadId = nextPhysicalId
        while loadId == 0 || physicalIds.prefix(limit).contains(loadId) {
            loadId &+= 1
        }
        nextPhysicalId = loadId &+ 1
        if nextPhysicalId == 0 { nextPhysicalId = 1 }
        physicalIds[slot] = loadId
        return loadId
    }

    mutating func cancel(_ loadId: UInt64) -> Bool {
        // Logical cancellation removes WebKit callback ownership, not the already queued/running physical job.
        physicalIds.prefix(limit).contains(loadId)
    }

    mutating func complete(_ loadId: UInt64) -> Bool {
        guard let slot = physicalIds.prefix(limit).firstIndex(of: loadId) else { return false }
        physicalIds[slot] = 0
        return true
    }

    static func selfTest(limit: Int) -> Bool {
        guard limit > 0, limit <= capacity else { return false }
        var budget = MaruAssetLoadBudget(limit: limit)
        var ids: [UInt64] = []
        for _ in 0 ..< limit {
            guard let id = budget.admit() else { return false }
            ids.append(id)
        }
        for id in ids where !budget.cancel(id) { return false }
        // limit번 start → stop 뒤에도 physical completion 전의 추가 start는 전부 거부한다.
        for _ in 0 ..< limit where budget.admit() != nil { return false }
        for id in ids where !budget.complete(id) { return false }
        // 서로 다른 handler의 첫 요청도 같은 global issuer에서 충돌하지 않는 token을 받는다.
        guard let firstHandler = budget.admit(), let secondHandler = budget.admit(),
              firstHandler != secondHandler, budget.cancel(firstHandler), budget.cancel(secondHandler),
              budget.complete(firstHandler), budget.physicalCount == 1,
              budget.cancel(secondHandler), budget.complete(secondHandler) else { return false }
        return budget.physicalCount == 0
    }
}

@MainActor
final class MaruAppSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "maru-app"
    private nonisolated static let maxAssetBytes = 4 * 1024 * 1024
    private static var loadBudget = MaruAssetLoadBudget(limit: MaruAssetLoadBudget.capacity)
    private nonisolated static let assetIOQueue = DispatchQueue(label: "app.maru.scheme-assets", qos: .userInitiated)
    private let assetRoot: String // 번들 web asset root 절대 경로(Bundle.main.resourceURL/web 또는 MARU_WEB_APP_ROOT).
    private let appCSP: String
    private let renderCSP: String
    private var pendingLoads: [UInt64: (task: WKURLSchemeTask, url: URL, role: Int32)] = [:]
    private var pendingTaskIds: [ObjectIdentifier: UInt64] = [:]

    init(assetRoot: String) {
        self.assetRoot = assetRoot
        self.appCSP = Self.loadCSP(role: MARU_APP_ASSET_ROLE_APP)
        self.renderCSP = Self.loadCSP(role: MARU_APP_ASSET_ROLE_RENDER)
        super.init()
    }

    // 신뢰 UI asset root — 번들 Resources/web(정식 실행) 또는 MARU_WEB_APP_ROOT override(bare 스모크·dev). override는
    // root만 바꾸고 샌드박스는 그 아래로 그대로 적용되므로 안전(dev/smoke 편의). nil이면 핸들러 미등록(패널이 blank).
    static func webAssetRoot() -> String? {
        if let ov = ProcessInfo.processInfo.environment["MARU_WEB_APP_ROOT"], !ov.isEmpty { return ov }
        return Bundle.main.resourceURL?.appendingPathComponent("web").path
    }

    // app_scheme.appOriginAllowed의 Swift 어댑터. role: shell=0, renderer=1, asset=2.
    static func originAllowed(scheme: String, host: String, hasExplicitPort: Bool, role: UInt32) -> Bool {
        let schemeBytes = Array(scheme.utf8)
        let hostBytes = Array(host.utf8)
        return schemeBytes.withUnsafeBufferPointer { sp in
            hostBytes.withUnsafeBufferPointer { hp in
                maru_macos_app_origin_allowed(
                    sp.baseAddress,
                    sp.count,
                    hp.baseAddress,
                    hp.count,
                    hasExplicitPort ? 1 : 0,
                    role
                ) == 1
            }
        }
    }

    static func originAllowed(_ url: URL, role: UInt32) -> Bool {
        guard let scheme = url.scheme, let host = url.host else { return false }
        return originAllowed(scheme: scheme, host: host, hasExplicitPort: url.port != nil, role: role)
    }

    static func assetRole(_ url: URL) -> Int32 {
        guard let scheme = url.scheme, let host = url.host else { return -1 }
        let schemeBytes = Array(scheme.utf8)
        let hostBytes = Array(host.utf8)
        return schemeBytes.withUnsafeBufferPointer { sp in
            hostBytes.withUnsafeBufferPointer { hp in
                maru_macos_app_asset_role_for_origin(sp.baseAddress, sp.count, hp.baseAddress, hp.count, url.port == nil ? 0 : 1)
            }
        }
    }

    struct RoleSchemeSmokeResult {
        let appShellStatus: Int
        let appShellCSP: String
        let appMermaidStatus: Int
        let renderShellStatus: Int
        let renderShellCSP: String
        let renderDocumentStatus: Int
        let renderDocumentCSP: String
    }

    /// Actual WKURLSchemeHandler adapter smoke. The temporary root keeps the inert worker fixture out of the
    /// production bundle until FP10b creates the dedicated worker bundle.
    static func roleSchemeSmoke(using webView: WKWebView) -> RoleSchemeSmokeResult? {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maru-role-scheme-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try Data("<!doctype html><title>shell</title>".utf8).write(to: root.appendingPathComponent("index.html"))
            try Data("globalThis.mermaid={}".utf8).write(to: root.appendingPathComponent("mermaid-helper.js"))
            try Data("<!doctype html><title>render</title>".utf8).write(to: root.appendingPathComponent("render.html"))
            let handler = MaruAppSchemeHandler(assetRoot: root.path)
            func run(_ rawURL: String) -> MaruSchemeSmokeTask? {
                guard let url = URL(string: rawURL) else { return nil }
                let task = MaruSchemeSmokeTask(url: url)
                handler.webView(webView, start: task)
                let deadline = Date().addingTimeInterval(2)
                while !task.finished && task.failure == nil && Date() < deadline {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                }
                return task.finished ? task : nil
            }
            guard let appShell = run("maru-app://app/index.html"),
                  let appMermaid = run("maru-app://app/mermaid-helper.js"),
                  let renderShell = run("maru-app://render/index.html"),
                  let renderDocument = run("maru-app://render/render.html") else { return nil }
            let appShellStatus = appShell.response?.statusCode ?? -1
            let appShellCSP = appShell.response?.value(forHTTPHeaderField: "Content-Security-Policy") ?? "missing"
            let renderShellStatus = renderShell.response?.statusCode ?? -1
            let renderShellCSP = renderShell.response?.value(forHTTPHeaderField: "Content-Security-Policy") ?? "missing"
            let renderDocumentStatus = renderDocument.response?.statusCode ?? -1
            let renderDocumentCSP = renderDocument.response?.value(forHTTPHeaderField: "Content-Security-Policy") ?? "missing"
            return RoleSchemeSmokeResult(
                appShellStatus: appShellStatus,
                appShellCSP: appShellCSP,
                appMermaidStatus: appMermaid.response?.statusCode ?? -1,
                renderShellStatus: renderShellStatus,
                renderShellCSP: renderShellCSP,
                renderDocumentStatus: renderDocumentStatus,
                renderDocumentCSP: renderDocumentCSP
            )
        } catch {
            return nil
        }
    }

    // CSP 문자열은 Zig AppAssetRole이 단일 출처 — role별 export를 1회 읽어 캐시한다(Swift에 중복 문자열 두지 않음).
    private static func loadCSP(role: UInt32) -> String {
        // 버퍼는 csp_header(현재 ~152B) 대비 넉넉히(1024B). 초과(-1)는 사실상 도달 불가지만 **조용히** default-deny로
        // 폴백하면 신뢰 패널이 자기 script/style을 CSP로 막아 blank가 되고 원인 불명이 되므로, 개발 빌드에서 소리내어
        // 실패시켜(assertionFailure) 버퍼를 키우도록 강제한다(리뷰11 [3]). 릴리스 폴백은 fail-closed(과제약이 안전).
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = maru_macos_app_csp_header(role, &buf, buf.count)
        guard n > 0 else {
            assertionFailure("maru_macos_app_csp_header 실패/초과(\(n)) — csp_header가 버퍼(\(buf.count)B)를 넘음. 버퍼를 키우세요.")
            return "default-src 'none'"
        }
        return String(decoding: buf[0 ..< Int(n)], as: UTF8.self)
    }

    // 다크모드 blank 회귀 방지: 배경 미지정 문서는 시스템 appearance(다크모드=다크)로 렌더돼 아래 다크 터미널과 구분되지
    // 않으므로, placeholder·에러 응답은 항상 color-scheme:light + 흰 배경을 명시한다(리뷰11 [1]). 신뢰 패널이 asset을 못
    // 찾아도(404) 다크 사각형 대신 흰 페이지가 보인다. 메시지는 고정 문자열이라 reflection/injection 없음.
    static func errorPageHTML(_ message: String) -> String {
        "<!doctype html><html><head><meta name=\"color-scheme\" content=\"light\"></head>"
            + "<body style=\"margin:0;background:#ffffff;color:#1a1a1a;font-family:-apple-system,system-ui,sans-serif;padding:2rem\">"
            + message + "</body></html>"
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let roleRaw = Self.assetRole(url)
        guard roleRaw == Int32(MARU_APP_ASSET_ROLE_APP) || roleRaw == Int32(MARU_APP_ASSET_ROLE_RENDER) else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        guard let loadId = Self.loadBudget.admit() else {
            respond(urlSchemeTask, url: url, status: 503, mime: "text/html; charset=utf-8", data: Data(Self.errorPageHTML("리소스 요청이 너무 많습니다 (503).").utf8), attachCSP: false)
            return
        }
        pendingLoads[loadId] = (urlSchemeTask, url, roleRaw)
        pendingTaskIds[ObjectIdentifier(urlSchemeTask as AnyObject)] = loadId
        let root = assetRoot
        let requestPath = url.path
        // Handler를 completion까지 유지해 background read 도중 WKWebView가 내려가더라도 전역 pending slot이
        // 유실되지 않게 한다. stop은 pending id를 먼저 제거하므로 늦은 completion은 callback 없이 종료된다.
        Self.assetIOQueue.async { [self] in
            let payload = Self.callRead(root: root, requestPath, role: UInt32(roleRaw))
            Task { @MainActor [self] in
                self.completeLoad(loadId, path: requestPath, data: payload)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask as AnyObject)
        guard let loadId = pendingTaskIds.removeValue(forKey: key) else { return }
        pendingLoads.removeValue(forKey: loadId)
        _ = Self.loadBudget.cancel(loadId)
        // 실제 serial executor job은 이미 queued/running일 수 있다. 물리 slot은 completion에서만 반환해
        // start/stop 반복이 executor backlog를 32개보다 크게 만들지 못하게 한다.
    }

    private func completeLoad(_ loadId: UInt64, path: String?, data: Data?) {
        guard Self.loadBudget.complete(loadId) else { return }
        guard let pending = pendingLoads.removeValue(forKey: loadId) else { return }
        pendingTaskIds.removeValue(forKey: ObjectIdentifier(pending.task as AnyObject))
        guard let path, let data else {
            // resolve/read는 전용 bounded serial queue에서 끝났고, WebKit callback만 MainActor에서 수행한다.
            respond(pending.task, url: pending.url, status: 404, mime: "text/html; charset=utf-8", data: Data(Self.errorPageHTML("요청한 리소스를 찾을 수 없습니다 (404).").utf8), attachCSP: false)
            return
        }
        respond(pending.task, url: pending.url, status: 200, mime: Self.mimeType(forPath: path), data: data, csp: pending.role == Int32(MARU_APP_ASSET_ROLE_APP) ? appCSP : renderCSP)
    }

    // FFI 마샬링 **단일 출처**(핸들러 인스턴스 + 스모크 검증이 공유 — 리뷰11 [6]). 요청 path → (Zig 반환 코드,
    // 성공(>0) 시 asset root 아래 안전한 절대 경로). 빈 path(`maru-app://app`처럼 authority만)는 Zig가 index.html로
    // 매핑하는 계약이지만 빈 Swift 배열은 baseAddress=nil이라 export가 NULL(-4)로 오판하므로 "/"로 정규화한다.
    nonisolated static func callResolve(root: String, _ reqPath: String, role: UInt32 = MARU_APP_ASSET_ROLE_APP) -> (code: Int64, path: String?) {
        let rootBytes = Array(root.utf8)
        let reqBytes = Array((reqPath.isEmpty ? "/" : reqPath).utf8)
        var out = [UInt8](repeating: 0, count: 4096)
        let n = rootBytes.withUnsafeBufferPointer { rp in
            reqBytes.withUnsafeBufferPointer { qp in
                out.withUnsafeMutableBufferPointer { op in
                    maru_macos_app_resolve_app_asset(role, rp.baseAddress, rp.count, qp.baseAddress, qp.count, op.baseAddress, op.count)
                }
            }
        }
        guard n > 0 else { return (n, nil) }
        return (n, String(decoding: out[0 ..< Int(n)], as: UTF8.self))
    }

    nonisolated static func callRead(root: String, _ reqPath: String, role: UInt32) -> Data? {
        let rootBytes = Array(root.utf8)
        let reqBytes = Array((reqPath.isEmpty ? "/" : reqPath).utf8)
        var data = Data(count: maxAssetBytes)
        let count = data.withUnsafeMutableBytes { raw in
            rootBytes.withUnsafeBufferPointer { rp in
                reqBytes.withUnsafeBufferPointer { qp in
                    maru_macos_app_read_app_asset(
                        role,
                        rp.baseAddress,
                        rp.count,
                        qp.baseAddress,
                        qp.count,
                        raw.bindMemory(to: UInt8.self).baseAddress,
                        raw.count
                    )
                }
            }
        }
        guard count >= 0, count <= data.count else { return nil }
        data.count = Int(count)
        return data
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, status: Int, mime: String, data: Data, attachCSP: Bool = true, csp: String = "") {
        var headers = [
            "Content-Type": mime,
            "Content-Length": "\(data.count)",
        ]
        // 서빙 asset(app 콘텐츠)엔 엄격 CSP를 붙인다(외부 네트워크·iframe·base-uri·form-action 차단). 정적 error page는
        // 활성 콘텐츠가 없어 CSP를 생략한다(위 404 주석 — 인라인 흰 배경이 차단되지 않게).
        if attachCSP {
            headers["Content-Security-Policy"] = csp
            // asset(bundle.js·app.css·render.html 등)은 앱 수명 동안 불변이므로 WebKit이 캐시하게 한다. 없으면
            // 커스텀 스킴 응답이 캐시되지 않아, 라이브 프리뷰의 atomic 위젯 iframe마다 bundle.js(≈1.9 MiB)를 단일
            // serial IO로 매번 다시 읽어, 코드펜스가 많은 큰 문서에서 뒤쪽 위젯이 deadline 안에 못 부팅해 소스로
            // 폴백하던 것을 없앤다(첫 로드만 느리고 이후는 캐시 히트). 앱 갱신 시 새 WebKit 세션이라 stale 없음.
            headers["Cache-Control"] = "max-age=3600"
        }
        guard let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            task.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    // 확장자 기반 MIME(어댑터 관심사). asset root의 신뢰 파일만 서빙하므로 sniffing 없이 확장자로 충분.
    nonisolated private static func mimeType(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "woff2": return "font/woff2"
        case "wasm": return "application/wasm"
        default: return "application/octet-stream"
        }
    }
}
