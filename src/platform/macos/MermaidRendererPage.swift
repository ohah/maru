import Foundation
import WebKit

/// FP10c1 helper의 inert 문서 구성 단일 출처다. Process/protocol 수명과 WKWebView page 구성을
/// 분리해, helper smoke가 실제 loadHTMLString 계약을 그대로 검증할 수 있게 한다.
enum MermaidRendererPage {
    static let baseURL: URL? = nil

    @MainActor
    static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // userContentController에 handler를 하나도 추가하지 않는 것이 앱 bridge 부재의 구조적 보장이다.
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString(
            """
            <!doctype html><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; connect-src 'none'; img-src data:; style-src 'unsafe-inline'">
            <body></body>
            """,
            // c1 문서는 외부 asset을 resolve하지 않는다. 합성 custom scheme을 base로 주면 WebKit이
            // Launch Services에 넘겨 앱 선택 alert를 만들 수 있으므로 opaque blank origin을 유지한다.
            baseURL: baseURL
        )
        return webView
    }
}
